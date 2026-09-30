package si.gasilko.app.feature.inspections.domain

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import si.gasilko.app.feature.hydrants.domain.*
import java.math.BigDecimal
import java.util.UUID

enum class InspectionMode { QUICK, GUIDED, CLASSIC }
enum class InspectionResult { PASS, PASS_WITH_ISSUES, FAIL, NOT_INSPECTED;
    val hydrantStatus: HydrantStatus? get() = when(this) {
        PASS -> HydrantStatus.WORKING
        PASS_WITH_ISSUES -> HydrantStatus.NEEDS_INSPECTION
        FAIL -> HydrantStatus.NOT_WORKING
        NOT_INSPECTED -> null
    }
}

/** Completed event input. Times are UTC epoch milliseconds; retain this UUID on retry. */
data class InspectionCompletion(
    val mode: InspectionMode, val result: InspectionResult, val startedAt: Long, val completedAt: Long,
    val notes: String? = null, val pressureBar: Double? = null, val flowLMin: Double? = null,
    val id: String = UUID.randomUUID().toString(),
    val planContext: si.gasilko.app.feature.plans.PlanStopContext? = null,
) {
    fun sameEvent(other: InspectionCompletion): Boolean {
        fun sameNumber(a: Double?, b: Double?) = if(a==null || b==null) a==b
            else BigDecimal.valueOf(a).compareTo(BigDecimal.valueOf(b))==0
        // Plan linkage is validated separately against the explicit plan-item receipt.
        return copy(pressureBar=null,flowLMin=null,planContext=null)==other.copy(pressureBar=null,flowLMin=null,planContext=null) &&
            sameNumber(pressureBar,other.pressureBar) && sameNumber(flowLMin,other.flowLMin)
    }
    fun validate() {
        fun measurement(value: Double?, maximum: Double) = value==null ||
            (value.isFinite() && value in 0.0..maximum && BigDecimal.valueOf(value).stripTrailingZeros().scale()<=2)
        if(runCatching { UUID.fromString(id).toString() }.getOrNull()!=id ||
            startedAt !in 0..253402300799999L || completedAt !in startedAt..253402300799999L ||
            !measurement(pressureBar,999.99) || !measurement(flowLMin,999999.99))
            throw RegistryFailure(RegistryError.VALIDATION)
    }
}
data class Inspection(
    val id: String, val hydrantId: String, val organization: String, val inspectorId: String,
    val mode: InspectionMode, val result: InspectionResult, val startedAt: Long, val completedAt: Long,
    val notes: String?, val pressureBar: Double?, val flowLMin: Double?, val createdAt: Long,
    val hydrantVersionBefore: Long? = null, val hydrantVersionAfter: Long? = null,
) {
    fun completion() = InspectionCompletion(mode,result,startedAt,completedAt,notes,pressureBar,flowLMin,id)
}
/** Local writes return local state; only the sync engine treats the online result as acknowledgement. */
data class InspectionWrite(val inspection: Inspection, val hydrant: Hydrant, val planItem: si.gasilko.app.feature.plans.PlanItem? = null)
enum class InspectionSyncState { SYNCED, PENDING, ATTENTION }
data class InspectionHistoryEntry(val inspection: Inspection, val state: InspectionSyncState,
    val durableIssue: Boolean = false)
interface InspectionRepository {
    suspend fun completeInspectionWithPhotos(organization: String, hydrantId: String, input: InspectionCompletion,
        photos: List<si.gasilko.app.feature.photos.domain.LocalPhotoInput>): InspectionWrite {
        if(photos.isNotEmpty())throw RegistryFailure(RegistryError.UNAVAILABLE)
        return completeInspection(organization,hydrantId,input)
    }
    fun observeInspectionHistory(organization: String, hydrantId: String): Flow<List<InspectionHistoryEntry>> =
        observeInspections(organization,hydrantId).map { rows -> rows.map { InspectionHistoryEntry(it,InspectionSyncState.PENDING) } }
    fun observeInspections(organization: String, hydrantId: String): Flow<List<Inspection>> = flowOf(emptyList())
    suspend fun completeInspection(organization: String, hydrantId: String, input: InspectionCompletion): InspectionWrite {
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    suspend fun refreshInspections(organization: String, hydrantId: String) {}
    /** UUID pagination is used only for explicit online hydration; local observation sorts by completion time. */
    suspend fun listInspections(organization: String, hydrantId: String, after: String? = null): List<Inspection> = emptyList()
}
