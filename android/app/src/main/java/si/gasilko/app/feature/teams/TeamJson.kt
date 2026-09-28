package si.gasilko.app.feature.teams

import kotlinx.serialization.json.*

internal fun TeamChange.payload(org: String) = buildJsonObject {
    put("organization",org);put("team",id);put("operation",operation.name)
    put("team_name",name);put("enabled",active);put("member",member)
    put("initial_members",JsonArray(initialMembers.map(::JsonPrimitive)))
}
internal fun decodeTeams(value: JsonElement): TeamData {
    fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.content
    fun JsonObject.optional(key: String) = get(key)?.jsonPrimitive?.contentOrNull
    fun rows(key: String) = value.jsonObject.getValue(key).jsonArray.map { it.jsonObject }
    return TeamData(
        rows("teams").map { InspectionTeam(it.text("id"),it.text("organization_id"),it.text("name"),it.getValue("active").jsonPrimitive.boolean,
            it.text("created_by"),it.text("created_at"),it.text("updated_at")) },
        rows("members").map { TeamMember(it.text("team_id"),it.text("organization_id"),it.text("user_id"),it.getValue("active").jsonPrimitive.boolean,
            it.text("added_by"),it.text("created_at"),it.text("updated_at"),it.optional("display_name")) },
        rows("people").map { TeamPerson(it.text("id"),it.optional("display_name")) })
}
