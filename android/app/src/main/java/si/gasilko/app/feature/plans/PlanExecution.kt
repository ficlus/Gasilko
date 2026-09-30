package si.gasilko.app.feature.plans

import androidx.room.withTransaction
import kotlinx.serialization.json.*
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.data.CREATE_INSPECTION

internal fun PendingHydrantChange.planItemId(): String? {
    if(operation!=SKIP_PLAN_ITEM && operation!=CREATE_INSPECTION)return null
    val p=Json.parseToJsonElement(payload).jsonObject
    return p[if(operation==SKIP_PLAN_ITEM)"item_id" else "plan_item_id"]?.jsonPrimitive?.contentOrNull
}
internal fun PlanItem.context()=PlanStopContext(planId,id,executionVersion)
internal suspend fun cachePlanSnapshot(db: RegistryDatabase,actor: String,org: String,data: PlanData,check: ()->Unit) = db.withTransaction {
    check()
    if(data.plans.any { it.organization!=org } ||
        data.teams.any { t -> t.organization!=org || data.plans.none { it.id==t.planId } } ||
        data.items.any { i -> i.organization!=org || data.plans.none { it.id==i.planId } ||
            (i.teamId!=null && data.teams.none { it.planId==i.planId && it.teamId==i.teamId }) } ||
        data.routes.any { r -> r.organization!=org || data.teams.none { it.planId==r.planId && it.teamId==r.teamId } } ||
        data.reassignments.any { r -> r.organization!=org || data.items.none { it.planId==r.planId && it.id==r.itemId } ||
            listOf(r.fromTeam,r.toTeam).any { team -> data.teams.none { it.planId==r.planId && it.teamId==team } } })
        throw RegistryFailure(RegistryError.VALIDATION)
    val previous=db.plans().plans(actor,org).associate { it.value.id to it.value.version }
    val accepted=data.plans.filter { it.version >= (previous[it.id] ?: 0) }
    val ids=accepted.map { it.id }.toSet()
    val priorRoutes=db.plans().routes(actor,org).associate { (it.value.planId to it.value.teamId) to it.value }
    db.plans().plans(accepted.map { PlanEntity(actor,it) })
    db.plans().teams(data.teams.filter { it.planId in ids }.map { PlanTeamEntity(actor,it) })
    cachePlanItems(db,actor,org,data.items.filter { it.planId in ids })
    db.plans().routes(data.routes.filter { it.planId in ids }.map { route ->
        val prior=priorRoutes[route.planId to route.teamId]
        PlanRouteEntity(actor,if(prior!=null && prior.calculatedAt==route.calculatedAt && !prior.valid)route.copy(valid=false) else route)
    })
    val requests=db.plans().reassignments(actor,org).associateBy { it.id }
    db.plans().reassignments(data.reassignments.map { event ->
        val prior=requests[event.id]
        prior?.payload?.let { payload ->
            val request=decodeReassign(payload)
            if(event.actor!=actor || event.planId!=request.context.planId || event.itemId!=request.context.itemId ||
                event.fromTeam!=request.fromTeam || event.toTeam!=request.toTeam || event.reason!=request.reason.trim() ||
                event.version!=request.context.version+1)throw RegistryFailure(RegistryError.VALIDATION)
        }
        PlanReassignmentRecord(actor,org,event.id,event.planId,event.itemId,prior?.payload,event.payload().toString(),"ACKNOWLEDGED")
    })
    check()
}
// A remote refresh/earlier receipt may update route order, but must retain later local execution intent.
internal suspend fun cachePlanItems(db: RegistryDatabase,actor: String,org: String,rows: List<PlanItem>,ack: Long?=null) {
    val pending=db.registry().pendingChanges(actor,org).filter { it.sequence!=ack && it.state !in listOf("SYNCED","RESOLVED") }
        .mapNotNull { it.planItemId() }.toSet()
    val merged=rows.map { server ->
        val local=db.plans().item(actor,org,server.planId,server.id)?.value
        val assigned=if(local!=null && local.assignmentVersion>server.assignmentVersion)
            server.copy(teamId=local.teamId,assignmentVersion=local.assignmentVersion,routeOrder=local.routeOrder) else server
        if(local!=null && (server.id in pending || local.executionVersion>server.executionVersion))
            assigned.copy(executionVersion=local.executionVersion,inspectionId=local.inspectionId,completedBy=local.completedBy,
                completedAt=local.completedAt,skipReason=local.skipReason,skippedBy=local.skippedBy,skippedAt=local.skippedAt)
        else assigned
    }
    db.plans().items(merged.map { PlanItemEntity(actor,it) })
}
internal suspend fun uploadPlanSkip(db: RegistryDatabase,online: PlanRepository,operation: PendingHydrantChange,check: ()->Unit) {
    val payload=Json.parseToJsonElement(operation.payload).jsonObject
    val receipt=try { online.uploadPlanSkip(operation.organization,payload) }
    catch(e: RegistryFailure) {
        if(e.reason==RegistryError.VALIDATION)db.registry().blockExecution(operation.account,operation.organization,operation.sequence)
        throw e
    }
    check()
    if(receipt.id!=payload.getValue("item_id").jsonPrimitive.content ||
        receipt.planId!=payload.getValue("plan_id").jsonPrimitive.content || receipt.organization!=operation.organization ||
        receipt.hydrantId!=operation.entityId || receipt.skippedBy!=operation.account ||
        receipt.executionVersion!=payload.getValue("version").jsonPrimitive.long+1 ||
        receipt.skipReason!=payload.getValue("reason").jsonPrimitive.content)
        throw RegistryFailure(RegistryError.VALIDATION)
    db.withTransaction {
        check()
        val head=db.registry().nextChange(operation.account,operation.organization)
        if(head?.sequence!=operation.sequence || head.state!="PENDING")return@withTransaction
        cachePlanItems(db,operation.account,operation.organization,listOf(receipt),operation.sequence)
        kotlin.check(db.registry().acknowledge(operation.account,operation.organization,operation.sequence,null)==1)
        check()
    }
}
