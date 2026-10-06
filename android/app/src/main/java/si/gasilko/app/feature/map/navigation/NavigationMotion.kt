package si.gasilko.app.feature.map.navigation

import android.location.Location
import si.gasilko.app.feature.map.domain.GeoPoint
import si.gasilko.app.feature.map.domain.NearbyHydrants
import kotlin.math.*

internal object NavigationMotion {
    const val WRONG_SPEED=10.0/3.6
    const val WRONG_ANGLE=110.0
    const val WRONG_TIME=4_000L
    const val WRONG_FIXES=4
    const val WRONG_MOVEMENT=12.0
    const val LOOK_AHEAD=30.0
    const val COOLDOWN=30_000L
    fun speed(fix: Location): Double? = fix.speed.toDouble().takeIf {
        fix.hasSpeed() && it.isFinite() && it in 0.0..70.0 &&
            (!fix.hasSpeedAccuracy() || fix.speedAccuracyMetersPerSecond<=3f)
    }
    fun interval(speed: Double?) = when { speed==null || speed<10.0/3.6 -> 900L;speed<60.0/3.6 -> 450L;else -> 300L }
    fun bearing(fix: Location): Double? = fix.bearing.toDouble().takeIf {
        fix.hasBearing() && it.isFinite() && it in 0.0..360.0 && (speed(fix) ?: 0.0)>WRONG_SPEED &&
            fix.hasAccuracy() && fix.accuracy<=25f && (!fix.hasBearingAccuracy() || fix.bearingAccuracyDegrees<=25f)
    }?.rem(360.0)
    fun delta(a: Double,b: Double)=abs(((a-b+540.0)%360.0)-180.0)
    fun direction(a: GeoPoint,b: GeoPoint): Double {
        val lat1=Math.toRadians(a.latitude);val lat2=Math.toRadians(b.latitude);val lon=Math.toRadians(b.longitude-a.longitude)
        return (Math.toDegrees(atan2(sin(lon)*cos(lat2),cos(lat1)*sin(lat2)-sin(lat1)*cos(lat2)*cos(lon)))+360)%360
    }
}
internal enum class WrongWay { NORMAL, SUSPECTED, CONFIRMED, REROUTING }
internal class WrongWayTracker {
    private var since: Long?=null
    private var start: GeoPoint?=null
    private var count=0
    private var previous=0L
    fun reset() { since=null;start=null;count=0;previous=0L }
    fun sample(point: GeoPoint,at: Long,speed: Double?,bearing: Double?,expected: Double?): WrongWay {
        if(previous>0 && at-previous>3_000)reset()
        previous=at
        if(speed==null || speed<=NavigationMotion.WRONG_SPEED || bearing==null || expected==null ||
            NavigationMotion.delta(bearing,expected)<=NavigationMotion.WRONG_ANGLE) { reset();return WrongWay.NORMAL }
        if(since==null) { since=at;start=point };count++
        return if(count>=NavigationMotion.WRONG_FIXES && at-since!!>=NavigationMotion.WRONG_TIME &&
            NearbyHydrants.distance(start!!,point)>=NavigationMotion.WRONG_MOVEMENT)WrongWay.CONFIRMED else WrongWay.SUSPECTED
    }
}
