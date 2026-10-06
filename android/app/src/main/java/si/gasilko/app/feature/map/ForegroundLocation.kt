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
internal fun freshLocation(fix: Location): Boolean =
    GeoPoint(fix.latitude,fix.longitude).valid && fix.hasAccuracy() && fix.accuracy.isFinite() && fix.accuracy>=0 &&
        SystemClock.elapsedRealtimeNanos()-fix.elapsedRealtimeNanos in 0..120_000_000_000L
internal fun hasLocationPermission(context: Context) =
    context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

/** Collected only by STARTED foreground UI. No service, storage, or network/sync integration. */
internal fun foregroundLocations(context: Context, navigation: Boolean = false) = callbackFlow {
    val manager = context.getSystemService(LocationManager::class.java)
    if(manager == null) { trySend(LocationState(notice=LocationNotice.UNAVAILABLE)); close(); return@callbackFlow }
    var latest: Location? = null
    var registered = false
    var began = SystemClock.elapsedRealtime()
    val providers = mutableListOf<String>()
    var requestedInterval=if(navigation)900L else 5_000L
    var changedAt=0L
    fun publish() {
        if(!hasLocationPermission(context)) { latest=null; trySend(LocationState(notice=LocationNotice.DENIED)); close(); return }
        val enabled = try { providers.any { manager.isProviderEnabled(it) } }
            catch(_: SecurityException) { latest=null;trySend(LocationState(notice=LocationNotice.DENIED));close();return }
        val fix = latest
        when {
            !enabled -> { latest=null; trySend(LocationState(notice=LocationNotice.DISABLED)) }
            fix != null && freshLocation(fix) -> trySend(LocationState(Location(fix)))
            fix != null -> trySend(LocationState(notice=LocationNotice.STALE))
            else -> trySend(LocationState(notice=if(SystemClock.elapsedRealtime()-began < 30_000) LocationNotice.SEARCHING else LocationNotice.UNAVAILABLE))
        }
    }
    val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            // A future timestamp must not replace the last fix and suppress subsequent valid fixes.
            if(!freshLocation(location)) return
            if(navigation && (location.accuracy>50f || SystemClock.elapsedRealtimeNanos()-location.elapsedRealtimeNanos>20_000_000_000L))return
            val previous=latest
            if(navigation && previous!=null) {
                val seconds=(location.elapsedRealtimeNanos-previous.elapsedRealtimeNanos)/1e9
                if(seconds>0 && previous.distanceTo(location)>seconds*80+previous.accuracy+location.accuracy)return
            }
            if(latest == null || location.elapsedRealtimeNanos > latest!!.elapsedRealtimeNanos) latest=Location(location)
            if(navigation) {
                val interval=si.gasilko.app.feature.map.navigation.NavigationMotion.interval(si.gasilko.app.feature.map.navigation.NavigationMotion.speed(location))
                val now=SystemClock.elapsedRealtime()
                if(interval!=requestedInterval && now-changedAt>=3_000) {
                    requestedInterval=interval;changedAt=now
                    try { for(provider in providers)manager.requestLocationUpdates(provider,interval,0f,this,Looper.getMainLooper()) }
                    catch(_: SecurityException) { latest=null;publish();return }
                }
            }
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
            manager.requestLocationUpdates(provider, requestedInterval, if(navigation)0f else 5f, listener, Looper.getMainLooper())
            registered=true
            if(manager.isProviderEnabled(provider)) manager.getLastKnownLocation(provider)?.let(listener::onLocationChanged)
        }
        publish()
    } catch(_: SecurityException) {
        latest=null; trySend(LocationState(notice=LocationNotice.DENIED));close()
    } catch(_: IllegalArgumentException) {
        latest=null; trySend(LocationState(notice=LocationNotice.UNAVAILABLE));close()
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
