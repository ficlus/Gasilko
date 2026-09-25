package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.domain.*
import si.gasilko.app.feature.inspections.data.*

/** Local reads/writes with an append-only queue; explicit hydration never replaces pending work. */
class RoomHydrantRepository(
    private val database: RegistryDatabase,
    private val online: HydrantRepository,
    private val currentAccount: () -> String,
    private val selectSyncScope: (String?, String?) -> Unit = { _, _ -> },
    private val scheduleSync: (String, String) -> Unit = { _, _ -> },
    private val authorizedOrganizations: (suspend (String) -> List<RegistryOrganization>)? = null,
    private val refreshAuthorization: (suspend () -> List<RegistryOrganization>)? = null,
    private val observeWork: (String, String) -> Flow<SyncPhase> = { _, _ -> flowOf(SyncPhase.PENDING) },
) : HydrantRepository {
    private val dao = database.registry()
    private val changes = Mutex()
    override fun observeInspections(organization: String, hydrantId: String): Flow<List<Inspection>> = flow {
        val account=currentAccount()
        emitAll(database.invalidationTracker.createFlow("inspections","hydrants","organizations").map {
            get(organization,hydrantId) // Reuse cached authorization and inactive-hydrant role gates.
            dao.inspectionHistory(account,organization,hydrantId).map { it.value }.also { checkAccount(account) }
        }.distinctUntilChanged())
    }
    override suspend fun listInspections(organization: String, hydrantId: String, after: String?): List<Inspection> {
        val account=currentAccount()
        get(organization,hydrantId)
        return dao.inspectionHistory(account,organization,hydrantId).map { it.value }
            .filter { after==null || it.id>after }.sortedBy { it.id }.take(100).also { checkAccount(account) }
    }
    override suspend fun refreshInspections(organization: String, hydrantId: String) = hydrantRemoteAccess.withLock { changes.withLock history@{
        val account=currentAccount()
        val local=get(organization,hydrantId)
        if(local.version==0L) return@history // Parent hydrant has not reached the server yet.
        val rows=mutableListOf<Inspection>()
        var after: String?=null
        do {
            val page=online.listInspections(organization,hydrantId,after)
            require(page.all { it.organization==organization && it.hydrantId==hydrantId && (after==null || it.id>after!!) })
            rows.addAll(page);after=page.lastOrNull()?.id
        } while(page.size==100)
        checkAccount(account)
        database.withTransaction {
            // Never replace a local event or delete history on a partial/empty refresh.
            dao.cacheInspections(rows.map { InspectionEntity(account,it,System.currentTimeMillis()) })
            checkAccount(account)
        }
    } }
    override suspend fun completeInspection(organization: String, hydrantId: String, input: InspectionCompletion): InspectionWrite = changes.withLock {
        input.validate()
        val account=currentAccount()
        val result=database.withTransaction {
            val org=organization(account,organization)
            if(!org.active) throw RegistryFailure(RegistryError.FORBIDDEN)
            val prior=dao.get(account,organization,hydrantId)?.value ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
            if(!prior.active && !org.role.manages) throw RegistryFailure(RegistryError.FORBIDDEN)
            val existing=dao.inspection(account,organization,input.id)?.value
            if(existing!=null) {
                if(existing.hydrantId!=hydrantId || existing.inspectorId!=account || !existing.completion().sameEvent(input))
                    throw RegistryFailure(RegistryError.VALIDATION)
                checkAccount(account)
                return@withTransaction InspectionWrite(existing,prior)
            }
            val now=System.currentTimeMillis()
            val inspection=Inspection(input.id,hydrantId,organization,account,input.mode,input.result,
                input.startedAt,input.completedAt,input.notes,input.pressureBar,input.flowLMin,now)
            val visible=input.result.hydrantStatus?.let { prior.copy(status=it,updatedBy=account,updatedAt=Instant.ofEpochMilli(now).toString()) } ?: prior
            dao.insertInspection(InspectionEntity(account,inspection))
            dao.upsertHydrants(listOf(HydrantEntity.from(account,visible)))
            // Same ordered queue and parent UUID: protects the hydrant during refresh and
            // queues a never-synced parent's CREATE before this immutable inspection event.
            dao.enqueue(PendingHydrantChange(operationId=input.id,account=account,organization=organization,
                entityId=hydrantId,operation=CREATE_INSPECTION,payload=input.payload().toString(),
                baseVersion=prior.version.takeIf { it>0 },createdAt=now))
            checkAccount(account)
            InspectionWrite(inspection,visible)
        }
        try { scheduleSync(account,organization) }
        catch(_: Exception) { android.util.Log.w("HydrantSync","schedule failed; inspection retained") }
        result
    }
    override fun observeMap(query: HydrantQuery): Flow<List<Hydrant>> = flow {
        val account = currentAccount()
        emitAll(database.invalidationTracker.createFlow("hydrants", "organizations").map {
            val org = organization(account, query.organization)
            if(!org.active) throw RegistryFailure(RegistryError.FORBIDDEN)
            val q = query.normalized(org.role)
            dao.list(account, q.organization, HydrantEntity.fold(q.search), q.type, q.status,
                when(q.active) { ActiveFilter.ALL -> null; ActiveFilter.ACTIVE -> true; ActiveFilter.INACTIVE -> false },
                after = null, limit = -1).map { it.value }.also { checkAccount(account) }
        }.distinctUntilChanged())
    }
    override fun observeSync(organization: String): Flow<RegistrySyncState> = flow {
        val account = currentAccount()
        emitAll(combine(database.invalidationTracker.createFlow("hydrants", "pending_hydrant_changes", "hydrant_conflicts"),
            observeWork(account, organization)) { _, work ->
            organization(account, organization)
            database.withTransaction {
                val pending = dao.pendingHydrantIds(account, organization).toSet()
                val conflicts = conflicts(organization)
                checkAccount(account)
                RegistrySyncState(organization, when {
                    conflicts.isNotEmpty() -> SyncPhase.CONFLICT
                    pending.isEmpty() -> SyncPhase.SYNCHRONIZED
                    else -> work
                }, pending, conflicts)
            }
        })
    }
    override fun setActiveOrganization(organization: String?) {
        selectSyncScope(if(organization == null) null else currentAccount(), organization)
    }
    override fun requestSync(organization: String) { scheduleSync(currentAccount(), organization) }
    override suspend fun conflicts(organization: String): List<HydrantConflict> {
        val account = currentAccount()
        organization(account, organization)
        return dao.pendingChanges(account, organization).filter { it.state == "CONFLICT" }.map { operation ->
            ensureConflict(database, operation)
            val info = dao.conflictInfo(account, organization, operation.sequence)!!
            val local = decodeHydrant(Json.parseToJsonElement(info.localState))
            HydrantConflict(operation.sequence, account, organization, operation.operation, operation.payload,
                local, info.serverState?.let { decodeHydrant(Json.parseToJsonElement(it)) },
                if(operation.operation == "CREATE") local else operation.applyTo(local))
        }.also { checkAccount(account) }
    }
    override suspend fun resolveConflict(organization: String, sequence: Long, resolution: ConflictResolution) {
        hydrantRemoteAccess.withLock { changes.withLock {
            val account = currentAccount()
            organization(account, organization)
            val org = (refreshAuthorization?.invoke() ?: online.organizations()).find { it.id == organization && it.active }
                ?: throw RegistryFailure(RegistryError.FORBIDDEN)
            val operation = dao.pendingChanges(account, organization).find { it.sequence == sequence && it.state == "CONFLICT" }
                ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
            if(resolution == ConflictResolution.KEEP_LOCAL && operation.operation in listOf("UPDATE", "SET_ACTIVE") && !org.role.manages)
                throw RegistryFailure(RegistryError.FORBIDDEN)
            val server = online.get(organization, operation.entityId)
            require(server.organization == organization && server.id == operation.entityId)
            checkAccount(account)
            ensureConflict(database, operation)
            database.withTransaction {
                val now = System.currentTimeMillis()
                dao.captureServer(account, organization, sequence, server.snapshot())
                val replacement = if(resolution == ConflictResolution.KEEP_LOCAL) dao.enqueue(operation.copy(
                    sequence = 0, operationId = UUID.randomUUID().toString(), baseVersion = server.version,
                    createdAt = now, state = "PENDING", acknowledgedVersion = null,
                    orderSequence = operation.orderSequence ?: operation.sequence)) else null
                check(dao.resolve(account, organization, sequence, resolution.name, now, server.snapshot(), server.version, replacement) == 1)
                check(dao.resolveOperation(account, organization, sequence) == 1)
                var visible = server
                dao.remainingChanges(account, organization, server.id).forEach { visible = it.applyTo(visible) }
                dao.upsertHydrants(listOf(HydrantEntity.from(account, visible)))
                checkAccount(account)
            }
            try { scheduleSync(account, organization) }
            catch(_: Exception) { android.util.Log.w("HydrantSync", "schedule failed; resolution retained") }
        } }
    }
    private fun checkAccount(account: String) {
        if (currentAccount() != account) throw RegistryFailure(RegistryError.EXPIRED)
    }
    private suspend fun organization(account: String, id: String) =
        (authorizedOrganizations?.invoke(account) ?: dao.organizations(account).map { it.value })
            .firstOrNull { it.id == id } ?: throw RegistryFailure(RegistryError.FORBIDDEN)

    override suspend fun organizations(): List<RegistryOrganization> {
        val account = currentAccount()
        return (authorizedOrganizations?.invoke(account) ?: dao.organizations(account).map { it.value }).also { checkAccount(account) }
    }
    override suspend fun types(organization: String): List<HydrantType> {
        val account = currentAccount()
        val org = organization(account, organization)
        return dao.types(account, organization).map { it.value }
            .filter { org.role.manages || it.active }.also { checkAccount(account) }
    }
    override suspend fun list(query: HydrantQuery, after: String?): List<Hydrant> {
        val account = currentAccount()
        val q = query.normalized(organization(account, query.organization).role)
        return dao.list(account, q.organization, HydrantEntity.fold(q.search), q.type, q.status,
            when(q.active) { ActiveFilter.ALL -> null; ActiveFilter.ACTIVE -> true; ActiveFilter.INACTIVE -> false }, after)
            .map { it.value }.also { checkAccount(account) }
    }
    override suspend fun get(organization: String, id: String): Hydrant {
        val account = currentAccount()
        val org = organization(account, organization)
        val row = dao.get(account, organization, id)?.value
        checkAccount(account)
        return row?.takeIf { it.active || org.role.manages } ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    override suspend fun refreshOrganizations() = changes.withLock {
        val account = currentAccount()
        val rows = refreshAuthorization?.invoke() ?: online.organizations()
        checkAccount(account)
        database.withTransaction {
            dao.removeOrganizations(account)
            dao.upsertOrganizations(rows.map { OrganizationEntity(account, it) })
        }
    }
    override suspend fun refresh(organization: String) = hydrantRemoteAccess.withLock { changes.withLock {
        val account = currentAccount()
        val org = organization(account, organization)
        val types = online.types(organization)
        val rows = mutableListOf<Hydrant>()
        val query = HydrantQuery(organization, active = if(org.role.manages) ActiveFilter.ALL else ActiveFilter.ACTIVE)
        var after: String? = null
        do {
            val page = online.list(query, after)
            require(page.all { it.organization == organization && (after == null || it.id > after!!) })
            rows.addAll(page)
            after = page.lastOrNull()?.id
        } while(page.size == 100)
        require(types.all { it.organization == null || it.organization == organization })
        checkAccount(account)
        // All pages must succeed before replacing this organization, in one atomic transaction.
        database.withTransaction {
            val pending = dao.pendingHydrantIds(account, organization).toSet()
            dao.removeHydrants(account, organization)
            dao.removeTypes(account, organization)
            dao.upsertTypes(types.map { TypeEntity(account, organization, it) })
            dao.upsertHydrants(rows.filterNot { it.id in pending }.map { HydrantEntity.from(account, it) })
        }
    } }
    override suspend fun refreshDetail(organization: String, id: String) = hydrantRemoteAccess.withLock { changes.withLock detail@{
        val account = currentAccount()
        organization(account, organization)
        if(id in dao.pendingHydrantIds(account, organization)) return@detail
        val row = online.get(organization, id)
        checkAccount(account)
        require(row.organization == organization && row.id == id)
        database.withTransaction {
            if(id !in dao.pendingHydrantIds(account, organization))
                dao.upsertHydrants(listOf(HydrantEntity.from(account, row)))
        }
    } }

    private suspend fun localWrite(organization: String, id: String, operation: String, version: Long?,
        payload: JsonObject, change: (Hydrant?, String, String) -> Hydrant): Hydrant = changes.withLock {
        val account = currentAccount()
        val result = database.withTransaction {
            val org = organization(account, organization)
            if(!org.active || (operation in listOf("UPDATE", "SET_ACTIVE") && !org.role.manages))
                throw RegistryFailure(RegistryError.FORBIDDEN)
            val prior = dao.get(account, organization, id)?.value
            if(operation == "CREATE" && prior != null) {
                // Repeating the same local create must not erase later edits or append another create.
                if(prior.createdBy == account && dao.pendingChanges(account, organization)
                        .any { it.entityId == id && it.operation == "CREATE" }) {
                    checkAccount(account)
                    return@withTransaction prior
                }
                throw RegistryFailure(RegistryError.VALIDATION)
            }
            if(operation != "CREATE") {
                if(prior == null) throw RegistryFailure(RegistryError.UNAVAILABLE)
                if(!prior.active && !org.role.manages) throw RegistryFailure(RegistryError.FORBIDDEN)
                if(prior.version != version) throw RegistryFailure(RegistryError.CONFLICT)
            }
            val now = Instant.now()
            val row = change(prior, account, now.toString())
            if(operation == "CREATE" || operation == "UPDATE") {
                val lat = row.latitude; val lon = row.longitude
                if((lat == null) != (lon == null) || (lat != null && (!lat.isFinite() || lat !in -90.0..90.0)) ||
                    (lon != null && (!lon.isFinite() || lon !in -180.0..180.0)))
                    throw RegistryFailure(RegistryError.COORDINATES)
                if(lat == null && row.address.isNullOrBlank() && row.description.isNullOrBlank())
                    throw RegistryFailure(RegistryError.LOCATION)
                if(row.interval != null && row.interval <= 0) throw RegistryFailure(RegistryError.INTERVAL)
                if(row.type != prior?.type && dao.types(account, organization).none { it.value.id == row.type && it.value.active })
                    throw RegistryFailure(RegistryError.TYPE)
            }
            checkAccount(account)
            if(operation == "CREATE") dao.insertHydrant(HydrantEntity.from(account, row))
            else dao.upsertHydrants(listOf(HydrantEntity.from(account, row)))
            // version remains the last server version (0 for a never-synced create).
            // Ordered operations retain that baseline; future sync must chain server acknowledgements.
            dao.enqueue(PendingHydrantChange(operationId = UUID.randomUUID().toString(), account = account,
                organization = organization, entityId = id, operation = operation, payload = payload.toString(),
                baseVersion = prior?.version?.takeIf { it > 0 }, createdAt = now.toEpochMilli()))
            checkAccount(account)
            row
        }
        // A scheduling failure cannot turn an already committed local write into a failed save.
        try { scheduleSync(account, organization) }
        catch(_: Exception) { android.util.Log.w("HydrantSync", "schedule failed; queue retained") }
        result
    }
    override suspend fun create(organization: String, id: String, fields: HydrantFields): Hydrant {
        if(runCatching { UUID.fromString(id).toString() }.getOrNull() != id)
            throw RegistryFailure(RegistryError.VALIDATION)
        return localWrite(organization, id, "CREATE", null, buildJsonObject {
            put("hydrant_type_id", fields.type); fields.payload(true).forEach { (key, value) -> put(key, value) }
        }) { _, account, now ->
            Hydrant(id, organization, null, fields.type, fields.status, fields.latitude, fields.longitude,
                fields.address, fields.description, fields.notes, fields.interval, version = 0,
                createdBy = account, createdAt = now, updatedAt = now, updatedBy = account)
        }
    }
    override suspend fun changeStatus(organization: String, id: String, status: HydrantStatus, version: Long) =
        localWrite(organization, id, "CHANGE_STATUS", version, buildJsonObject { put("status", status.name) }) { prior, account, now ->
            prior!!.copy(status = status, updatedAt = now, updatedBy = account)
        }
    override suspend fun update(organization: String, id: String, fields: HydrantFields, version: Long) =
        localWrite(organization, id, "UPDATE", version, fields.payload(false)) { prior, account, now ->
            prior!!.copy(type = fields.type, latitude = fields.latitude, longitude = fields.longitude,
                address = fields.address, description = fields.description, notes = fields.notes,
                interval = fields.interval, updatedAt = now, updatedBy = account)
        }
    override suspend fun setActive(organization: String, id: String, active: Boolean, version: Long) =
        localWrite(organization, id, "SET_ACTIVE", version, buildJsonObject { put("active", active) }) { prior, account, now ->
            prior!!.copy(active = active, updatedAt = now, updatedBy = account)
        }
}
