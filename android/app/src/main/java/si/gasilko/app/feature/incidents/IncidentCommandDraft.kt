package si.gasilko.app.feature.incidents

import kotlinx.serialization.json.*
import java.util.UUID

internal fun canonicalUuid(value: String)=runCatching { UUID.fromString(value).toString()==value }.getOrDefault(false)

/** SQL catalog: row.id = definition; configuration.id = immutable version.
 * configuration is to_jsonb(version), not an arbitrary editor-only object. */
internal fun catalogVersion(row: JsonObject?): String? {
    if(row==null || !row.flag("active") || !canonicalUuid(row.text("id")))return null
    val config=row.obj("configuration")
    val version=config.text("id")
    if(!canonicalUuid(version) || config.text("definition_id")!=row.text("id") ||
        !config.flag("active_for_new_commands") ||
        config.text("version_number").toLongOrNull()?.takeIf { it>0 }!=row.text("version").toLongOrNull() ||
        config.text("version_number").toLongOrNull()==null ||
        config["recipient_types"]?.jsonArray?.none { it.jsonPrimitive.content=="INCIDENT_CREW_MEMBER" }!=false)return null
    return version
}

internal fun validParameters(config: JsonObject,values: JsonObject): Boolean = runCatching {
    val definitions=config.rows("parameter_definitions")
    require(values.toString().toByteArray(Charsets.UTF_8).size<=8192)
    require(values.keys.all { key->definitions.any { it.text("code")==key } })
    for(d in definitions) {
        val value=values[d.text("code")]
        if(value==null) { require(!d.flag("required"));continue }
        val primitive=value as? JsonPrimitive ?: return@runCatching false
        require(primitive!=JsonNull)
        when(d.text("type")) {
            "TEXT"-> {
                require(primitive.isString)
                require(primitive.content.codePointCount(0,primitive.content.length)<=(d.text("max_length").toIntOrNull() ?: 0))
                require(!d.flag("required") || primitive.content.trim(' ').isNotEmpty())
            }
            "INTEGER","DECIMAL"-> {
                require(!primitive.isString)
                val number=primitive.content.toBigDecimal()
                require(number.precision().toLong()-number.scale()<=131072L && number.scale()<=16383)
                if(d.text("type")=="INTEGER")require(number.stripTrailingZeros().scale()<=0)
                d["min"]?.let { require(number>=it.jsonPrimitive.content.toBigDecimal()) }
                d["max"]?.let { require(number<=it.jsonPrimitive.content.toBigDecimal()) }
            }
            "BOOLEAN"->require(!primitive.isString && primitive.booleanOrNull!=null)
            "CHOICE"->require(primitive.isString && d.rows("options").any { it.text("code")==primitive.content })
            else->return@runCatching false
        }
    }
    true
}.getOrDefault(false)

internal fun validIssueDraft(row: JsonObject?,payload: JsonObject,incident: JsonObject): Boolean = runCatching {
    val version=catalogVersion(row) ?: return@runCatching false
    require(payload.text("action_version_id")==version && canonicalUuid(payload.text("id")))
    val config=row!!.obj("configuration")
    val title=payload.text("title");val notes=payload.text("notes")
    require(title.codePointCount(0,title.length)<=200 && notes.codePointCount(0,notes.length)<=4000)
    require(payload.toString().toByteArray(Charsets.UTF_8).size<=50000)
    require(validParameters(config,payload.obj("parameters")))
    val recipient=payload.rows("recipients").single()
    require(canonicalUuid(recipient.text("id")) && recipient.text("type")=="INCIDENT_CREW_MEMBER")
    require(incident.rows("units").filter { it.flag("leader") }.flatMap { it.rows("crew") }
        .any { it.text("id")==recipient.text("recipient_id") && it.flag("can_issue") && it.text("status")=="ACTIVE" })
    val target=payload.obj("target");val kind=target.text("kind")
    require(config["target_types"]!!.jsonArray.any { it.jsonPrimitive.content==kind })
    when(kind) {
        "NONE"->require(target.keys==setOf("kind"))
        "COORDINATE"-> {
            require(target.keys==setOf("kind","coordinate"))
            val xy=target["coordinate"]!!.jsonArray
            require(xy.size==2 && xy.all { !it.jsonPrimitive.isString })
            val lon=xy[0].jsonPrimitive.double;val lat=xy[1].jsonPrimitive.double
            require(lon.isFinite() && lat.isFinite() && lon in -180.0..180.0 && lat in -90.0..90.0)
        }
        "HYDRANT"->require(target.keys==setOf("kind","entityId") && canonicalUuid(target.text("entityId")))
        "INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"->require(target.keys==setOf("kind","entityId","incidentId") &&
            canonicalUuid(target.text("entityId")) && target.text("incidentId")==incident.text("id"))
        else->return@runCatching false
    }
    if(config.text("native_behavior") in listOf("MOVE_TO","WITHDRAW_TO")) {
        require(kind in listOf("COORDINATE","HYDRANT","INCIDENT_MAP_OBJECT"))
        // Non-point reference validity is checked against the visible target before Review
        // and rechecked against the authoritative object by the canonical RPC.
    }
    true
}.getOrDefault(false)
