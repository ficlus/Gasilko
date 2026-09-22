package si.gasilko.app.feature.hydrants.domain

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf

enum class SyncPhase { SYNCHRONIZED, PENDING, SYNCING, RETRY, CONFLICT }
data class RegistrySyncState(val organization: String = "", val phase: SyncPhase = SyncPhase.PENDING,
    val pendingIds: Set<String> = emptySet(), val conflicts: List<HydrantConflict> = emptyList())

enum class RegistryRole { FIREFIGHTER, MANAGER, ADMIN;
    val manages: Boolean get() = this != FIREFIGHTER
}
enum class HydrantStatus { WORKING, NOT_WORKING, NEEDS_INSPECTION, UNKNOWN }
enum class ActiveFilter { ACTIVE, INACTIVE, ALL }
enum class ConflictResolution { KEEP_SERVER, KEEP_LOCAL }
data class HydrantConflict(val sequence: Long, val account: String, val organization: String,
    val operation: String, val payload: String, val local: Hydrant, val server: Hydrant?, val intent: Hydrant = local)
data class HydrantQuery(val organization: String = "", val search: String = "", val type: String? = null,
    val status: HydrantStatus? = null, val active: ActiveFilter = ActiveFilter.ACTIVE) {
    fun normalized(role: RegistryRole) = copy(search=search.trim().take(200),active=if(role==RegistryRole.FIREFIGHTER)ActiveFilter.ACTIVE else active)
    val filtered get() = search.isNotBlank() || type!=null || status!=null || active!=ActiveFilter.ACTIVE
    /** Reconcile visible rows only; repository performs the actual bounded query. */
    fun matches(h: Hydrant): Boolean = h.organization==organization && (type==null || h.type==type) &&
        (status==null || h.status==status) && (active==ActiveFilter.ALL || h.active==(active==ActiveFilter.ACTIVE)) &&
        (search.isBlank() || listOf(h.code,h.address,h.description).any { it?.contains(search.trim(),ignoreCase=true)==true })
}
data class RegistryOrganization(val id: String, val name: String, val role: RegistryRole, val active: Boolean = true)
data class HydrantType(val id: String, val organization: String?, val code: String, val name: String, val active: Boolean)
data class Hydrant(
    val id: String, val organization: String, val code: String?, val type: String,
    val status: HydrantStatus, val latitude: Double? = null, val longitude: Double? = null,
    val address: String? = null, val description: String? = null, val notes: String? = null,
    val interval: Int? = null, val active: Boolean = true, val version: Long = 1,
    val createdBy: String = "",
    val createdAt: String? = null, val updatedAt: String? = null, val updatedBy: String? = null,
)
data class HydrantFields(val type: String, val latitude: Double?, val longitude: Double?,
    val address: String?, val description: String?, val notes: String?, val interval: Int?,
    val status: HydrantStatus = HydrantStatus.UNKNOWN)
enum class RegistryError { NETWORK, EXPIRED, FORBIDDEN, VALIDATION, CONFLICT, SERVER, UNAVAILABLE, LOCATION, COORDINATES, INTERVAL, TYPE }
class RegistryFailure(val reason: RegistryError) : Exception()
data class HydrantForm(
    val id: String, val type: String = "", val latitude: String = "", val longitude: String = "",
    val address: String = "", val description: String = "", val notes: String = "", val interval: String = "",
    val status: HydrantStatus = HydrantStatus.UNKNOWN, val baseVersion: Long? = null,
) {
    fun fields(): HydrantFields {
        if (type.isBlank()) throw RegistryFailure(RegistryError.TYPE)
        fun coordinate(text: String): Double? {
            if (text.isBlank()) return null
            val decimal=text.trim().replace(',', '.')
            if(!Regex("[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)").matches(decimal)) throw RegistryFailure(RegistryError.COORDINATES)
            return decimal.toDoubleOrNull()?.takeIf { it.isFinite() }
                ?: throw RegistryFailure(RegistryError.COORDINATES)
        }
        val lat = coordinate(latitude); val lon = coordinate(longitude)
        if ((lat == null) != (lon == null) || (lat != null && lat !in -90.0..90.0) || (lon != null && lon !in -180.0..180.0))
            throw RegistryFailure(RegistryError.COORDINATES)
        if (lat == null && address.isBlank() && description.isBlank()) throw RegistryFailure(RegistryError.LOCATION)
        val months = if (interval.isBlank()) null else interval.trim().toIntOrNull()?.takeIf { it > 0 }
            ?: throw RegistryFailure(RegistryError.INTERVAL)
        return HydrantFields(type, lat, lon, address.trim().ifBlank { null }, description.trim().ifBlank { null },
            notes.trim().ifBlank { null }, months, status)
    }
    companion object {
        fun from(h: Hydrant) = HydrantForm(h.id, h.type, h.latitude?.toString().orEmpty(), h.longitude?.toString().orEmpty(),
            h.address.orEmpty(), h.description.orEmpty(), h.notes.orEmpty(), h.interval?.toString().orEmpty(), h.status, h.version)
    }
}
/** UI reads use Room. Explicit refresh is temporary online hydration, not synchronization. */
interface HydrantRepository {
    fun observeMap(query: HydrantQuery): Flow<List<Hydrant>> = flowOf(emptyList())
    fun observeSync(organization: String): Flow<RegistrySyncState> = flowOf(RegistrySyncState(organization))
    suspend fun conflicts(organization: String): List<HydrantConflict> = emptyList()
    suspend fun resolveConflict(organization: String, sequence: Long, resolution: ConflictResolution) {
        throw RegistryFailure(RegistryError.UNAVAILABLE)
    }
    fun setActiveOrganization(organization: String?) {}
    fun requestSync(organization: String) {}
    suspend fun refreshOrganizations() {}
    suspend fun refresh(organization: String) {}
    suspend fun refreshDetail(organization: String, id: String) {}
    suspend fun organizations(): List<RegistryOrganization>
    suspend fun types(organization: String): List<HydrantType>
    suspend fun list(query: HydrantQuery, after: String? = null): List<Hydrant>
    suspend fun get(organization: String, id: String): Hydrant
    suspend fun create(organization: String, id: String, fields: HydrantFields): Hydrant
    suspend fun changeStatus(organization: String, id: String, status: HydrantStatus, version: Long): Hydrant
    suspend fun update(organization: String, id: String, fields: HydrantFields, version: Long): Hydrant
    suspend fun setActive(organization: String, id: String, active: Boolean, version: Long): Hydrant
}
