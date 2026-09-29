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
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import si.gasilko.app.feature.plans.PlanRoute

/** Derived display data only. The persisted road geometry is supplied by Room. */
internal data class RouteMapData(val key: String, val json: String, val points: List<LatLng>, val numbers: Set<Int>)
internal fun routeMapData(route: PlanRoute): RouteMapData {
    val points=mutableListOf<LatLng>()
    val numbers=mutableSetOf<Int>()
    val root=Json.parseToJsonElement(route.geometry).jsonObject
    val features=root.getValue("features").jsonArray.map { element ->
        val feature=element.jsonObject
        val geometry=feature.getValue("geometry").jsonObject
        val properties=feature.getValue("properties").jsonObject
        val coordinates=geometry.getValue("coordinates").jsonArray
        if(properties["kind"]?.jsonPrimitive?.content=="road") {
            coordinates.forEach { point -> point.jsonArray.let { points.add(LatLng(it[1].jsonPrimitive.double,it[0].jsonPrimitive.double)) } }
            feature
        } else {
            points.add(LatLng(coordinates[1].jsonPrimitive.double,coordinates[0].jsonPrimitive.double))
            val number=properties.getValue("number").jsonPrimitive.int
            numbers.add(number)
            JsonObject(feature+("properties" to JsonObject(properties+("icon" to JsonPrimitive("gasilko-route-stop-"+number)))))
        }
    }
    return RouteMapData(route.planId+route.teamId+route.calculatedAt,JsonObject(root+("features" to JsonArray(features))).toString(),points,numbers)
}
internal class PlanRouteLayers(private val style: Style) {
    private val source=GeoJsonSource("gasilko-route",HydrantMapLayers.EMPTY)
    private var last: String?=null
    private val images=mutableSetOf<Int>()
    init {
        style.addSource(source)
        style.addLayer(LineLayer("gasilko-route-road","gasilko-route").withProperties(lineColor(Color.rgb(30,77,185)),lineWidth(5f))
            .apply { setFilter(eq(get("kind"),literal("road"))) })
        style.addLayer(SymbolLayer("gasilko-route-stops","gasilko-route").withProperties(
            iconImage(get("icon")),iconSize(0.6f),iconAllowOverlap(true),iconIgnorePlacement(true))
            .apply { setFilter(eq(get("kind"),literal("stop"))) })
    }
    fun update(data: RouteMapData?) {
        val json=data?.json ?: HydrantMapLayers.EMPTY
        if(last==json)return
        data?.numbers?.forEach { number -> if(images.add(number)) {
            // Local bitmaps keep stop numbers readable with an offline/fallback style and no glyph server.
            val bitmap=Bitmap.createBitmap(64,64,Bitmap.Config.ARGB_8888)
            val canvas=Canvas(bitmap)
            val paint=Paint(Paint.ANTI_ALIAS_FLAG)
            paint.color=Color.WHITE;canvas.drawCircle(32f,32f,31f,paint)
            paint.color=Color.rgb(30,77,185);canvas.drawCircle(32f,32f,27f,paint)
            paint.color=Color.WHITE;paint.textAlign=Paint.Align.CENTER;paint.textSize=if(number<100)30f else 24f
            paint.isFakeBoldText=true
            canvas.drawText(number.toString(),32f,32f-(paint.ascent()+paint.descent())/2,paint)
            style.addImage("gasilko-route-stop-"+number,bitmap)
        } }
        source.setGeoJson(json);last=json
    }
}
