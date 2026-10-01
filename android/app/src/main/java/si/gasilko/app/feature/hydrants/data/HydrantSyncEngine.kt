package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.domain.*
import si.gasilko.app.feature.inspections.data.*
import si.gasilko.app.feature.photos.domain.UPLOAD_PHOTO
import si.gasilko.app.feature.photos.data.PhotoFiles
import si.gasilko.app.feature.photos.data.uploadQueuedPhoto
import si.gasilko.app.feature.plans.*

// The app uses default, single-process WorkManager. Also serialize refreshes so a stale
// pre-upload snapshot cannot replace a newly acknowledged row. Local writes remain independent.
internal val hydrantRemoteAccess = Mutex()

/** Default WorkManager and manual callers share one process-wide upload lock. */
class HydrantSyncEngine(
    private val database: RegistryDatabase,
    private val online: HydrantRepository,
    private val account: String,
    private val checkContext: () -> Unit,
    private val photoFiles: PhotoFiles? = null,
) {
    suspend fun sync(organization: String) = hydrantRemoteAccess.withLock {
        checkContext()
        val org = online.organizations().find { it.id == organization && it.active }
            ?: throw RegistryFailure(RegistryError.FORBIDDEN)
        val dao = database.registry()
        while(true) {
            currentCoroutineContext().ensureActive()
            checkContext()
            val operation = dao.nextChange(account, organization) ?: break
            if(operation.state == "CONFLICT") {
                captureConflict(database, online, operation, checkContext)
                break // Filling missing server metadata is not a resolution.
            }
            if(operation.state != "PENDING") break
            if(operation.operation==SKIP_PLAN_ITEM) {
                uploadPlanSkip(database,online,operation,checkContext)
                continue
            }
            if(operation.operation==UPLOAD_PHOTO) {
                uploadQueuedPhoto(database,online,photoFiles,operation,checkContext)
                continue
            }
            if(operation.operation in listOf("UPDATE", "SET_ACTIVE") && !org.role.manages)
                throw RegistryFailure(RegistryError.FORBIDDEN)
            val acknowledged = dao.acknowledgedVersion(account, organization, operation.entityId, operation.orderSequence ?: operation.sequence)
            val version = maxOf(operation.baseVersion ?: 0, acknowledged ?: 0)
            val payload = Json.parseToJsonElement(operation.payload).jsonObject
            var inspection: Inspection? = null
            var planItem: PlanItem? = null
            checkContext()
            val server = try {
                when(operation.operation) {
                    CREATE_INSPECTION -> {
                        val input=payload.inspectionCompletion()
                        if(input.id!=operation.operationId)throw RegistryFailure(RegistryError.VALIDATION)
                        val accepted=online.completeInspection(organization,operation.entityId,input)
                        val event=accepted.inspection
                        if(!(event.id==input.id && event.organization==organization && event.hydrantId==operation.entityId &&
                            event.inspectorId==account && event.completion().sameEvent(input) &&
                            event.hydrantVersionBefore!=null && event.hydrantVersionAfter!=null)) {
                            recordInspectionIssue(database,account,organization,operation.operationId,"SERVER_EVENT_MISMATCH")
                            throw RegistryFailure(RegistryError.VALIDATION)
                        }
                        inspection=event
                        planItem=accepted.planItem
                        accepted.hydrant
                    }
                    "CREATE" -> online.create(organization, operation.entityId, payload.fields())
                    "UPDATE" -> online.update(organization, operation.entityId, payload.fields(), version)
                    "CHANGE_STATUS" -> online.changeStatus(organization, operation.entityId,
                        HydrantStatus.valueOf(payload.getValue("status").jsonPrimitive.content), version)
                    "SET_ACTIVE" -> online.setActive(organization, operation.entityId,
                        payload.getValue("active").jsonPrimitive.boolean, version)
                    else -> throw RegistryFailure(RegistryError.VALIDATION)
                }
            } catch(e: RegistryFailure) {
                if(operation.operation==CREATE_INSPECTION && e.reason==RegistryError.VALIDATION)
                    recordInspectionIssue(database,account,organization,operation.operationId,"SERVER_REJECTED_EVENT")
                if(e.reason != RegistryError.CONFLICT || operation.operation==CREATE_INSPECTION) throw e // Retryable failures keep PENDING; invalid immutable events stay blocked.
                captureConflict(database, online, operation, checkContext)
                break
            }
            require(server.id == operation.entityId && server.organization == organization && server.version > 0)
            if(!acknowledgeHydrantOperation(database,operation,server,inspection,checkContext,planItem))break
            // Inspection receipt and queue acknowledgement are durable before this best-effort action.
            // One attempt per newly acknowledged event; failures remain stale for a manual retry.
            planItem?.takeIf { it.inspectionId!=null && it.teamId!=null }?.let { item ->
                try {
                    checkContext()
                    val snapshot=online.readPlans(organization)
                    val plan=snapshot.plans.find { it.id==item.planId && it.status=="ACTIVE" }
                    if(plan!=null) {
                        val request=PlanRouting(plan.id,plan.version,
                            operationId=java.util.UUID.nameUUIDFromBytes(("remaining:"+operation.operationId).toByteArray(Charsets.UTF_8)).toString(),
                            remaining=true,teamId=item.teamId)
                        checkContext()
                        val routed=online.routePlan(organization,request)
                        checkContext()
                        cachePlanSnapshot(database,account,organization,routed,checkContext)
                    }
                } catch(e: kotlinx.coroutines.CancellationException) { throw e }
                catch(_: Exception) { /* No retry loop and no inspection/queue rollback. */ }
            }
        }
        checkContext()
        val plans=online.readPlans(organization)
        checkContext()
        cachePlanSnapshot(database,account,organization,plans,checkContext)
    }
}

private fun JsonObject.fields() = HydrantFields(
    getValue("hydrant_type_id").jsonPrimitive.content,
    this["latitude"]?.jsonPrimitive?.doubleOrNull, this["longitude"]?.jsonPrimitive?.doubleOrNull,
    this["address"]?.jsonPrimitive?.contentOrNull, this["location_description"]?.jsonPrimitive?.contentOrNull,
    this["notes"]?.jsonPrimitive?.contentOrNull, this["inspection_interval_months"]?.jsonPrimitive?.intOrNull,
    this["status"]?.jsonPrimitive?.contentOrNull?.let(HydrantStatus::valueOf) ?: HydrantStatus.UNKNOWN,
)

internal fun PendingHydrantChange.applyTo(row: Hydrant): Hydrant {
    val p = Json.parseToJsonElement(payload).jsonObject
    return when(operation) {
        SKIP_PLAN_ITEM -> row
        UPLOAD_PHOTO -> row // Attachment has no hydrant master/status effect during replay.
        CREATE_INSPECTION -> p.inspectionCompletion().result.hydrantStatus?.let { row.copy(status=it) } ?: row
        "UPDATE" -> p.fields().let { row.copy(type = it.type, latitude = it.latitude, longitude = it.longitude,
            address = it.address, description = it.description, notes = it.notes, interval = it.interval) }
        "CHANGE_STATUS" -> row.copy(status = HydrantStatus.valueOf(p.getValue("status").jsonPrimitive.content))
        "SET_ACTIVE" -> row.copy(active = p.getValue("active").jsonPrimitive.boolean)
        else -> throw RegistryFailure(RegistryError.VALIDATION)
    }
}

internal fun Hydrant.snapshot(): String = buildJsonObject {
    put("id", id); put("organization_id", organization); put("code", code); put("hydrant_type_id", type)
    put("status", status.name); put("latitude", latitude); put("longitude", longitude)
    put("address", address); put("location_description", description); put("notes", notes)
    put("inspection_interval_months", interval); put("active", active); put("version", version)
    put("created_by", createdBy); put("created_at", createdAt); put("updated_at", updatedAt); put("updated_by", updatedBy)
}.toString()

internal suspend fun ensureConflict(database: RegistryDatabase, operation: PendingHydrantChange) {
    database.withTransaction {
        val dao = database.registry()
        if(operation.state == "PENDING") dao.conflict(operation.account, operation.organization, operation.sequence)
        if(dao.conflictInfo(operation.account, operation.organization, operation.sequence) == null) {
            val local = dao.get(operation.account, operation.organization, operation.entityId)?.value
                ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
            dao.captureConflict(HydrantConflictEntity(operation.sequence, operation.orderSequence ?: operation.sequence,
                operation.account, operation.organization, operation.entityId, local.snapshot(), detectedAt = System.currentTimeMillis()))
        }
    }
}

internal suspend fun captureConflict(database: RegistryDatabase, online: HydrantRepository,
    operation: PendingHydrantChange, checkContext: () -> Unit) {
    ensureConflict(database, operation) // Durable local intent even if the subsequent GET fails.
    val dao = database.registry()
    if(dao.conflictInfo(operation.account, operation.organization, operation.sequence)?.serverState == null) {
        checkContext()
        val server = online.get(operation.organization, operation.entityId)
        checkContext()
        require(server.organization == operation.organization && server.id == operation.entityId)
        dao.captureServer(operation.account, operation.organization, operation.sequence, server.snapshot())
    }
}
