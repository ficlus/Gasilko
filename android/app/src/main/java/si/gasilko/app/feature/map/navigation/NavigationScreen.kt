package si.gasilko.app.feature.map.navigation

import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.Hydrant
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.map.MapScreen
import si.gasilko.app.feature.map.domain.GeoPoint
import si.gasilko.app.feature.plans.PlanItem
import si.gasilko.app.feature.plans.PlanRoute
import java.util.Locale
import kotlin.math.roundToInt

internal object NavigationPresentation {
    const val PHOTO_METERS=200.0
    const val LARGE_PHOTO_METERS=50.0
    const val ROAD_UPDATE_METERS=10.0
}

internal fun maneuverLabel(step: NavigationStep?): Int {
    if(step?.modifier=="uturn")return R.string.nav_uturn
    return when(step?.type) {
        "depart"->R.string.nav_depart;"arrive"->R.string.nav_arrive
        "roundabout","rotary","roundabout turn","exit roundabout","exit rotary"->R.string.nav_roundabout
        "merge"->R.string.nav_merge;"fork"->R.string.nav_fork;"on ramp"->R.string.nav_on_ramp;"off ramp"->R.string.nav_off_ramp
        "turn","continue","new name","end of road"->when(step?.modifier) {
            "left"->R.string.nav_left;"right"->R.string.nav_right
            "slight left"->R.string.nav_slight_left;"slight right"->R.string.nav_slight_right
            "sharp left"->R.string.nav_sharp_left;"sharp right"->R.string.nav_sharp_right
            else->R.string.nav_continue
        }
        else->R.string.nav_continue
    }
}
private fun maneuverIcon(step: NavigationStep?)=when {
    step?.modifier=="uturn"->"↶"
    step?.type in listOf("roundabout","rotary","roundabout turn")->"⟳"
    step?.type=="arrive"->"⚑"
    step?.modifier?.contains("left")==true->"↰"
    step?.modifier?.contains("right")==true->"↱"
    else->"↑"
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun NavigationScreen(session: NavigationSession,hydrants: List<Hydrant>,items: List<PlanItem>,cached: PlanRoute?,
    onOpen: (String)->Unit,canOpen: (String)->Boolean,photo: @Composable (Hydrant) -> Unit,
    targetPhoto: @Composable (Hydrant,Boolean,Boolean) -> Unit) {
    val state by session.state.collectAsStateWithLifecycle()
    var follow by rememberSaveable(state.plan,state.team) { mutableStateOf(true) }
    val context=LocalContext.current
    var animatedArrows by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(state.routeRevision) { if(state.routeRevision>0)follow=true }
    val displayLegs=remember(state.route) { state.route?.displayLegs() }
    val readyGuidance=!state.awaitingCompletion && state.routeSourceKey==state.sourceKey
    val guidance=if(readyGuidance)state.guidance else Guidance()
    val roadProgress=kotlin.math.floor(guidance.geometryMeters/NavigationPresentation.ROAD_UPDATE_METERS)*NavigationPresentation.ROAD_UPDATE_METERS
    val route=remember(state.route,state.routeRevision,roadProgress,readyGuidance) {
        state.route?.let { it.mapRoute(state.organization,"navigation-${state.routeRevision}",if(readyGuidance)remainingRoad(displayLegs?.first.orEmpty(),roadProgress) else emptyList(),if(readyGuidance)displayLegs?.second.orEmpty() else it.points) }
    }?.let { it.copy(valid=readyGuidance && cached?.valid!=false) } ?: cached
    val target=state.route?.takeIf { readyGuidance }?.stops?.firstOrNull()
    val targetHydrant=hydrants.find { it.id==target?.hydrant && it.organization==state.organization }
    val approaching=state.locationReady && (guidance.arrived || guidance.toTarget<=NavigationPresentation.PHOTO_METERS)
    val close=guidance.arrived || guidance.toTarget<=NavigationPresentation.LARGE_PHOTO_METERS
    val label=stringResource(if(guidance.arrived)R.string.nav_arrive else maneuverLabel(guidance.next))
    val meters=(guidance.toManeuver/10).roundToInt()*10
    val distance=stringResource(R.string.nav_distance,meters)
    val speech=when {
        !readyGuidance->null
        !state.locationReady->null
        state.busy && state.route!=null->"reroute-${target?.item}" to stringResource(R.string.nav_recalculating)
        state.error!=null->"error-${state.routeRevision}" to stringResource(R.string.nav_reroute_failed)
        guidance.arrived->"arrival-${target?.item}" to stringResource(R.string.nav_arrival_voice,target?.code ?: target?.hydrant?.take(8).orEmpty())
        state.route!=null->{
            val phase=when { guidance.toManeuver<=NavigationThresholds.TURN_NOW_METERS->"now"
                guidance.toManeuver<=NavigationThresholds.ANNOUNCE_METERS->"soon";else->"ahead" }
            "${state.routeRevision}-${guidance.step}-$phase" to "$distance. $label. ${guidance.next?.road.orEmpty()}"
        }
        else->null
    }
    val voiceUnavailable=NavigationSpeech(session,speech)
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle,session) {
        val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_STOP)session.pause() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer);session.pause() }
    }
    MapScreen(onBack=session::stop,hydrants=hydrants,onOpenHydrant=onOpen,route=route,
        canOpenHydrant=canOpen,photoPreview=photo,
        completedHydrants=items.filter { it.inspectionId!=null }.map { it.hydrantId }.toSet(),
        routeHydrantIds=items.map { it.hydrantId }.toSet(),
        completedRouteNumbers=items.filter { it.inspectionId!=null && it.routeOrder!=null }.associate { it.hydrantId to it.routeOrder!! },
        navigationMode=true,animatedRouteArrows=animatedArrows,followUser=follow && state.locationReady,onUserPan={follow=false},onRecenter={follow=true},
        requestLocationKey=state.plan+state.team,
        onLocationUpdate={ fix -> if(fix==null || !fix.hasAccuracy())session.unavailable() else {
            val at=fix.elapsedRealtimeNanos/1_000_000
                        val connectivity=context.getSystemService(android.net.ConnectivityManager::class.java)
            val connected=connectivity?.getNetworkCapabilities(connectivity.activeNetwork)
                ?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true
            session.fix(GeoPoint(fix.latitude,fix.longitude),fix.accuracy,at,SystemClock.elapsedRealtime()-at,
                NavigationMotion.speed(fix),NavigationMotion.bearing(fix),connected)
        } },
        navigationContent={
            OperationalCard(modifier=Modifier.fillMaxWidth().padding(horizontal=12.dp)) {
                Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                    Text(maneuverIcon(guidance.next),style=MaterialTheme.typography.headlineLarge)
                    Column(Modifier.weight(1f)) {
                        Text(if(state.awaitingCompletion)stringResource(R.string.nav_wait_sync) else if(state.route==null)stringResource(R.string.nav_start) else if(guidance.arrived)label else distance,
                            style=if(guidance.arrived)MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineMedium)
                        if(state.route!=null && readyGuidance && !guidance.arrived)Text(label,style=MaterialTheme.typography.titleMedium)
                        if(!guidance.arrived)guidance.next?.road?.takeIf { it.isNotBlank() }?.let { Text(it) }
                        if(!approaching)target?.let { Text(stringResource(R.string.nav_target,it.code ?: it.hydrant.take(8))) }
                    }
                }
                if(state.route!=null && readyGuidance)Text(stringResource(R.string.nav_remaining,(guidance.remaining/100).roundToInt()/10.0,
                    kotlin.math.ceil(guidance.seconds/60).toInt()))
                targetHydrant?.let { hydrant ->
                    if(approaching) {
                        Text(hydrant.code ?: (stringResource(R.string.h_pending_code)+" · "+hydrant.id.take(8)),
                            style=MaterialTheme.typography.titleLarge)
                        listOfNotNull(hydrant.address,hydrant.description).filter { it.isNotBlank() }.distinct().forEach { Text(it) }
                        Text(stringResource(R.string.nav_access_distance,guidance.toTarget.roundToInt()),style=MaterialTheme.typography.bodyMedium)
                    }
                    // Keep this scoped loader in composition as distance changes, including outside 200 m.
                    targetPhoto(hydrant,approaching,close)
                }
                target?.let { stop -> if(canOpen(stop.hydrant))PrimaryAction(onClick={onOpen(stop.hydrant)}) {
                    Text(stringResource(R.string.nav_inspect))
                } }
                if(!follow)Text(stringResource(R.string.nav_follow_paused),style=MaterialTheme.typography.labelLarge)
                if(voiceUnavailable)Text(stringResource(R.string.nav_voice_unavailable),style=MaterialTheme.typography.bodySmall)
                if(state.busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                when {
                    state.awaitingCompletion->FieldBanner(stringResource(R.string.nav_wait_sync),FieldTone.WARNING)
                    !state.locationReady->FieldBanner(stringResource(R.string.nav_wait_location),FieldTone.WARNING)
                    state.error!=null->FieldBanner(stringResource(R.string.nav_reroute_failed)+" "+stringResource(errorLabel(state.error!!)),FieldTone.WARNING)
                    state.wrongWay==WrongWay.CONFIRMED || state.wrongWay==WrongWay.REROUTING->FieldBanner(stringResource(if(state.busy)R.string.nav_recalculating else R.string.nav_wrong_way),FieldTone.WARNING)
                    guidance.offRoute->FieldBanner(stringResource(if(state.busy)R.string.nav_recalculating else R.string.nav_off_route),FieldTone.WARNING)
                    state.route?.legs.isNullOrEmpty()->Text(stringResource(R.string.nav_basic))
                }
                Row(verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
                    Switch(checked=animatedArrows,onCheckedChange={animatedArrows=it})
                    Text(stringResource(R.string.nav_animated_arrows))
                }
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick=session::stop) { Text(stringResource(R.string.nav_stop)) }
                    if(state.error!=null || guidance.offRoute)TextButton(onClick=session::request,
                        enabled=!state.busy && state.locationReady && !state.awaitingCompletion) { Text(stringResource(R.string.nav_retry)) }
                }
            }
        })
}

@Composable
private fun NavigationSpeech(session: NavigationSession,message: Pair<String,String>?): Boolean {
    val context=LocalContext.current
    val language=if(LocalConfiguration.current.locales[0].language=="de")"de" else "sl"
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var engine by remember { mutableStateOf<TextToSpeech?>(null) }
    var unavailable by remember { mutableStateOf(false) }
    DisposableEffect(language,lifecycle) {
        var disposed=false
        var tts: TextToSpeech?=null
        try {
            tts=TextToSpeech(context.applicationContext) { result -> Handler(Looper.getMainLooper()).post {
                if(!disposed) {
                    val ready=runCatching { result==TextToSpeech.SUCCESS && (tts?.setLanguage(Locale(language)) ?: TextToSpeech.LANG_NOT_SUPPORTED)>=0 }.getOrDefault(false)
                    engine=tts.takeIf { ready };unavailable=!ready
                }
            } }
        } catch(_: Exception) { unavailable=true }
        val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_STOP)tts?.stop() }
        lifecycle.addObserver(observer)
        onDispose { disposed=true;lifecycle.removeObserver(observer);engine=null;tts?.stop();tts?.shutdown() }
    }
    LaunchedEffect(engine,message?.first,lifecycle.currentState) {
        val tts=engine;val value=message
        if(value==null)tts?.stop()
        if(tts!=null && value!=null && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) && value.first !in session.spoken) {
            if(tts.speak(value.second,TextToSpeech.QUEUE_FLUSH,null,value.first)==TextToSpeech.SUCCESS)session.spoken.add(value.first)
        }
    }
    return unavailable
}
