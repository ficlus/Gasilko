package si.gasilko.app.feature.plans

import kotlinx.serialization.json.*
import java.util.UUID

data class PlanReassign(val context: PlanStopContext, val fromTeam: String, val toTeam: String, val reason: String,
    val id: String = UUID.randomUUID().toString()) {
    fun payload()=buildJsonObject {
        put("id",id);put("plan_id",context.planId);put("item_id",context.itemId);put("version",context.version)
        put("from_team_id",fromTeam);put("to_team_id",toTeam);put("reason",reason.trim())
    }
}
data class PlanReassignment(val id: String,val organization: String,val planId: String,val itemId: String,
    val fromTeam: String,val toTeam: String,val actor: String,val createdAt: String,val reason: String,val version: Long) {
    fun payload()=buildJsonObject {
        put("id",id);put("organization_id",organization);put("plan_id",planId);put("item_id",itemId)
        put("from_team_id",fromTeam);put("to_team_id",toTeam);put("actor",actor);put("created_at",createdAt)
        put("reason",reason);put("item_version",version)
    }
}
internal fun decodeReassignment(row: JsonObject): PlanReassignment {
    fun s(k: String)=row.getValue(k).jsonPrimitive.content
    return PlanReassignment(s("id"),s("organization_id"),s("plan_id"),s("item_id"),s("from_team_id"),s("to_team_id"),
        s("actor"),s("created_at"),s("reason"),s("item_version").toLong())
}
internal fun decodeReassign(payload: String): PlanReassign {
    val row=Json.parseToJsonElement(payload).jsonObject
    fun s(k: String)=row.getValue(k).jsonPrimitive.content
    return PlanReassign(PlanStopContext(s("plan_id"),s("item_id"),s("version").toLong()),s("from_team_id"),
        s("to_team_id"),s("reason"),s("id"))
}
