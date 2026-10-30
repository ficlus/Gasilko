package si.gasilko.app.feature.incidents

import kotlinx.serialization.json.*

internal val leaderRpcs=setOf("incident_issue_task","incident_update_unit_status",
    "incident_add_crew_member","incident_remove_crew_member","incident_transition_resource_allocation")
internal fun leaderStamp(unit: JsonObject)=unit.obj("leader_assignment").text("id")+"/"+unit.obj("leader_assignment").text("version")
internal fun isCurrentLeader(incident: JsonObject,unit: JsonObject)=incident.text("leadership_schema")=="1" &&
    incident.text("status") in listOf("ACTIVE","STABILIZED") && unit.flag("leader") &&
    canonicalUuid(unit.obj("leader_assignment").text("id"))
internal fun unitAssignments(incident: JsonObject,unit: String)=incident.rows("assignments")
    .filter { it.text("unit_id")==unit }.sortedBy { it.text("id") }
internal fun resourceTransitions(row: JsonObject)=if(!row.flag("can_transition"))emptyList() else when(row.text("status")) {
    "RESERVED"->listOf("DEPLOYED","CANCELLED")
    "DEPLOYED"->listOf("RETURNED","CONSUMED")
    else->emptyList()
}
/** Presentation/candidate validation only. The existing RPC is the commit authority. */
internal fun validateLeaderPayload(incident: JsonObject,unit: JsonObject,rpc: String,payload: JsonObject) {
    require(isCurrentLeader(incident,unit)) { "NOT_AUTHORIZED" }
    when(rpc) {
        "incident_issue_task" -> require(unit.rows("crew").any {
            it.text("id")==payload.rows("recipients").single().text("recipient_id") && it.flag("can_issue") && it.text("status")=="ACTIVE"
        }) { "INVALID_TASK_RECIPIENT" }
        "incident_update_unit_status" -> require(payload.text("id")==unit.text("id") && payload.text("version")==unit.text("version") &&
            unit["status_actions"]?.jsonArray?.any { it.jsonPrimitive.content==payload.text("status") }==true) { "INVALID_UNIT_STATUS" }
        "incident_add_crew_member" -> require(unit.flag("can_manage_crew") && payload.text("unit_assignment_id")==unit.text("id") &&
            canonicalUuid(payload.text("id")) && canonicalUuid(payload.text("user_id")) &&
            payload.text("crew_role") in listOf("LEADER","DRIVER","RESPONDER","SPECIALIST")) { "INVALID_CREW_MEMBER" }
        "incident_remove_crew_member" -> require(unit.rows("crew").any {
            it.text("id")==payload.text("id") && it.text("version")==payload.text("version") && it.flag("can_leave")
        }) { "INVALID_CREW_MEMBER" }
        "incident_transition_resource_allocation" -> require(unit.rows("resources").any {
            it.text("id")==payload.text("id") && it.text("version")==payload.text("version") && payload.text("status") in resourceTransitions(it)
        }) { "INVALID_RESOURCE_STATUS" }
        else -> error("NOT_AUTHORIZED")
    }
}

internal fun leaderError(message: String?): String = listOf("NOT_AUTHORIZED","MANIFEST_SCOPE_CHANGED","SCOPE_CHANGED","STALE_VERSION",
    "INVALID_UNIT_STATUS","UNIT_HAS_ACTIVE_COMMAND","UNIT_HAS_ACTIVE_CREW","RESOURCE_IN_USE","UNRESOLVED_TASKS",
    "INVALID_CREW_MEMBER","INVALID_RESOURCE_STATUS","INVALID_TASK_RECIPIENT","INVALID_ACTION_DEFINITION","OPERATION_REUSED",
    "SIMULATION_RESOURCE_DISABLED","INSUFFICIENT_RESOURCE_QUANTITY","RESOURCE_LIMIT_REACHED","INCIDENT_TERMINAL",
    "VALIDATION_FAILED","CATALOG_LIMIT","OUTCOME_UNKNOWN","TRANSPORT_UNCERTAIN").firstOrNull { message.orEmpty().contains(it) } ?: "SERVER"
