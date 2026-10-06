package si.gasilko.app.feature.map.navigation

import si.gasilko.app.feature.map.domain.GeoPoint
import si.gasilko.app.feature.map.domain.NearbyHydrants
import kotlin.math.*

/** Foreground driving tolerances in one place; GPS has no persistence side effects. */
internal object NavigationThresholds {
    const val MANEUVER_METERS=25.0
    const val ARRIVAL_METERS=40.0
    const val OFF_ROUTE_METERS=60.0
    const val OFF_ROUTE_SAMPLES=3
    const val OFF_ROUTE_MILLIS=15_000L
    const val MAX_ACCURACY_METERS=50f
    const val MAX_FIX_AGE_MILLIS=20_000L
    const val PROJECTION_WINDOW_METERS=200.0
    const val ANNOUNCE_METERS=200.0
    const val TURN_NOW_METERS=50.0
}
internal data class Guidance(val meters: Double=0.0,val next: NavigationStep?=null,val step: Int=0,
    val toManeuver: Double=0.0,val remaining: Double=0.0,val seconds: Double=0.0,val arrived: Boolean=false,val offRoute: Boolean=false,
    val toTarget: Double=Double.POSITIVE_INFINITY,val geometryMeters: Double=0.0,val expectedBearing: Double?=null)
private data class Segment(val a: GeoPoint,val b: GeoPoint,val start: Double,val length: Double,
    val geometryStart: Double,val geometryLength: Double)

/** Progress is constrained to the current leg; crossing a later leg cannot skip an inspection. */
internal class NavigationProgress(private val route: NavigationRoute) {
    private val leg=route.legs.firstOrNull()
    private val steps=leg?.steps.orEmpty()
    private val segments=mutableListOf<Segment>()
    private val starts=mutableListOf<Double>()
    private var length=0.0
    private var geometryLength=0.0
    private var progress=0.0
    private var reached=false
    private var last: GeoPoint?=null
    private var badSince: Long?=null
    private var badSamples=0
    init {
        fun append(points: List<GeoPoint>,meters: Double?=null) {
            val distances=points.zipWithNext { a,b -> NearbyHydrants.distance(a,b) }
            val total=distances.sum()
            points.zipWithNext().forEachIndexed { i,(a,b) ->
                val d=if(meters!=null && total>0)meters*distances[i]/total else distances[i]
                if(d>0) {
                    segments.add(Segment(a,b,length,d,geometryLength,distances[i]))
                    length+=d;geometryLength+=distances[i]
                }
            }
        }
        if(steps.isNotEmpty())steps.forEach { starts.add(length);append(it.points,it.meters) }
        else {
            // Geometry-only providers still guide toward the first snapped road-access point.
            val target=route.stops.first().snapped
            val index=route.points.indices.minByOrNull { NearbyHydrants.distance(route.points[it],target) } ?: 0
            append(route.points.take(index+1))
        }
    }
    fun sample(point: GeoPoint,at: Long): Guidance {
        val window=max(NavigationThresholds.PROJECTION_WINDOW_METERS,(last?.let { NearbyHydrants.distance(it,point) } ?: 0.0)*2)
        fun project(segment: Segment): Pair<Double,Double> {
            val scale=cos(Math.toRadians(point.latitude))
            val ax=(segment.a.longitude-point.longitude)*scale;val ay=segment.a.latitude-point.latitude
            val dx=(segment.b.longitude-segment.a.longitude)*scale;val dy=segment.b.latitude-segment.a.latitude
            val t=if(dx*dx+dy*dy==0.0)0.0 else (-(ax*dx+ay*dy)/(dx*dx+dy*dy)).coerceIn(0.0,1.0)
            val p=GeoPoint(segment.a.latitude+(segment.b.latitude-segment.a.latitude)*t,segment.a.longitude+(segment.b.longitude-segment.a.longitude)*t)
            return NearbyHydrants.distance(point,p) to (segment.start+t*segment.length)
        }
        val candidates=segments.filter { it.start<=progress+window && it.start+it.length>=progress-NavigationThresholds.ARRIVAL_METERS }
        val nearest=candidates.map(::project).minWithOrNull(compareBy<Pair<Double,Double>> { it.first }.thenBy { it.second })
        val deviation=nearest?.first ?: NearbyHydrants.distance(point,route.stops.first().snapped)
        if(deviation>NavigationThresholds.OFF_ROUTE_METERS) {
            if(badSince==null)badSince=at
            badSamples++
        } else { badSince=null;badSamples=0;progress=max(progress,nearest?.second ?: 0.0) }
        last=point
        val accessDistance=NearbyHydrants.distance(point,route.stops.first().snapped)
        if(accessDistance<=NavigationThresholds.ARRIVAL_METERS &&
            length-progress<=NavigationThresholds.ARRIVAL_METERS*2)reached=true
        val arrived=reached
        val index=starts.indices.firstOrNull { starts[it]>progress+NavigationThresholds.MANEUVER_METERS } ?: steps.lastIndex
        val next=steps.getOrNull(index)
        val usedSeconds=if(length>0)(leg?.seconds ?: (route.seconds*length/max(route.meters,1.0)))*(progress/length).coerceIn(0.0,1.0) else 0.0
        // A display-only offset along provider geometry; road-distance weights above stay unchanged.
        val segment=segments.firstOrNull { it.start+it.length>=progress }
        val geometryProgress=segment?.let {
            it.geometryStart+it.geometryLength*((progress-it.start)/it.length).coerceIn(0.0,1.0)
        } ?: geometryLength
        val matched=nearest?.second ?: progress
        fun pointAt(meters: Double): GeoPoint? {
            val s=segments.firstOrNull { it.start+it.length>=meters } ?: segments.lastOrNull() ?: return null
            val f=((meters-s.start)/s.length).coerceIn(0.0,1.0)
            return GeoPoint(s.a.latitude+(s.b.latitude-s.a.latitude)*f,s.a.longitude+(s.b.longitude-s.a.longitude)*f)
        }
        val a=pointAt(matched);val b=pointAt(min(length,matched+NavigationMotion.LOOK_AHEAD))
        val expected=if(deviation<=NavigationThresholds.OFF_ROUTE_METERS && a!=null && b!=null && NearbyHydrants.distance(a,b)>=8)
            NavigationMotion.direction(a,b) else null
        return Guidance(progress,next,index,(starts.getOrNull(index)?.minus(progress) ?: (length-progress)).coerceAtLeast(0.0),
            (route.meters-progress).coerceAtLeast(0.0),(route.seconds-usedSeconds).coerceAtLeast(0.0),arrived,
            badSamples>=NavigationThresholds.OFF_ROUTE_SAMPLES && at-(badSince ?: at)>=NavigationThresholds.OFF_ROUTE_MILLIS,
            accessDistance,geometryProgress,expected)
    }
}
