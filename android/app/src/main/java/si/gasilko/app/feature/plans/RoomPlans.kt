package si.gasilko.app.feature.plans

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
        emitAll(db.invalidationTracker.createFlow("inspection_plans","inspection_plan_teams","inspection_plan_items","inspection_plan_routes","organizations").map {
            access(actor,org)
            db.withTransaction { PlanData(db.plans().plans(actor,org).map { it.value },db.plans().teams(actor,org).map { it.value },
                db.plans().items(actor,org).map { it.value },db.plans().routes(actor,org).map { it.value }).also { check(actor) } }
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
        if(data.routes.any { r -> r.organization!=org || data.teams.none { it.planId==r.planId && it.teamId==r.teamId } })
            throw RegistryFailure(RegistryError.VALIDATION)
        if(data.plans.any { it.organization!=org } || data.teams.any { t -> t.organization!=org || data.plans.none { it.id==t.planId } } ||
            data.items.any { i -> i.organization!=org || data.plans.none { it.id==i.planId } ||
                (i.teamId!=null && data.teams.none { it.planId==i.planId && it.teamId==i.teamId && (!i.active || it.active) }) })throw RegistryFailure(RegistryError.VALIDATION)
        db.withTransaction {
            access(actor,org)
            db.plans().plans(data.plans.map { PlanEntity(actor,it) });db.plans().teams(data.teams.map { PlanTeamEntity(actor,it) })
            db.plans().items(data.items.map { PlanItemEntity(actor,it) })
            db.plans().routes(data.routes.map { PlanRouteEntity(actor,it) });check(actor)
        }
    }
    suspend fun refresh(org: String) = remote.withLock {
        val actor=account();access(actor,org);val data=online.readPlans(org);cache(actor,org,data)
    }
    suspend fun assign(org: String,change: PlanAssignment): PlanData = remote.withLock {
        val actor=account();access(actor,org,true)
        val data=online.assignPlan(org,change)
        access(actor,org,true);cache(actor,org,data);data
    }
    suspend fun route(org: String,change: PlanRouting): PlanData = remote.withLock {
        val actor=account();access(actor,org,true)
        val data=online.routePlan(org,change)
        access(actor,org,true);cache(actor,org,data);data
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

