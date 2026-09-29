package si.gasilko.app.feature.plans

import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.domain.*
import java.time.Instant
import java.util.UUID

enum class PlanStatus { DRAFT, PLANNED, ACTIVE, COMPLETED, CANCELLED }
enum class SelectionMode { MANUAL, OVERDUE, DUE_SOON_AND_OVERDUE, ALL, CURRENT_FILTER }
data class InspectionPlan(val id: String, val organization: String, val name: String, val status: String,
    val selectionMode: String, val selectionSnapshot: String, val startLatitude: Double?, val startLongitude: Double?,
    val returnToStart: Boolean, val createdBy: String, val createdAt: String, val updatedAt: String,
    val startedAt: String?, val completedAt: String?, val version: Long)
data class PlanTeam(val planId: String, val organization: String, val teamId: String, val active: Boolean)
data class PlanItem(val id: String, val planId: String, val organization: String, val hydrantId: String,
    val active: Boolean, val createdAt: String, val teamId: String? = null)
data class PlanData(val plans: List<InspectionPlan> = emptyList(), val teams: List<PlanTeam> = emptyList(),
    val items: List<PlanItem> = emptyList())
data class PlanCandidates(val hydrants: List<Hydrant> = emptyList(), val filteredIds: Set<String> = emptySet(),
    val due: Map<String,InspectionDueState?> = emptyMap(), val registryCached: Boolean = false) {
    val incomplete get() = !registryCached || hydrants.any { it.active && due[it.id]==null }
    fun select(mode: SelectionMode): Set<String> = hydrants.filter { h ->
        h.active && when(mode) {
            SelectionMode.ALL -> true
            SelectionMode.CURRENT_FILTER -> h.id in filteredIds
            SelectionMode.OVERDUE -> due[h.id]==InspectionDueState.OVERDUE
            SelectionMode.DUE_SOON_AND_OVERDUE -> due[h.id] in listOf(InspectionDueState.DUE_SOON,InspectionDueState.OVERDUE)
            SelectionMode.MANUAL -> false
        }
    }.map { it.id }.toSet()
}
data class PlanSave(val id: String, val version: Long, val name: String, val status: PlanStatus,
    val mode: SelectionMode, val snapshot: String, val latitude: Double?, val longitude: Double?,
    val returnToStart: Boolean, val teams: List<String>, val hydrants: List<String>,
    val operationId: String = UUID.randomUUID().toString()) {
    fun payload() = buildJsonObject {
        put("id",id);put("version",version);put("operation_id",operationId);put("name",name);put("status",status.name)
        put("selection_mode",mode.name);put("selection_snapshot",Json.parseToJsonElement(snapshot))
        put("start_latitude",latitude);put("start_longitude",longitude);put("return_to_start",returnToStart)
        put("teams",JsonArray(teams.map { JsonPrimitive(it) }));put("hydrants",JsonArray(hydrants.map { JsonPrimitive(it) }))
    }
}
fun planSelectionSnapshot(query: HydrantQuery, incomplete: Boolean) = buildJsonObject {
    put("search",query.search);put("type",query.type);put("status",query.status?.name);put("active",query.active.name)
    put("cache_incomplete",incomplete);put("selected_at",Instant.now().toString())
}.toString()
data class PlanAssignment(val id: String, val version: Long, val operationId: String = UUID.randomUUID().toString()) {
    fun payload() = buildJsonObject {
        put("id",id);put("version",version);put("operation_id",operationId);put("action","ASSIGN")
    }
}
interface PlanRepository {
    suspend fun assignPlan(org: String, change: PlanAssignment): PlanData = throw RegistryFailure(RegistryError.UNAVAILABLE)
    fun observePlans(org: String): Flow<PlanData> = flowOf(PlanData())
    fun observePlanCandidates(query: HydrantQuery): Flow<PlanCandidates> = flowOf(PlanCandidates())
    suspend fun refreshPlans(org: String) {}
    suspend fun refreshPlanCandidates(org: String) {}
    suspend fun readPlans(org: String): PlanData = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun savePlan(org: String, change: PlanSave): PlanData = throw RegistryFailure(RegistryError.UNAVAILABLE)
    suspend fun listPlanInspections(org: String, after: String?): List<Inspection> = throw RegistryFailure(RegistryError.UNAVAILABLE)
}
internal fun decodePlans(value: JsonElement): PlanData {
    fun JsonObject.s(k: String)=getValue(k).jsonPrimitive.content
    fun JsonObject.optional(k: String)=get(k)?.jsonPrimitive?.contentOrNull
    fun JsonObject.b(k: String)=getValue(k).jsonPrimitive.boolean
    fun rows(k: String)=value.jsonObject.getValue(k).jsonArray.map { it.jsonObject }
    return PlanData(rows("plans").map { InspectionPlan(it.s("id"),it.s("organization_id"),it.s("name"),it.s("status"),
        it.s("selection_mode"),it.getValue("selection_snapshot").toString(),it.optional("start_latitude")?.toDouble(),
        it.optional("start_longitude")?.toDouble(),it.b("return_to_start"),it.s("created_by"),it.s("created_at"),
        it.s("updated_at"),it.optional("started_at"),it.optional("completed_at"),it.s("version").toLong()) },
        rows("teams").map { PlanTeam(it.s("plan_id"),it.s("organization_id"),it.s("team_id"),it.b("active")) },
        rows("items").map { PlanItem(it.s("id"),it.s("plan_id"),it.s("organization_id"),it.s("hydrant_id"),it.b("active"),it.s("created_at"),it.optional("team_id")) })
}

