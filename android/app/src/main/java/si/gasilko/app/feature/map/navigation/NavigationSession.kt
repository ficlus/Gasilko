package si.gasilko.app.feature.map.navigation

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.map.domain.GeoPoint

internal data class NavigationState(val organization: String="",val plan: String="",val team: String="",val version: Long=0,
    val sourceKey: String="",val routeSourceKey: String="",val route: NavigationRoute?=null,val routeRevision: Int=0,val guidance: Guidance=Guidance(),
    val busy: Boolean=false,val error: RegistryError?=null,val awaitingCompletion: Boolean=false,val locationReady: Boolean=false,
    val wrongWay: WrongWay=WrongWay.NORMAL) {
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
    private val wrong=WrongWayTracker()
    private var lastAttempt=Long.MIN_VALUE
    private var bearing: Double?=null
    private var online=true
    fun start(org: String,plan: String,team: String,version: Long,key: String) {
        stop();mutable.value=NavigationState(org,plan,team,version,key);requestNeeded=true
    }
    fun stop() { spoken.clear();generation++;job?.cancel();job=null;tracker=null;point=null;lastFix=0;requestNeeded=false;wrong.reset();lastAttempt=Long.MIN_VALUE;bearing=null;mutable.value=NavigationState() }
    fun pause() { wrong.reset();bearing=null;lastFix=0;generation++;job?.cancel();job=null;point=null;mutable.value=mutable.value.copy(busy=false,locationReady=false,wrongWay=WrongWay.NORMAL);requestNeeded=mutable.value.route==null }
    fun unavailable() { point=null;bearing=null;wrong.reset();mutable.value=mutable.value.copy(locationReady=false,wrongWay=WrongWay.NORMAL) }
    fun updatePlan(version: Long,key: String,ready: Boolean,remaining: Set<String>) {
        val old=mutable.value;if(!old.active)return
        val currentKey=key+"/"+version+"/"+remaining.sorted().joinToString(",")
        val completed=old.route?.stops?.firstOrNull()?.item?.let { it !in remaining }==true
        if(remaining.isEmpty()) { stop();return }
        if(!ready) {
            generation++;job?.cancel();job=null
            mutable.value=old.copy(version=version,busy=false,awaitingCompletion=true);return
        }
        if(old.sourceKey!=currentKey || old.awaitingCompletion || completed) {
            generation++;job?.cancel();job=null;tracker=null;wrong.reset();lastAttempt=Long.MIN_VALUE;requestNeeded=true
            mutable.value=old.copy(version=version,sourceKey=currentKey,busy=false,awaitingCompletion=false,error=null,guidance=Guidance(),wrongWay=WrongWay.NORMAL)
            if(point!=null)request()
        } else mutable.value=old.copy(version=version)
    }
    fun fix(value: GeoPoint,accuracy: Float,at: Long,ageMillis: Long,speed: Double?=null,heading: Double?=null,connected: Boolean=true) {
        if(!mutable.value.active)return
        if(!value.valid || !accuracy.isFinite() || accuracy>NavigationThresholds.MAX_ACCURACY_METERS ||
            ageMillis !in 0..NavigationThresholds.MAX_FIX_AGE_MILLIS) { unavailable();return }
        if(at<=lastFix)return
        lastFix=at;point=value;bearing=heading;online=connected;mutable.value=mutable.value.copy(locationReady=true)
        if(requestNeeded) { if(online) { requestNeeded=false;request() };return }
        if(mutable.value.awaitingCompletion)return
        tracker?.sample(value,at)?.let { guidance ->
            val direction=if(mutable.value.busy)WrongWay.REROUTING else wrong.sample(value,at,speed,heading,guidance.expectedBearing)
            mutable.value=mutable.value.copy(guidance=guidance,wrongWay=direction)
            if((guidance.offRoute || direction==WrongWay.CONFIRMED) && !guidance.arrived && !mutable.value.busy &&
                (lastAttempt==Long.MIN_VALUE || at-lastAttempt>=NavigationMotion.COOLDOWN)) {
                if(online)request() else mutable.value=mutable.value.copy(error=RegistryError.NETWORK)
            }
        }
    }
    fun request() {
        val old=mutable.value;val origin=point ?: return
        if(!old.active || old.busy || old.awaitingCompletion)return
        if(old.route!=null && lastAttempt!=Long.MIN_VALUE && lastFix-lastAttempt<NavigationMotion.COOLDOWN)return
        if(!online) { mutable.value=old.copy(error=RegistryError.NETWORK);return }
        val stamp=generation
        lastAttempt=lastFix
        requestNeeded=false
        mutable.value=old.copy(busy=true,error=null,wrongWay=WrongWay.REROUTING)
        job=scope.launch {
            try {
                val route=load(NavigationRequest(old.organization,old.plan,old.team,old.version,origin,bearing))
                if(stamp!=generation)return@launch
                require(route.plan==old.plan && route.team==old.team && route.version==old.version && route.stops.isNotEmpty())
                tracker=NavigationProgress(route)
                wrong.reset()
                mutable.value=mutable.value.copy(route=route,routeSourceKey=old.sourceKey,routeRevision=old.routeRevision+1,
                    guidance=tracker!!.sample(point ?: origin,lastFix),busy=false,error=null,wrongWay=WrongWay.NORMAL)
            } catch(e: CancellationException) { if(stamp==generation)mutable.value=mutable.value.copy(busy=false);throw e }
            catch(e: Exception) { wrong.reset();if(stamp==generation)mutable.value=mutable.value.copy(busy=false,wrongWay=WrongWay.NORMAL,error=(e as? RegistryFailure)?.reason ?: RegistryError.ROUTE_PROVIDER) }
        }
    }
}
