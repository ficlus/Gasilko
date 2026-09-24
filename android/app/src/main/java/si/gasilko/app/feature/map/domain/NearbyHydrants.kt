package si.gasilko.app.feature.map.domain

import kotlin.math.*
import si.gasilko.app.feature.hydrants.domain.Hydrant

data class GeoPoint(val latitude: Double, val longitude: Double) {
    val valid get() = latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0
}
data class NearbyHydrant(val hydrant: Hydrant, val meters: Double)

/** Great-circle distances in meters, never road distance or travel time. Inputs are already scoped. */
object NearbyHydrants {
    fun distance(from: GeoPoint, to: GeoPoint): Double {
        require(from.valid && to.valid)
        val lat1 = Math.toRadians(from.latitude)
        val lat2 = Math.toRadians(to.latitude)
        val dLat = lat2 - lat1
        val dLon = Math.toRadians(to.longitude - from.longitude)
        val a = (sin(dLat / 2).pow(2) + cos(lat1) * cos(lat2) * sin(dLon / 2).pow(2)).coerceIn(0.0, 1.0)
        return 6_371_008.8 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
    fun ordered(from: GeoPoint, rows: List<Hydrant>): List<NearbyHydrant> {
        if(!from.valid) return emptyList()
        return rows.mapNotNull { h ->
            val point = GeoPoint(h.latitude ?: return@mapNotNull null, h.longitude ?: return@mapNotNull null)
            if(point.valid) NearbyHydrant(h, distance(from, point)) else null
        }.sortedWith(compareBy<NearbyHydrant> { it.meters }.thenBy { it.hydrant.id })
    }
}
