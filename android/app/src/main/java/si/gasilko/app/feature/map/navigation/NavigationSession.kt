package si.gasilko.app.feature.map.navigation

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.map.domain.GeoPoint

internal data class NavigationState(val organization: String="",val plan: String="",val team: String="",val version: Long=0,
    val sourceKey: String="",val routeSourceKey: String="",val route: NavigationRoute?=null,val routeRevision: Int=0,val guidance: Guidance=Guidance(),
    val busy: Boolean=false,val error: RegistryError?=null,val awaitingCompletion: Boolean=false,val locationReady: Boolean=false) {
    val active get()=plan.isNotEmpty()
}
/** Owned by the registry ViewModel; no location observer, Android resources or durable GPS trail. */
internal class NavigationSession(private val scope: CoroutineScope,private val load: suspend (NavigationRequest)->NavigationRoute) {
    private val mutable=MutableStateFlow(NavigationState())
    val state=mutable.asStateFlow()
    private var job: Job?=null
    val spoken=mutableSetOf<String>()
    private var generation=0
    private var tracker: NavigationProgress?=null
    private var point: GeoPoint?=null
    private var lastFix=0L
    private var requestNeeded=false
    private var autoAttempted=false
    fun start(org: String,plan: String,team: String,version: Long,key: String) {
        stop();mutable.value=NavigationState(org,plan,team,version,key);requestNeeded=true
    }
    fun stop() { spoken.clear();generation++;job?.cancel();job=null;tracker=null;point=null;lastFix=0;requestNeeded=false;autoAttempted=false;mutable.value=NavigationState() }
    fun pause() { generation++;job?.cancel();job=null;point=null;mutable.value=mutable.value.copy(busy=false,locationReady=false);requestNeeded=mutable.value.route==null }
    fun unavailable() { point=null;mutable.value=mutable.value.copy(locationReady=false) }
    fun updatePlan(version: Long,key: String,ready: Boolean,remaining: Set<String>) {
        val old=mutable.value;if(!old.active)return
        val completed=old.route?.stops?.firstOrNull()?.item?.let { it !in remaining }==true
        if(remaining.isEmpty()) { stop();return }
        if((completed && old.routeSourceKey==key) || !ready) {
            generation++;job?.cancel();job=null
            mutable.value=old.copy(version=version,busy=false,awaitingCompletion=true);return
        }
        if(old.sourceKey!=key || old.awaitingCompletion) {
            generation++;job?.cancel();job=null;tracker=null;autoAttempted=false;requestNeeded=true
            mutable.value=old.copy(version=version,sourceKey=key,busy=false,awaitingCompletion=false,error=null,guidance=Guidance())
            if(point!=null)request()
        } else mutable.value=old.copy(version=version)
    }
    fun fix(value: GeoPoint,accuracy: Float,at: Long,ageMillis: Long) {
        if(!mutable.value.active)return
        if(!value.valid || !accuracy.isFinite() || accuracy>NavigationThresholds.MAX_ACCURACY_METERS ||
            ageMillis !in 0..NavigationThresholds.MAX_FIX_AGE_MILLIS) { unavailable();return }
        if(at<=lastFix)return
        lastFix=at;point=value;mutable.value=mutable.value.copy(locationReady=true)
        if(requestNeeded) { requestNeeded=false;request();return }
        if(mutable.value.awaitingCompletion)return
        tracker?.sample(value,at)?.let { guidance ->
            mutable.value=mutable.value.copy(guidance=guidance)
            // At most one automatic deviation reroute per target/authoritative route revision.
            if(guidance.offRoute && !guidance.arrived && !autoAttempted && !mutable.value.busy) { autoAttempted=true;request() }
        }
    }
    fun request() {
        val old=mutable.value;val origin=point ?: return
        if(!old.active || old.busy || old.awaitingCompletion)return
        val stamp=generation
        requestNeeded=false
        mutable.value=old.copy(busy=true,error=null)
        job=scope.launch {
            try {
                val route=load(NavigationRequest(old.organization,old.plan,old.team,old.version,origin))
                if(stamp!=generation)return@launch
                require(route.plan==old.plan && route.team==old.team && route.version==old.version && route.stops.isNotEmpty())
                tracker=NavigationProgress(route)
                mutable.value=mutable.value.copy(route=route,routeSourceKey=old.sourceKey,routeRevision=old.routeRevision+1,
                    guidance=tracker!!.sample(point ?: origin,lastFix),busy=false,error=null)
            } catch(e: CancellationException) { if(stamp==generation)mutable.value=mutable.value.copy(busy=false);throw e }
            catch(e: Exception) { if(stamp==generation)mutable.value=mutable.value.copy(busy=false,error=(e as? RegistryFailure)?.reason ?: RegistryError.ROUTE_PROVIDER) }
        }
    }
}
