package si.gasilko.app.feature.plans

import si.gasilko.app.feature.map.navigation.*

import androidx.room.withTransaction
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import si.gasilko.app.core.database.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.data.*
import si.gasilko.app.feature.inspections.domain.*
import si.gasilko.app.feature.inspections.data.*
import java.time.Instant
import kotlinx.serialization.json.*

internal class RoomPlans(private val db: RegistryDatabase, private val online: PlanRepository,
    private val account: ()->String, private val authorize: suspend (String,String)->RegistryOrganization,
    private val refreshRegistry: suspend (String)->Unit) {
    companion object { private val remote=Mutex() }
    private fun check(actor: String) { if(account()!=actor)throw RegistryFailure(RegistryError.EXPIRED) }
    private suspend fun access(actor: String,org: String,write: Boolean=false): RegistryOrganization {
        val organization=authorize(actor,org);check(actor)
        if(!organization.active || (write && !organization.role.manages))throw RegistryFailure(RegistryError.FORBIDDEN)
        return organization
    }
    fun observe(org: String): Flow<PlanData> = flow {
        val actor=account()
        emitAll(db.invalidationTracker.createFlow("inspection_plans","inspection_plan_teams","inspection_plan_items","inspection_plan_routes","organizations","inspection_team_members","inspection_teams","pending_hydrant_changes","plan_reassignments").map {
            val authority=access(actor,org)
            val teams=db.teams().teams(actor,org).filter { it.value.active }.map { it.value.id }.toSet()
            val allowed=if(authority.role.manages)teams else db.teams().members(actor,org)
                .filter { it.value.active && it.value.userId==actor && it.value.teamId in teams }.map { it.value.teamId }.toSet()
            val pending=db.registry().pendingChanges(actor,org).filter { it.state !in listOf("SYNCED","RESOLVED") }
            db.withTransaction {
                val assignments=db.plans().reassignments(actor,org)
                PlanData(db.plans().plans(actor,org).map { it.value },db.plans().teams(actor,org).map { it.value },
                db.plans().items(actor,org).map { it.value },db.plans().routes(actor,org).map { it.value },allowed,
                pending.mapNotNull { it.planItemId() }.toSet(),pending.filter { it.state!="PENDING" }.mapNotNull { it.planItemId() }.toSet(),
                assignments.mapNotNull { it.event?.let { json -> decodeReassignment(Json.parseToJsonElement(json).jsonObject) } },
                assignments.filter { it.state=="REQUESTED" }.map { decodeReassign(it.payload!!) }).also { check(actor) } }
        }.distinctUntilChanged())
    }
    fun candidates(query: HydrantQuery): Flow<PlanCandidates> = flow {
        val actor=account();val org=query.organization
        val clock=flow { while(true) { emit(Instant.now());delay(60_000) } }
        emitAll(combine(db.invalidationTracker.createFlow("hydrants","inspections","organizations","plan_cache_coverage"),clock) { _,now ->
            val authorization=access(actor,org);val q=query.normalized(authorization.role)
            db.withTransaction {
                val rows=db.registry().list(actor,org,"",null,null,if(authorization.role.manages)null else true,null,-1).map { it.value }
                val filtered=db.registry().list(actor,org,HydrantEntity.fold(q.search),q.type,q.status,
                    when(q.active) { ActiveFilter.ALL->null;ActiveFilter.ACTIVE->true;ActiveFilter.INACTIVE->false },null,-1).map { it.value.id }.toSet()
                val coverage=db.plans().coverage(actor,org).associateBy { it.hydrantId }
                val last=db.plans().lastInspections(actor,org).associateBy { it.hydrantId }
                PlanCandidates(rows,filtered,rows.associate { h ->
                    val history=last[h.id]
                    h.id to if(coverage[h.id]?.version!=h.version || (history?.issues ?: 0)>0)null
                        else inspectionDue(history?.completedAt,h.interval,authorization.inspectionIntervalMonths,now).state
                },coverage.containsKey("")).also { check(actor) }
            }
        }.distinctUntilChanged())
    }
    private suspend fun cache(actor: String,org: String,data: PlanData) {
        access(actor,org)
        cachePlanSnapshot(db,actor,org,data) { check(actor) }
    }
    suspend fun refresh(org: String) = remote.withLock {
        val actor=account();access(actor,org);val data=online.readPlans(org);cache(actor,org,data)
    }
    suspend fun assign(org: String,change: PlanAssignment): PlanData = remote.withLock {
        val actor=account();access(actor,org,true)
        val data=online.assignPlan(org,change)
        access(actor,org,true);cache(actor,org,data);data
    }
    suspend fun navigate(request: NavigationRequest): NavigationRoute {
        val actor=account();val org=request.organization;val authority=access(actor,org)
        val data=db.plans()
        if(db.teams().teams(actor,org).none { it.value.id==request.team && it.value.active } ||
            data.plans(actor,org).none { it.value.id==request.plan && it.value.status=="ACTIVE" } ||
            data.teams(actor,org).none { it.value.planId==request.plan && it.value.teamId==request.team && it.value.active } ||
            (!authority.role.manages && db.teams().members(actor,org).none { it.value.teamId==request.team && it.value.userId==actor && it.value.active }))
            throw RegistryFailure(RegistryError.FORBIDDEN)
        val items=data.items(actor,org).filter { it.value.planId==request.plan && it.value.teamId==request.team }.map { it.value.id }.toSet()
        if(db.registry().pendingChanges(actor,org).any { it.state !in listOf("SYNCED","RESOLVED") && it.planItemId() in items })
            throw RegistryFailure(RegistryError.EXECUTION_PENDING)
        if(data.reassignments(actor,org).any { it.planId==request.plan && it.state=="REQUESTED" })
            throw RegistryFailure(RegistryError.REASSIGNMENT_PENDING)
        val result=online.navigatePlan(request)
        access(actor,org);return result.also { check(actor) }
    }
    suspend fun route(org: String,change: PlanRouting): PlanData = remote.withLock {
        val actor=account();val authority=access(actor,org)
        if(!authority.role.manages && (!change.remaining || change.teamId==null ||
            db.plans().teams(actor,org).none { it.value.planId==change.id && it.value.teamId==change.teamId && it.value.active } ||
            db.teams().teams(actor,org).none { it.value.id==change.teamId && it.value.active } ||
            db.teams().members(actor,org).none { it.value.teamId==change.teamId && it.value.userId==actor && it.value.active }))
            throw RegistryFailure(RegistryError.FORBIDDEN)
        if(db.plans().reassignments(actor,org).any { it.planId==change.id && it.state=="REQUESTED" })
            throw RegistryFailure(RegistryError.REASSIGNMENT_PENDING)
        if(change.remaining && db.registry().pendingChanges(actor,org).any { it.state !in listOf("SYNCED","RESOLVED") &&
            it.planItemId()!=null && Json.parseToJsonElement(it.payload).jsonObject["plan_id"]?.jsonPrimitive?.content==change.id })
            throw RegistryFailure(RegistryError.EXECUTION_PENDING)
        val data=online.routePlan(org,change)
        access(actor,org);cache(actor,org,data);data
    }
    suspend fun activate(org: String,change: PlanAssignment): PlanData = remote.withLock {
        val actor=account();access(actor,org,true)
        val data=online.activatePlan(org,change);access(actor,org,true);cache(actor,org,data);data
    }
    suspend fun reassign(org: String,change: PlanReassign): PlanData = remote.withLock {
        val actor=account();val authority=access(actor,org)
        val journal=db.plans().reassignments(actor,org)
        val prior=journal.find { it.id==change.id }
        if(prior!=null && prior.payload!=change.payload().toString())throw RegistryFailure(RegistryError.VALIDATION)
        if(db.registry().pendingChanges(actor,org).any { it.state !in listOf("SYNCED","RESOLVED") && it.planItemId()==change.context.itemId })
            throw RegistryFailure(RegistryError.EXECUTION_PENDING)
        if(prior==null) {
            val item=db.plans().item(actor,org,change.context.planId,change.context.itemId)?.value
                ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
            if(journal.any { it.itemId==item.id && it.state=="REQUESTED" })throw RegistryFailure(RegistryError.REASSIGNMENT_PENDING)
            if(change.reason.trim().length !in 1..2000 || change.fromTeam==change.toTeam)throw RegistryFailure(RegistryError.VALIDATION)
            if(item.inspectionId!=null || item.teamId!=change.fromTeam || item.executionVersion!=change.context.version ||
                db.plans().plans(actor,org).none { it.value.id==item.planId && it.value.status=="ACTIVE" })
                throw RegistryFailure(RegistryError.EXECUTION_CHANGED)
            val selected=db.plans().teams(actor,org).filter { it.value.planId==item.planId && it.value.active }.map { it.value.teamId }.toSet()
            val active=db.teams().teams(actor,org).filter { it.value.active }.map { it.value.id }.toSet()
            val own=db.teams().members(actor,org).filter { it.value.active && it.value.userId==actor }.map { it.value.teamId }.toSet()
            if(change.fromTeam !in selected || change.toTeam !in selected || change.toTeam !in active ||
                (!authority.role.manages && listOf(change.fromTeam,change.toTeam).none { it in own && it in active }))
                throw RegistryFailure(RegistryError.FORBIDDEN)
            check(actor)
            db.plans().reassignments(listOf(PlanReassignmentRecord(actor,org,change.id,item.planId,item.id,change.payload().toString(),null,"REQUESTED")))
        }
        // The caller holds the same local-write mutex as inspection and skip completion.
        // An uncertain network outcome stays journaled, and only a manual online retry can upload it.
        check(actor)
        val data=try { online.reassignPlanItem(org,change) } catch(e: RegistryFailure) {
            if(e.reason in listOf(RegistryError.VALIDATION,RegistryError.CONFLICT,RegistryError.EXECUTION_CHANGED))
                db.plans().rejectReassignment(actor,org,change.id)
            throw e
        }
        access(actor,org)
        if(data.reassignments.none { it.id==change.id })throw RegistryFailure(RegistryError.VALIDATION)
        cache(actor,org,data);data
    }
    private suspend fun executionReady(actor: String,org: String,item: String) {
        if(db.plans().reassignments(actor,org).any { it.itemId==item && it.state=="REQUESTED" })
            throw RegistryFailure(RegistryError.REASSIGNMENT_PENDING)
    }
    suspend fun stop(org: String,plan: String,item: String): PlanItem {
        val actor=account();val authority=access(actor,org)
        val p=db.plans().plans(actor,org).find { it.value.id==plan }?.value
            ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
        val row=db.plans().item(actor,org,plan,item)?.value ?: throw RegistryFailure(RegistryError.UNAVAILABLE)
        if(p.status!="ACTIVE" || !row.active || row.teamId==null ||
            db.plans().teams(actor,org).none { it.value.planId==plan && it.value.teamId==row.teamId && it.value.active } ||
            (!authority.role.manages && (db.teams().teams(actor,org).none { it.value.id==row.teamId && it.value.active } ||
                db.teams().members(actor,org).none { it.value.teamId==row.teamId && it.value.userId==actor && it.value.active })))
            throw RegistryFailure(RegistryError.FORBIDDEN)
        check(actor);return row
    }
    suspend fun completeLocal(org: String,context: PlanStopContext,hydrant: String,id: String,at: Long) {
        val actor=account();val row=stop(org,context.planId,context.itemId)
        executionReady(actor,org,row.id)
        if(row.hydrantId!=hydrant)throw RegistryFailure(RegistryError.VALIDATION)
        if(row.inspectionId==id)return
        if(row.inspectionId!=null || row.executionVersion!=context.version)throw RegistryFailure(RegistryError.EXECUTION_CHANGED)
        db.plans().staleRoute(actor,org,row.planId,row.teamId!!)
        db.plans().items(listOf(PlanItemEntity(actor,row.copy(executionVersion=row.executionVersion+1,
            inspectionId=id,completedBy=actor,completedAt=Instant.ofEpochMilli(at).toString(),skipReason=null,skippedBy=null,skippedAt=null))))
    }
    suspend fun skip(org: String,change: PlanSkip) = db.withTransaction {
        val actor=account();val row=stop(org,change.context.planId,change.context.itemId)
        executionReady(actor,org,row.id)
        val payload=change.payload().toString()
        val prior=db.registry().pendingChanges(actor,org).find { it.operationId==change.id }
        if(prior!=null) {
            if(prior.operation!=SKIP_PLAN_ITEM || prior.payload!=payload)throw RegistryFailure(RegistryError.VALIDATION)
            return@withTransaction
        }
        if(change.reason.trim().length !in 1..2000)throw RegistryFailure(RegistryError.VALIDATION)
        if(row.inspectionId!=null || row.executionVersion!=change.context.version)throw RegistryFailure(RegistryError.EXECUTION_CHANGED)
        db.plans().items(listOf(PlanItemEntity(actor,row.copy(executionVersion=row.executionVersion+1,
            skipReason=change.reason.trim(),skippedBy=actor,skippedAt=change.at))))
        db.registry().enqueue(PendingHydrantChange(operationId=change.id,account=actor,organization=org,entityId=row.hydrantId,
            operation=SKIP_PLAN_ITEM,payload=payload,baseVersion=null,createdAt=System.currentTimeMillis()))
        check(actor)
    }
    suspend fun save(org: String,change: PlanSave): PlanData = remote.withLock {
        val actor=account();access(actor,org,true);val data=online.savePlan(org,change);access(actor,org,true);cache(actor,org,data);data
    }
    // One paginated organization read, not one request for every hydrant.
    // Reuse immutable inspection reconciliation. This refresh never acknowledges/reorders queue operations.
    suspend fun refreshCandidates(org: String) = remote.withLock {
        val actor=account();access(actor,org,true)
        refreshRegistry(org);check(actor)
        val hydrants=db.registry().list(actor,org,"",null,null,null,null,-1).map { it.value }
        val rows=mutableListOf<Inspection>();var after: String?=null
        do {
            val page=online.listPlanInspections(org,after)
            if(page.any { it.organization!=org || (after!=null && it.id<=after!!) })throw RegistryFailure(RegistryError.VALIDATION)
            rows.addAll(page);after=page.lastOrNull()?.id
        } while(page.size==100)
        access(actor,org,true)
        db.withTransaction {
            val operations=db.registry().pendingChanges(actor,org).filter { it.operation==CREATE_INSPECTION }.associateBy { it.operationId }
            rows.forEach { event ->
                val existing=db.registry().inspectionIdentity(actor,event.id)
                if(existing!=null && existing.value.organization!=org)throw RegistryFailure(RegistryError.VALIDATION)
                val operation=operations[event.id]
                if(existing==null)db.registry().cacheInspections(listOf(InspectionEntity(actor,event,System.currentTimeMillis())))
                else if(!existing.matchesServer(event) || (operation!=null && !operation.matchesServer(event)))
                    recordInspectionIssue(db,actor,org,event.id,"SERVER_EVENT_MISMATCH")
            }
            db.plans().coverage(hydrants.map { PlanCoverage(actor,org,it.id,it.version,System.currentTimeMillis()) })
            check(actor)
        }
    }
}

