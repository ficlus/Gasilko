package si.gasilko.app.feature.map.navigation

import android.location.Location
import android.os.Build
import android.os.SystemClock
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import kotlin.math.abs

/** Presentation-only state, owned by the native map view. Never changes the GPS/progress input. */
internal class NavigationCamera {
    private var heading: Double? = null
    private var bearingFix = Long.MIN_VALUE
    private var cameraFix = Long.MIN_VALUE
    private var animatedAt = 0L
    private var viewport = 0 to 0

    fun location(fix: Location): Location {
        if (bearingFix != fix.elapsedRealtimeNanos) {
            bearingFix = fix.elapsedRealtimeNanos
            val usable = fix.hasBearing() && fix.bearing.isFinite() && fix.hasSpeed() &&
                fix.speed >= 1.5f && fix.hasAccuracy() && fix.accuracy <= 25f &&
                (Build.VERSION.SDK_INT < 26 || !fix.hasBearingAccuracy() || fix.bearingAccuracyDegrees <= 35f)
            if (usable) {
                val previous = heading
                // Shortest-angle smoothing avoids a 359° -> 1° full turn; ignore tiny GPS jitter.
                heading = if (previous == null) fix.bearing.toDouble() else {
                    val delta = ((fix.bearing - previous + 540.0) % 360.0) - 180.0
                    if (abs(delta) < 4.0) previous else (previous + delta * 0.65 + 360.0) % 360.0
                }
            }
        }
        return Location(fix).apply {
            heading?.let { bearing = it.toFloat() } ?: removeBearing()
        }
    }

    fun follow(map: MapLibreMap, fix: Location, width: Int, height: Int, force: Boolean) {
        if (width <= 0 || height <= 0) return
        val now = SystemClock.elapsedRealtime()
        val resized = viewport != (width to height)
        if (!force && !resized && cameraFix == fix.elapsedRealtimeNanos) return
        cameraFix = fix.elapsedRealtimeNanos
        animatedAt = now
        viewport = width to height
        map.easeCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder()
            .target(LatLng(fix.latitude, fix.longitude)).bearing(heading ?: 0.0)
            .zoom(16.5).tilt(35.0)
            // Positive top padding anchors the vehicle at 66% of the unobscured map height.
            .padding(0.0, height * 0.32, 0.0, 0.0).build()), if(force)300 else 200)
    }
}
