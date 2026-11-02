package si.gasilko.app.feature.incidents

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** C2 safe subset. There is deliberately no ACTIVE state or sample/session input. */
internal enum class VehicleLocationCheck { DISABLED,UNAVAILABLE }
internal const val VEHICLE_LOCATION_PRODUCER_ENABLED=false

internal fun disabledVehicleCapability(value: JsonObject,account: String,org: String,incident: String): Boolean {
    val keys=setOf("schema_version","account","organization","incident_id","scope_fingerprint","mode","state",
        "enabled","producer_available","reader_available","policy_approved","retention_ready","device_binding_ready")
    val off=listOf("enabled","producer_available","reader_available","policy_approved","retention_ready","device_binding_ready")
    return !VEHICLE_LOCATION_PRODUCER_ENABLED && listOf(account,org,incident).all(::canonicalUuid) &&
        value.keys==keys && value.text("schema_version")=="1" && value.text("account")==account &&
        value.text("organization")==org && value.text("incident_id")==incident &&
        Regex("[0-9a-f]{32}").matches(value.text("scope_fingerprint")) &&
        value.text("mode") in listOf("REAL","TRAINING") && value.text("state")=="DISABLED" &&
        off.all {value[it]==JsonPrimitive(false)}
}
