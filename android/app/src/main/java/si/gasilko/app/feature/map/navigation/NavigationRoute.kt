package si.gasilko.app.feature.map.navigation

import kotlinx.serialization.json.*
import si.gasilko.app.feature.map.domain.GeoPoint
import si.gasilko.app.feature.map.domain.NearbyHydrants
import si.gasilko.app.feature.plans.PlanRoute
import java.util.UUID

data class NavigationRequest(val organization: String,val plan: String,val team: String,val version: Long,val origin: GeoPoint) {
    fun arguments()=buildJsonObject {
        put("organization",organization)
        put("origin",buildJsonArray { add(origin.longitude);add(origin.latitude) })
        put("request",buildJsonObject {
            put("id",plan);put("team_id",team);put("version",version);put("operation_id",UUID.randomUUID().toString());put("action","NAVIGATE")
        })
    }
}
data class NavigationStep(val points: List<GeoPoint>,val meters: Double,val seconds: Double,val road: String,
    val type: String,val modifier: String,val location: GeoPoint)
data class NavigationLeg(val meters: Double,val seconds: Double,val steps: List<NavigationStep>)
data class NavigationStop(val item: String,val hydrant: String,val code: String?,val original: GeoPoint,val snapped: GeoPoint,val order: Int)
data class NavigationRoute(val plan: String,val team: String,val version: Long,val provider: String,val meters: Double,
    val seconds: Double,val points: List<GeoPoint>,val legs: List<NavigationLeg>,val stops: List<NavigationStop>) {
    fun mapRoute(org: String,key: String,roadPoints: List<GeoPoint> = points)=PlanRoute(plan,org,team,provider,"car",key,meters,seconds,
        buildJsonObject {
            put("type","FeatureCollection")
            put("features",buildJsonArray {
                if(roadPoints.size>1)add(buildJsonObject {
                    put("type","Feature");put("properties",buildJsonObject { put("kind","road") })
                    put("geometry",buildJsonObject { put("type","LineString");put("coordinates",JsonArray(roadPoints.map { it.json() })) })
                })
                stops.forEach { stop -> add(buildJsonObject {
                    put("type","Feature");put("properties",buildJsonObject {
                        put("kind","stop");put("uuid",stop.hydrant);put("number",stop.order);put("snapped",stop.snapped.json())
                    })
                    put("geometry",buildJsonObject { put("type","Point");put("coordinates",stop.original.json()) })
                }) }
            })
        }.toString(),buildJsonArray { stops.forEach { add(buildJsonObject { put("hydrant",it.hydrant);put("code",it.code);put("order",it.order) }) } }.toString(),true)
}
/** Trim only the travelled prefix of the provider's road line. Stop coordinates stay untouched. */
internal fun remainingRoad(points: List<GeoPoint>,travelled: Double): List<GeoPoint> {
    if(travelled<=0 || points.size<2)return points
    var remaining=travelled
    for(index in 0 until points.lastIndex) {
        val a=points[index];val b=points[index+1]
        val meters=NearbyHydrants.distance(a,b)
        if(meters>0 && remaining<meters) {
            val fraction=remaining/meters
            return listOf(GeoPoint(a.latitude+(b.latitude-a.latitude)*fraction,
                a.longitude+(b.longitude-a.longitude)*fraction))+points.drop(index+1)
        }
        remaining-=meters
    }
    return points.takeLast(1)
}
private fun GeoPoint.json()=buildJsonArray { add(longitude);add(latitude) }
internal fun decodeNavigation(value: JsonElement): NavigationRoute {
    fun JsonElement.point(): GeoPoint { val a=jsonArray;return GeoPoint(a[1].jsonPrimitive.double,a[0].jsonPrimitive.double).also { require(it.valid) } }
    fun JsonObject.s(k: String)=getValue(k).jsonPrimitive.content
    fun JsonObject.n(k: String)=getValue(k).jsonPrimitive.double.also { require(it.isFinite() && it>=0) }
    fun JsonObject.points(k: String)=getValue(k).jsonArray.map { it.point() }
    val r=value.jsonObject
    val legs=r.getValue("legs").jsonArray.map { l -> val leg=l.jsonObject
        NavigationLeg(leg.n("distance"),leg.n("seconds"),leg.getValue("steps").jsonArray.map { s -> val step=s.jsonObject
            NavigationStep(step.points("coordinates"),step.n("distance"),step.n("seconds"),step.s("road"),step.s("type"),step.s("modifier"),step.getValue("location").point()) }) }
    val stops=r.getValue("stops").jsonArray.map { s -> val stop=s.jsonObject
        NavigationStop(stop.s("id"),stop.s("hydrant"),stop["code"]?.jsonPrimitive?.contentOrNull,
            GeoPoint(stop.getValue("latitude").jsonPrimitive.double,stop.getValue("longitude").jsonPrimitive.double).also { require(it.valid) },
            stop.getValue("snapped").point(),stop.getValue("order").jsonPrimitive.int) }
    return NavigationRoute(r.s("plan"),r.s("team"),r.getValue("version").jsonPrimitive.long,r.s("provider"),r.n("distance"),r.n("seconds"),r.points("coordinates"),legs,stops)
}
