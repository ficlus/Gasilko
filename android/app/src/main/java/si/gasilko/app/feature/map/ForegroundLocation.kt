package si.gasilko.app.feature.map

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import si.gasilko.app.feature.map.domain.GeoPoint

internal enum class LocationNotice { SEARCHING, UNAVAILABLE, STALE, DISABLED, DENIED }
internal data class LocationState(val fix: Location? = null, val notice: LocationNotice? = null)
internal fun hasLocationPermission(context: Context) =
    context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

/** Collected only while the map is STARTED. No service, storage, or network/sync integration. */
internal fun foregroundLocations(context: Context) = callbackFlow {
    val manager = context.getSystemService(LocationManager::class.java)
    if(manager == null) { trySend(LocationState(notice=LocationNotice.UNAVAILABLE)); close(); return@callbackFlow }
    var latest: Location? = null
    var registered = false
    var began = SystemClock.elapsedRealtime()
    val providers = mutableListOf<String>()
    fun publish() {
        if(!hasLocationPermission(context)) { latest=null; trySend(LocationState(notice=LocationNotice.DENIED)); close(); return }
        val enabled = providers.any { manager.isProviderEnabled(it) }
        val fix = latest
        val age = fix?.let { (SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1_000_000 }
        when {
            !enabled -> { latest=null; trySend(LocationState(notice=LocationNotice.DISABLED)) }
            fix != null && age != null && age in 0..120_000 -> trySend(LocationState(Location(fix)))
            fix != null -> trySend(LocationState(notice=LocationNotice.STALE))
            else -> trySend(LocationState(notice=if(SystemClock.elapsedRealtime()-began < 30_000) LocationNotice.SEARCHING else LocationNotice.UNAVAILABLE))
        }
    }
    val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            if(!GeoPoint(location.latitude,location.longitude).valid || !location.hasAccuracy() || !location.accuracy.isFinite() || location.accuracy < 0) return
            if(latest == null || location.elapsedRealtimeNanos > latest!!.elapsedRealtimeNanos) latest=Location(location)
            publish()
        }
        override fun onProviderDisabled(provider: String) { latest=null; publish() }
        override fun onProviderEnabled(provider: String) { began=SystemClock.elapsedRealtime(); publish() }
        @Deprecated("Platform compatibility")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) { publish() }
    }
    try {
        if(!hasLocationPermission(context)) { trySend(LocationState(notice=LocationNotice.DENIED)); close(); return@callbackFlow }
        val precise = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        providers.addAll(listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
            .filter { it in manager.allProviders && (precise || it != LocationManager.GPS_PROVIDER) })
        for(provider in providers) {
            manager.requestLocationUpdates(provider, 5_000L, 5f, listener, Looper.getMainLooper())
            registered=true
            if(manager.isProviderEnabled(provider)) manager.getLastKnownLocation(provider)?.let(listener::onLocationChanged)
        }
        publish()
    } catch(_: SecurityException) {
        latest=null; trySend(LocationState(notice=LocationNotice.DENIED))
    } catch(_: IllegalArgumentException) {
        latest=null; trySend(LocationState(notice=LocationNotice.UNAVAILABLE))
    }
    val expiry = launch {
        while(true) { delay(5_000); publish() }
    }
    awaitClose {
        expiry.cancel()
        if(registered) manager.removeUpdates(listener)
        latest=null
    }
}
