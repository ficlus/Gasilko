package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*

/** Local reads/writes with an append-only queue; explicit hydration never replaces pending work. */
class RoomHydrantRepository(
    private val database: RegistryDatabase,
    private val online: HydrantRepository,
    private val currentAccount: () -> String,
) : HydrantRepository {
    private val dao = database.registry()
    private val changes = Mutex()
    private fun checkAccount(account: String) {
        if (currentAccount() != account) throw RegistryFailure(RegistryError.EXPIRED)
    }
    private suspend fun organization(account: String, id: String) = dao.organizations(account)
        .firstOrNull { it.value.id == id }?.value ?: throw RegistryFailure(RegistryError.FORBIDDEN)

    override suspend fun organizations(): List<RegistryOrganization> {
        val account = currentAccount()
        return dao.organizations(account).map { it.value }.also { checkAccount(account) }
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
        val rows = online.organizations()
        checkAccount(account)
        database.withTransaction {
            dao.removeOrganizations(account)
            dao.upsertOrganizations(rows.map { OrganizationEntity(account, it) })
        }
    }
    override suspend fun refresh(organization: String) = changes.withLock {
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
    }
    override suspend fun refreshDetail(organization: String, id: String) = changes.withLock {
        val account = currentAccount()
        organization(account, organization)
        if(id in dao.pendingHydrantIds(account, organization)) return@withLock
        val row = online.get(organization, id)
        checkAccount(account)
        require(row.organization == organization && row.id == id)
        database.withTransaction {
            if(id !in dao.pendingHydrantIds(account, organization))
                dao.upsertHydrants(listOf(HydrantEntity.from(account, row)))
        }
    }

    private suspend fun localWrite(organization: String, id: String, operation: String, version: Long?,
        payload: JsonObject, change: (Hydrant?, String, String) -> Hydrant): Hydrant = changes.withLock {
        val account = currentAccount()
        database.withTransaction {
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
