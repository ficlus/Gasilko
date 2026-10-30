package si.gasilko.app.feature.map

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import kotlinx.serialization.json.*
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.*
import org.maplibre.android.style.layers.*
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource

/** Authorized, validated display DTOs only. No location or command ownership. */
data class IncidentMapFeature(val id: String,val kind: String,val label: String,val geometry: JsonObject,
    val assignment: String?=null,val version: String="",val issued: Boolean=false,val attention: Boolean=false,val status: String="")
data class IncidentMapScene(val features: List<IncidentMapFeature>,val selected: String?=null,
    val focus: String?=null,val focusKey: Int=0)

/** One native layer set on the existing MapView, including fallback/offline styles. */
internal class IncidentMapLayers(private val map: MapLibreMap,private val style: Style,private val density: Float,private val preserveInitialCamera: Boolean=false) {
    companion object {
        val HIT_LAYERS=arrayOf("incident-selected","incident-counts","incident-points","incident-areas","incident-lines")
        fun positions(g: JsonObject): List<LatLng> = when((g["type"] as? JsonPrimitive)?.content) {
            "Point"->listOf(g.getValue("coordinates"))
            "LineString"->g.getValue("coordinates").jsonArray.toList()
            "Polygon"->g.getValue("coordinates").jsonArray.flatMap { it.jsonArray }
            else->emptyList()
        }.map { p->p.jsonArray.let { LatLng(it[1].jsonPrimitive.double,it[0].jsonPrimitive.double) } }
    }
    private val source=GeoJsonSource("incident-context",HydrantMapLayers.EMPTY)
    private var scene: IncidentMapScene?=null
    private var lastJson: String?=null
    private var groups=emptyMap<String,List<IncidentMapFeature>>()
    private var focused: Pair<String?,Int>?=null
    private val images=mutableSetOf<Int>()
    private val idle=MapLibreMap.OnCameraIdleListener { draw() }
    init {
        style.addSource(source)
        style.addLayer(FillLayer("incident-areas","incident-context").withProperties(
            fillColor(get("color")),fillOpacity(0.18f)).apply {setFilter(eq(geometryType(),literal("Polygon")))})
        style.addLayer(LineLayer("incident-lines","incident-context").withProperties(
            lineColor(get("color")),lineWidth(4f),lineOpacity(0.9f)).apply {setFilter(neq(geometryType(),literal("Point")))})
        style.addLayer(CircleLayer("incident-points","incident-context").withProperties(
            circleColor(get("color")),circleRadius(7f),circleStrokeColor(Color.WHITE),circleStrokeWidth(2f)
        ).apply {setFilter(all(eq(geometryType(),literal("Point")),eq(get("count"),literal(1))))})
        style.addLayer(SymbolLayer("incident-counts","incident-context").withProperties(
            iconImage(get("image")),iconSize(1f/density),iconAllowOverlap(true),iconIgnorePlacement(true)
        ).apply {setFilter(gt(get("count"),literal(1)))})
        style.addLayer(CircleLayer("incident-selected","incident-context").withProperties(
            circleColor(Color.TRANSPARENT),circleRadius(12f),circleStrokeColor(Color.BLACK),circleStrokeWidth(3f)
        ).apply {setFilter(all(eq(geometryType(),literal("Point")),eq(get("selected"),literal(true))))})
        map.addOnCameraIdleListener(idle)
    }
    fun close() {map.removeOnCameraIdleListener(idle)}
    fun update(value: IncidentMapScene?) {
        if(scene==value)return
        val first=scene==null
        scene=value;draw()
        val key=value?.focus to (value?.focusKey ?: 0)
        if(first && preserveInitialCamera && value?.focusKey==0){focused=key;return}
        if(focused!=key && value?.focus!=null && (focused?.second!=key.second || value.features.find {it.id==value.focus}?.kind!="ROUTE")) {
            focused=key
            value.features.find {it.id==value.focus}?.let { focus(listOf(it)) }
        }
    }
    private fun color(f: IncidentMapFeature)=when {
        f.kind=="REGISTRY_HYDRANT"->when(f.status) {
            "WORKING"->"#16803C";"NOT_WORKING"->"#D12828";"NEEDS_INSPECTION"->"#CB8500";else->"#657080"
        }
        f.attention->"#AD3300"
        f.kind=="TASK_TARGET"->"#B51E2B"
        f.kind=="INCIDENT_LINKED_HYDRANT"->"#087C65"
        f.kind=="INCIDENT_SECTOR"->"#7353A6"
        f.kind=="ROUTE"->"#164DAD"
        else->"#1A718F"
    }
    private fun countImage(count: Int) {
        val n=minOf(count,100)
        if(!images.add(n))return
        val size=(36*density).toInt().coerceAtLeast(36)
        val bitmap=Bitmap.createBitmap(size,size,Bitmap.Config.ARGB_8888)
        val canvas=Canvas(bitmap);val p=Paint(Paint.ANTI_ALIAS_FLAG)
        val mid=size/2f;p.color=Color.WHITE;canvas.drawCircle(mid,mid,mid,p)
        p.color=Color.rgb(45,55,67);canvas.drawCircle(mid,mid,mid-2*density,p)
        p.color=Color.WHITE;p.textAlign=Paint.Align.CENTER;p.textSize=14*density;p.isFakeBoldText=true
        canvas.drawText(if(n==100)"99+" else n.toString(),mid,mid-(p.ascent()+p.descent())/2,p)
        style.addImage("incident-count-$n",bitmap)
    }
    private fun draw() {
        val current=scene
        val features=current?.features.orEmpty().sortedBy {it.id}
        val shapes=features.filter {it.geometry["type"]?.jsonPrimitive?.content!="Point"}
        // Screen collision only, same category/attention. Selected target never hidden.
        val radius=28*density
        val buckets=mutableMapOf<String,MutableList<MutableList<IncidentMapFeature>>>()
        val clusters=mutableListOf<MutableList<IncidentMapFeature>>()
        for(f in features.filter {it.geometry["type"]?.jsonPrimitive?.content=="Point"}) {
            val p=map.projection.toScreenLocation(positions(f.geometry).first())
            val x=kotlin.math.floor(p.x/radius).toInt();val y=kotlin.math.floor(p.y/radius).toInt()
            val prefix=f.kind+"/"+f.attention+"/"+f.status+"/"
            val nearby=if(f.id==current?.selected || f.attention)emptyList() else (-1..1).flatMap { dx->(-1..1).flatMap {dy->buckets[prefix+(x+dx)+"/"+(y+dy)].orEmpty()} }
            val cluster=nearby.firstOrNull { group->
                !group.first().attention && group.first().id!=current?.selected && map.projection.toScreenLocation(positions(group.first().geometry).first()).let {
                    (it.x-p.x)*(it.x-p.x)+(it.y-p.y)*(it.y-p.y)<radius*radius
                }
            }
            if(cluster!=null)cluster.add(f) else {
                val next=mutableListOf(f);clusters.add(next);buckets.getOrPut(prefix+x+"/"+y){mutableListOf()}.add(next)
            }
        }
        groups=clusters.associate { it.first().id to it.toList() }
        val json=buildJsonObject {
            put("type","FeatureCollection")
            put("features",JsonArray((shapes.map {it to listOf(it)}+clusters.map {it.first() to it.toList()}).sortedBy {it.first.attention}.map { (f,group)->
                if(group.size>1)countImage(group.size)
                buildJsonObject {
                    put("type","Feature");put("id",f.id);put("geometry",f.geometry)
                    put("properties",buildJsonObject {
                        put("id",f.id);put("color",color(f));put("count",group.size)
                        put("image","incident-count-"+minOf(group.size,100));put("selected",f.id==current?.selected)
                    })
                }
            }))
        }.toString()
        if(json!=lastJson){source.setGeoJson(json);lastJson=json}
    }
    fun select(point: LatLng): List<String>? {
        val p=map.projection.toScreenLocation(point);val r=18*density
        val ids=map.queryRenderedFeatures(RectF(p.x-r,p.y-r,p.x+r,p.y+r),*HIT_LAYERS)
            .mapNotNull {it.getStringProperty("id")}.distinct()
        if(ids.isEmpty())return null
        val selected=ids.flatMap { id->groups[id] ?: scene?.features.orEmpty().filter {it.id==id} }.distinctBy {it.id}
        val points=selected.flatMap {positions(it.geometry)}
        if(selected.size>1 && points.distinctBy {it.latitude to it.longitude}.size>1 && map.cameraPosition.zoom<18.0) {
            focus(selected);return emptyList()
        }
        return selected.map {it.id}
    }
    private fun focus(features: List<IncidentMapFeature>) {
        val points=features.flatMap {positions(it.geometry)}.distinctBy {it.latitude to it.longitude}
        if(points.size==1)map.moveCamera(CameraUpdateFactory.newLatLngZoom(points.first(),maxOf(map.cameraPosition.zoom,16.0)))
        else if(points.isNotEmpty())map.moveCamera(CameraUpdateFactory.newLatLngBounds(LatLngBounds.Builder().includes(points).build(),64))
    }
}
