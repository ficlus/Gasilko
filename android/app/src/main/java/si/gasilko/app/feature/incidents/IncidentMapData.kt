package si.gasilko.app.feature.incidents

import kotlinx.serialization.json.*
import si.gasilko.app.feature.map.IncidentMapFeature
import si.gasilko.app.feature.map.domain.GeoPoint

internal data class FieldMapData(val features: List<IncidentMapFeature>,val routes: List<JsonObject>,
    val supported: Boolean,val limited: Boolean,val invalid: Boolean)

/** Bounded GeoJSON validation; never guesses a destination for an area or bad point. */
internal fun fieldGeometry(g: JsonObject,route: Boolean=false): Boolean {
 return runCatching {
    require(g.keys==setOf("type","coordinates"))
    val type=g.text("type");val c=g["coordinates"] as? JsonArray ?: return false
    val paths=when(type) {
        "Point"->listOf(JsonArray(listOf(c)))
        "LineString"->listOf(c)
        "Polygon"->c.map { it as? JsonArray ?: return false }
        else->return false
    }
    require(paths.isNotEmpty())
    var count=0
    for(path in paths) {
        require(path.size>=when(type) {"Polygon"->4;"LineString"->2;else->1})
        if(type=="Polygon")require(path.first()==path.last())
        for(value in path) {
            val p=value as? JsonArray ?: return false
            require(p.size==2 && p.all {it is JsonPrimitive && !it.isString})
            val lon=p[0].jsonPrimitive.double;val lat=p[1].jsonPrimitive.double
            require(GeoPoint(lat,lon).valid);count++
        }
    }
    require(count<=if(route)50_000 else 2_000)
    require(g.toString().toByteArray().size<=if(route)786_432 else 65_536)
    true
}.getOrDefault(false)
}

internal fun fieldMapData(i: JsonObject): FieldMapData {
    val context=i.obj("field_map")
    val supported=!i.flag("leader_reset") && context.text("source").length==32 && context.text("schema")=="1" && context.text("revision")==i.text("revision")
    if(!supported)return FieldMapData(emptyList(),emptyList(),false,false,false)
    val limited=context.text("status")!="COMPLETE" || context.rows("features").size>200 || context.rows("routes").size>25 ||
        context.toString().toByteArray().size>786_432
    var invalid=false
    val features=mutableListOf<IncidentMapFeature>()
    for(a in i.rows("assignments")) {
        val t=a.obj("task");val kind=t.text("target_type")
        if(kind=="NONE")continue
        val g=t.obj("target_geometry_snapshot")
        if(!fieldGeometry(g) || kind !in listOf("COORDINATE","HYDRANT","INCIDENT_MAP_OBJECT","INCIDENT_SECTOR") ||
            (kind in listOf("INCIDENT_MAP_OBJECT","INCIDENT_SECTOR") && t.text("target_incident_id")!=i.text("id"))) {
            invalid=true;continue
        }
        features.add(IncidentMapFeature("TASK_TARGET/"+a.text("id"),"TASK_TARGET",t.text("target_label_snapshot").ifEmpty {t.text("title")},
            g,a.text("id"),t.text("version"),true,a.text("status") in listOf("BLOCKED","UNABLE") || t.text("priority") in listOf("HIGH","CRITICAL"),status=a.text("status")))
    }
    for(row in if(limited)emptyList() else context.rows("features")) {
        val kind=row.text("kind");val g=row.obj("geometry")
        if(kind !in listOf("INCIDENT_SECTOR","INCIDENT_MAP_OBJECT","INCIDENT_LINKED_HYDRANT") ||
            !canonicalUuid(row.text("id")) || row.text("version").toLongOrNull()?.let {it>0}!=true || !fieldGeometry(g) ||
            (kind=="INCIDENT_SECTOR" && g.text("type")!="Polygon") ||
            (kind=="INCIDENT_LINKED_HYDRANT" && (!canonicalUuid(row.text("hydrant_id")) || g.text("type")!="Point"))) {invalid=true;continue}
        features.add(IncidentMapFeature(kind+"/"+row.text("id"),kind,row.text("label"),g,version=row.text("version")))
    }
    val routes=(if(limited)emptyList() else context.rows("routes")).filter { r->
        val a=i.rows("assignments").find {it.text("id")==r.text("assignment_id")}
        val valid=a!=null && canonicalUuid(r.text("session_id")) && canonicalUuid(r.text("route_id")) &&
            r.text("session_version").toLongOrNull()?.let {it>0}==true && r.text("route_revision").toLongOrNull()?.let {it>0}==true &&
            r.text("origin_source")=="MANUAL_PLANNING_POINT" && r.text("provider") in listOf("OSRM","GraphHopper") &&
            r.obj("destination")==a.obj("task").obj("target_geometry_snapshot") &&
            r.obj("geometry").text("type")=="LineString" && fieldGeometry(r.obj("geometry"),true) &&
            listOf("distance_m","duration_s").all {key->r.text(key).toDoubleOrNull()?.let {it.isFinite() && it>=0}==true}
        if(!valid)invalid=true
        valid
    }
    return FieldMapData(features.distinctBy {it.id},routes,true,limited,invalid)
}
internal fun mapPoint(g: JsonObject): GeoPoint? {
    if(g.text("type")!="Point" || !fieldGeometry(g))return null
    val c=g.getValue("coordinates").jsonArray
    return GeoPoint(c[1].jsonPrimitive.double,c[0].jsonPrimitive.double)
}
