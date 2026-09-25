package si.gasilko.app.feature.map

import org.maplibre.android.geometry.LatLngBounds
import si.gasilko.app.BuildConfig
import java.net.URI
import kotlin.math.*

/** Deployment approval is tied to an exact style, never inferred from a tile hostname. */
internal object OfflineMapPolicy {
    const val MIN_ZOOM = 10
    const val MAX_ZOOM = 16
    const val MAX_BYTES = 200L * 1024 * 1024
    fun supported(style: String) = style == BuildConfig.OFFLINE_MAP_STYLE_URL && runCatching {
        URI(style).let { it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null &&
            !it.host.equals("demotiles.maplibre.org", ignoreCase=true) }
    }.getOrDefault(false)

    // Bound the whole zoom pyramid, not just the visible zoom. This is per source, not a byte estimate.
    fun valid(bounds: LatLngBounds?): Boolean {
        if(bounds == null) return false
        val n=bounds.latitudeNorth; val s=bounds.latitudeSouth
        val e=bounds.longitudeEast; val w=bounds.longitudeWest
        if(listOf(n,s,e,w).any { !it.isFinite() } || s < -85 || n > 85 || w < -180 || e > 180 || n<=s || e<=w) return false
        fun y(lat: Double, scale: Double) = (1-ln(tan(Math.PI/4+Math.toRadians(lat)/2))/Math.PI)/2*scale
        var tiles=0L
        for(z in MIN_ZOOM..MAX_ZOOM) {
            val scale=2.0.pow(z)
            val width=floor((e+180)/360*scale)-floor((w+180)/360*scale)+1
            val height=floor(y(s,scale))-floor(y(n,scale))+1
            tiles+=(width*height).toLong()
            if(tiles>8_000) return false
        }
        return true
    }

    fun sameArea(a: LatLngBounds?, b: LatLngBounds) = a != null &&
        abs(a.latitudeNorth-b.latitudeNorth)<0.001 && abs(a.latitudeSouth-b.latitudeSouth)<0.001 &&
        abs(a.longitudeEast-b.longitudeEast)<0.001 && abs(a.longitudeWest-b.longitudeWest)<0.001
}
