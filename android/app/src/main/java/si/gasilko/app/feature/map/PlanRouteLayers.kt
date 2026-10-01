package si.gasilko.app.feature.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import kotlinx.serialization.json.*
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.*
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import si.gasilko.app.feature.plans.PlanRoute
import si.gasilko.app.feature.hydrants.domain.Hydrant

/** Derived display data only. The persisted road geometry is supplied by Room. */
internal data class RouteMapData(val key: String, val roads: String, val stops: String,
    val points: List<LatLng>, val numbers: Set<Int>, val hasRoad: Boolean, val stopCoordinates: Map<String,LatLng> = emptyMap())
internal fun routeMapData(route: PlanRoute, completed: Set<String> = emptySet(), allowed: Set<String>? = null,
    completedNumbers: Map<String,Int> = emptyMap(), hydrants: List<Hydrant> = emptyList()): RouteMapData {
    val points=mutableListOf<LatLng>()
    val stopCoordinates=mutableMapOf<String,LatLng>()
    val numbers=mutableSetOf<Int>()
    val root=Json.parseToJsonElement(route.geometry).jsonObject
    val roads=mutableListOf<JsonElement>()
    val stops=mutableListOf<JsonElement>()
    val features=root.getValue("features").jsonArray.toMutableList()
    val present=features.mapNotNull { it.jsonObject["properties"]?.jsonObject?.get("uuid")?.jsonPrimitive?.content }.toSet()
    // Remaining road geometry excludes completed stops; retain their original GPS markers from Room.
    hydrants.filter { it.id in completed && it.id !in present && HydrantMapLayers.valid(it) }.forEach { h ->
        completedNumbers[h.id]?.let { number -> features.add(buildJsonObject {
            put("type","Feature")
            put("properties",buildJsonObject { put("kind","stop");put("uuid",h.id);put("number",number) })
            put("geometry",buildJsonObject { put("type","Point");put("coordinates",buildJsonArray { add(h.longitude!!);add(h.latitude!!) }) })
        }) }
    }
    features.forEach { element ->
        val feature=element.jsonObject
        val geometry=feature.getValue("geometry").jsonObject
        val properties=feature.getValue("properties").jsonObject
        val coordinates=geometry.getValue("coordinates").jsonArray
        if(geometry["type"]?.jsonPrimitive?.content=="LineString") {
            val line=coordinates.map { point -> point.jsonArray.let { LatLng(it[1].jsonPrimitive.double,it[0].jsonPrimitive.double) } }
            // Old cached singleton/duplicate-point lines are not a visible driving route.
            if(line.distinctBy { it.latitude to it.longitude }.size>=2) {
                points.addAll(line);roads.add(feature)
            }
        } else if(geometry["type"]?.jsonPrimitive?.content=="Point" && properties["kind"]?.jsonPrimitive?.content=="stop") {
            val id=properties.getValue("uuid").jsonPrimitive.content
            if(allowed!=null && id !in allowed)return@forEach
            val position=LatLng(coordinates[1].jsonPrimitive.double,coordinates[0].jsonPrimitive.double)
            points.add(position)
            stopCoordinates[properties.getValue("uuid").jsonPrimitive.content]=position
            val number=properties.getValue("number").jsonPrimitive.int
            numbers.add(number)
            (properties["snapped"] as? JsonArray)?.takeIf { it.size>=2 }?.let {
                points.add(LatLng(it[1].jsonPrimitive.double,it[0].jsonPrimitive.double))
            }
            stops.add(JsonObject(feature+("properties" to JsonObject(properties+("icon" to JsonPrimitive("gasilko-route-stop-"+number+if(id in completed)"-completed" else ""))))))
        }
    }
    fun collection(features: List<JsonElement>)=buildJsonObject {
        put("type","FeatureCollection");put("features",JsonArray(features))
    }.toString()
    return RouteMapData(route.planId+route.teamId+route.calculatedAt,collection(roads),collection(stops),points,numbers,roads.isNotEmpty(),stopCoordinates)
}
internal class PlanRouteLayers(private val style: Style) {
    companion object { const val STOP_LAYER="gasilko-route-stops" }
    private val roads=GeoJsonSource("gasilko-route-roads",HydrantMapLayers.EMPTY)
    private val stops=GeoJsonSource("gasilko-route-stops",HydrantMapLayers.EMPTY)
    private var lastRoads: String?=null
    private var lastStops: String?=null
    private val images=mutableSetOf<String>()
    init {
        // Dedicated sources avoid mixed-geometry filtering; lines sit above the basemap, below stop numbers.
        style.addSource(roads);style.addSource(stops)
        style.addLayer(LineLayer("gasilko-route-casing","gasilko-route-roads").withProperties(
            lineColor(Color.WHITE),lineWidth(9f),lineOpacity(1f),visibility(Property.VISIBLE),
            lineCap(Property.LINE_CAP_ROUND),lineJoin(Property.LINE_JOIN_ROUND)))
        style.addLayer(LineLayer("gasilko-route-road","gasilko-route-roads").withProperties(
            lineColor(Color.rgb(30,77,185)),lineWidth(5f),lineOpacity(1f),visibility(Property.VISIBLE),
            lineCap(Property.LINE_CAP_ROUND),lineJoin(Property.LINE_JOIN_ROUND)))
        style.addLayer(SymbolLayer(STOP_LAYER,"gasilko-route-stops").withProperties(
            iconImage(get("icon")),iconSize(0.6f),iconAllowOverlap(true),iconIgnorePlacement(true)))
    }
    fun update(data: RouteMapData?) {
        val roadJson=data?.roads ?: HydrantMapLayers.EMPTY
        val stopJson=data?.stops ?: HydrantMapLayers.EMPTY
        if(lastRoads!=roadJson) { roads.setGeoJson(roadJson);lastRoads=roadJson }
        if(lastStops==stopJson)return
        data?.numbers?.forEach { number -> listOf(false,true).forEach { completed ->
            val imageId="gasilko-route-stop-"+number+if(completed)"-completed" else ""
            if(images.add(imageId)) {
            // Local bitmaps keep stop numbers readable with an offline/fallback style and no glyph server.
            val bitmap=Bitmap.createBitmap(64,64,Bitmap.Config.ARGB_8888)
            val canvas=Canvas(bitmap)
            val paint=Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color=Color.WHITE;canvas.drawCircle(32f,32f,31f,paint)
            paint.color=if(completed)Color.rgb(27,112,58) else Color.rgb(30,77,185);canvas.drawCircle(32f,32f,27f,paint)
            paint.color=Color.WHITE;paint.textAlign=Paint.Align.CENTER;paint.textSize=if(number<100)30f else 24f
            paint.isFakeBoldText=true
            canvas.drawText(number.toString(),32f,32f-(paint.ascent()+paint.descent())/2,paint)
            style.addImage(imageId,bitmap)
        } } }
        stops.setGeoJson(stopJson);lastStops=stopJson
    }
}
