package si.gasilko.app.feature.incidents

import si.gasilko.app.feature.map.domain.GeoPoint

/** C3 decision B: policy/display only. No current REAL observation adapter exists. */
internal const val REAL_UNIT_STALE_SECONDS=120
internal const val REAL_UNIT_EXPIRE_SECONDS=900
internal enum class RealUnitAvailability { UNAVAILABLE,LOCKED }
internal data class RealUnitBinding(val account: String,val organization: String,val incident: String,val unit: String,val fingerprint: String)
internal class RealUnitPositionView internal constructor(val binding: RealUnitBinding,val availability: RealUnitAvailability) {
    // Deliberately not constructor/copy inputs: route/SIM/refetch data cannot populate these.
    val coordinate: GeoPoint?=null
    val positionOrigin: String?=null
    val observedAt: String?=null
    val ageSeconds: Long?=null
    val accuracyM: Double?=null
    val sourceRevision: String?=null
    val serverAsOf: String?=null
}
/** Existing B1 unit-name permission is NOT a GPS permission. No JSON observation accepted. */
internal fun realUnitPositionView(binding: RealUnitBinding,scopeAuthorized: Boolean): RealUnitPositionView {
    val valid=scopeAuthorized && listOf(binding.account,binding.organization,binding.incident,binding.unit).all(::canonicalUuid) &&
        Regex("[0-9a-f]{32}").matches(binding.fingerprint)
    return RealUnitPositionView(binding,if(valid)RealUnitAvailability.UNAVAILABLE else RealUnitAvailability.LOCKED)
}
