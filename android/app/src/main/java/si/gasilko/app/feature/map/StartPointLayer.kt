package si.gasilko.app.feature.map

import android.graphics.Color
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.PropertyFactory.*
import org.maplibre.android.style.sources.GeoJsonSource
import si.gasilko.app.feature.map.domain.GeoPoint

/** Draft-only marker; never written to the hydrant store. */
internal object StartPointLayer {
    fun update(style: Style, point: GeoPoint?) {
        val id="gasilko-draft-start"
        if(point==null && style.getSource(id)==null)return
        val source=style.getSourceAs<GeoJsonSource>(id) ?: GeoJsonSource(id,HydrantMapLayers.EMPTY).also {
            style.addSource(it)
            style.addLayer(CircleLayer(id,id).withProperties(circleColor(Color.rgb(180,35,35)),circleRadius(10f),
                circleStrokeColor(Color.WHITE),circleStrokeWidth(3f)))
        }
        source.setGeoJson(if(point==null)HydrantMapLayers.EMPTY else
            """{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[${point.longitude},${point.latitude}]}}""")
    }
}
