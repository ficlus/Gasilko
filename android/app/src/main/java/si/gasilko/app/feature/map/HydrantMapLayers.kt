package si.gasilko.app.feature.map

import android.graphics.Color
import kotlinx.serialization.json.*
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression.*
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import si.gasilko.app.feature.hydrants.domain.Hydrant
import si.gasilko.app.feature.hydrants.domain.HydrantStatus

/** One source, fixed layer count; UUID is the identity even before a server code exists. */
internal class HydrantMapLayers(style: Style) {
    private val source = GeoJsonSource(SOURCE, EMPTY)
    private val selection = CircleLayer("gasilko-hydrant-selection", SOURCE).withProperties(
        circleRadius(12f), circleColor(Color.TRANSPARENT), circleStrokeColor(Color.BLACK), circleStrokeWidth(2f))
    private var lastData: String? = null
    init {
        style.addSource(source)
        HydrantStatus.entries.forEach { status ->
            style.addLayer(CircleLayer(layerId(status), SOURCE).withProperties(
                circleColor(color(status)), circleRadius(8f), circleStrokeColor(Color.WHITE), circleStrokeWidth(2f)
            ).apply { setFilter(eq(get("status"), literal(status.name))) })
        }
        selection.setFilter(eq(get("uuid"), literal("")))
        style.addLayer(selection)
    }
    fun update(data: String, selected: String?) {
        if(lastData != data) { source.setGeoJson(data); lastData=data }
        selection.setFilter(eq(get("uuid"), literal(selected.orEmpty())))
    }
    companion object {
        private const val SOURCE = "gasilko-hydrants"
        const val EMPTY = "{\"type\":\"FeatureCollection\",\"features\":[]}"
        // Allows cached hydrant layers to remain usable when the remote base style is unavailable.
        const val OFFLINE_STYLE = "{\"version\":8,\"sources\":{},\"layers\":[{\"id\":\"background\",\"type\":\"background\",\"paint\":{\"background-color\":\"#eef0ed\"}}]}"
        private fun layerId(status: HydrantStatus) = "gasilko-hydrant-${status.name}"
        val layerIds = HydrantStatus.entries.map(::layerId).toTypedArray()
        fun color(status: HydrantStatus): Int = Color.parseColor(when(status) {
            HydrantStatus.WORKING -> "#16803C"
            HydrantStatus.NOT_WORKING -> "#D12828"
            HydrantStatus.NEEDS_INSPECTION -> "#CB8500"
            HydrantStatus.UNKNOWN -> "#657080"
        })
        fun valid(h: Hydrant) = h.latitude?.let { it.isFinite() && it in -90.0..90.0 } == true &&
            h.longitude?.let { it.isFinite() && it in -180.0..180.0 } == true
        fun data(rows: List<Hydrant>): String = buildJsonObject {
            put("type", "FeatureCollection")
            put("features", JsonArray(rows.filter(::valid).map { h -> buildJsonObject {
                put("type", "Feature"); put("id", h.id)
                put("properties", buildJsonObject { put("uuid", h.id); put("status", h.status.name) })
                put("geometry", buildJsonObject {
                    put("type", "Point")
                    put("coordinates", buildJsonArray { add(h.longitude!!); add(h.latitude!!) })
                })
            } }))
        }.toString()
    }
}
