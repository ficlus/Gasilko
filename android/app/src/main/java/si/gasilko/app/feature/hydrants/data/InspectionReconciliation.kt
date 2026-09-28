package si.gasilko.app.feature.hydrants.data

import androidx.room.withTransaction
import kotlinx.serialization.json.*
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.data.*
import si.gasilko.app.feature.inspections.domain.*

internal fun InspectionEntity.matchesServer(event: Inspection): Boolean =
    value.organization==event.organization && value.hydrantId==event.hydrantId && value.inspectorId==event.inspectorId &&
        value.completion().sameEvent(event.completion()) &&
        (acknowledgedAt==null || (value.createdAt==event.createdAt &&
            value.hydrantVersionBefore==event.hydrantVersionBefore && value.hydrantVersionAfter==event.hydrantVersionAfter))

internal fun PendingHydrantChange.matchesServer(event: Inspection): Boolean = runCatching {
    operationId==event.id && organization==event.organization && entityId==event.hydrantId && account==event.inspectorId &&
        Json.parseToJsonElement(payload).jsonObject.inspectionCompletion().sameEvent(event.completion())
}.getOrDefault(false)

internal suspend fun recordInspectionIssue(database: RegistryDatabase, account: String, organization: String,
    id: String, issue: String) = database.withTransaction {
    database.registry().inspectionIssue(account,organization,id,issue)
    database.registry().blockInspection(account,organization,id)
}

/** Shared acknowledgement path for RPC receipts and history receipts. Caller holds
 * hydrantRemoteAccess. Only the ordered head can advance, never a later operation. */
internal suspend fun acknowledgeHydrantOperation(database: RegistryDatabase, operation: PendingHydrantChange,
    server: Hydrant, event: Inspection?, checkContext: ()->Unit): Boolean = database.withTransaction {
    checkContext()
    val dao=database.registry()
    val account=operation.account;val organization=operation.organization
    val head=dao.nextChange(account,organization)
    if(head==null || head.sequence!=operation.sequence || head.state!="PENDING")return@withTransaction false
    require(server.id==operation.entityId && server.organization==organization && server.version>0)
    val previous=dao.acknowledgedVersion(account,organization,operation.entityId,operation.orderSequence ?: operation.sequence)
    val version=maxOf(operation.baseVersion ?: 0,previous ?: 0)
    val chainVersion=if(event==null || (event.hydrantVersionBefore==version && event.hydrantVersionAfter==server.version))server.version else null
    if(event!=null) {
        val local=dao.inspection(account,organization,operation.operationId)
            ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
        if(local.syncIssue!=null)return@withTransaction false
        if(!local.matchesServer(event) || !operation.matchesServer(event) ||
            event.hydrantVersionBefore==null || event.hydrantVersionAfter==null) {
            recordInspectionIssue(database,account,organization,operation.operationId,"SERVER_EVENT_MISMATCH")
            return@withTransaction false
        }
        check(dao.acknowledgeInspection(account,organization,event.id,event.createdAt,
            event.hydrantVersionBefore,event.hydrantVersionAfter,System.currentTimeMillis())==1)
    }
    check(dao.acknowledge(account,organization,operation.sequence,chainVersion)==1)
    var visible=server
    dao.remainingChanges(account,organization,server.id).forEach { visible=it.applyTo(visible) }
    dao.upsertHydrants(listOf(HydrantEntity.from(account,visible)))
    checkContext()
    true
}
