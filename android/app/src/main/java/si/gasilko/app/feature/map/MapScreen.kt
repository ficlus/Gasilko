package si.gasilko.app.feature.map

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.os.SystemClock
import android.graphics.RectF
import android.location.Location
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import si.gasilko.app.feature.plans.orderedStops
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.location.LocationComponentActivationOptions
import org.maplibre.android.location.modes.CameraMode
import org.maplibre.android.location.modes.RenderMode
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.statusLabel
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.map.domain.GeoPoint
import si.gasilko.app.BuildConfig
import si.gasilko.app.core.ui.*
import si.gasilko.app.R
import si.gasilko.app.feature.plans.PlanRoute
import si.gasilko.app.feature.map.navigation.NavigationCamera
import si.gasilko.app.feature.map.navigation.NavigationThresholds
import java.net.URI

/** Rendering only: all hydrants are supplied by the existing local repository/ViewModel. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun MapScreen(onBack: () -> Unit, hydrants: List<Hydrant>, onOpenHydrant: ((String) -> Unit)?,
    dataLoading: Boolean = false, dataError: RegistryError? = null, styleUrl: String = BuildConfig.MAP_STYLE_URL,
    onAddHydrant: ((Double,Double,Float?)->Unit)? = null, creationEnabled: Boolean = true, route: PlanRoute? = null,
    photoPreview: @Composable (Hydrant)->Unit = {}, canOpenHydrant: (String)->Boolean = { true },
    completedHydrants: Set<String> = emptySet(), routeHydrantIds: Set<String>? = null,
    completedRouteNumbers: Map<String,Int> = emptyMap(),
    onSelectStart: ((Double,Double)->Unit)? = null, initialStart: GeoPoint? = null,
    navigationMode: Boolean=false, navigationContent: @Composable ()->Unit={},
    onLocationUpdate: (Location?)->Unit={}, followUser: Boolean=false, onUserPan: ()->Unit={},
    onRecenter: ()->Unit={}, requestLocationKey: String?=null) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val userPan by rememberUpdatedState(onUserPan)
    var lastFollowed by remember { mutableLongStateOf(0L) }
    val routeData=remember(route,completedHydrants,routeHydrantIds,completedRouteNumbers,hydrants) {
        route?.let { routeMapData(it,completedHydrants,routeHydrantIds,completedRouteNumbers,hydrants) }
    }
    val selectingStart by rememberUpdatedState(onSelectStart!=null)
    var startPoint by remember { mutableStateOf(initialStart?.takeIf { it.valid }) }
    val currentRoute by rememberUpdatedState(routeData)
    val routeStops=remember(route) { route?.orderedStops().orEmpty().associateBy { it.hydrantId } }
    var fittedRoute by rememberSaveable { mutableStateOf<String?>(null) }
    var mapSize by remember { mutableStateOf(IntSize.Zero) }
    var attempt by rememberSaveable { mutableIntStateOf(0) }
    var displayedStyle by rememberSaveable(styleUrl) { mutableStateOf(styleUrl) }
    var regionBounds by remember { mutableStateOf<LatLngBounds?>(null) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var location by remember { mutableStateOf<Location?>(null) }
    var centerRequested by rememberSaveable { mutableStateOf(false) }
    var focus by remember { mutableStateOf(initialStart?.takeIf { it.valid }) }
    // Keep the camera outside the native-view retry key.
    val saved = rememberSaveable(saver=Saver<SavedMap, Bundle>(
        save={it.snapshot()}, restore={SavedMap(it)})) { SavedMap() }
    var loading by remember(displayedStyle,attempt) { mutableStateOf(true) }
    var failed by remember(displayedStyle,attempt) { mutableStateOf(false) }
    var renderReady by remember(displayedStyle,attempt) { mutableStateOf(false) }
    val valid = remember(displayedStyle) {
        runCatching { URI(displayedStyle).let { it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null } }.getOrDefault(false)
    }
    fun cancelFocus() { centerRequested=false;focus=null;regionBounds=null }
    fun retry() { saved.bundle=saved.snapshot();attempt++ }
    fun back() { cancelFocus();onBack() }
    LaunchedEffect(centerRequested) { if(centerRequested) { delay(30_000);centerRequested=false } }
    val currentLocation by rememberUpdatedState(location)
    val addHydrant by rememberUpdatedState(onAddHydrant)
    val canCreate by rememberUpdatedState(creationEnabled)
    val selected = hydrants.find { it.id == selectedId && (route!=null || HydrantMapLayers.valid(it)) }
    val popupId=selectedId?.takeIf { selected!=null || it in routeData?.stopCoordinates.orEmpty() }
    val validCount = remember(hydrants) { hydrants.count(HydrantMapLayers::valid) }
    val data by produceState<Pair<List<Hydrant>?,String>>(null to HydrantMapLayers.EMPTY, hydrants) {
        value = hydrants to withContext(Dispatchers.Default) { HydrantMapLayers.data(hydrants) }
    }
    // Never retain old features while a new scoped/filter result is being serialized.
    val visibleData = if(route==null && data.first == hydrants) data.second else HydrantMapLayers.EMPTY
    val currentData by rememberUpdatedState(visibleData)
    val currentRows by rememberUpdatedState(hydrants)
    val currentSelection by rememberUpdatedState(selected?.id)
    LaunchedEffect(hydrants, dataLoading, routeData) { if(!dataLoading && popupId==null) selectedId=null }
    BackHandler(onBack=::back)
    Scaffold { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
        val headerHeight=maxHeight*0.5f
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.heightIn(max=headerHeight).verticalScroll(rememberScrollState())) {
            FlowRow(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(16.dp)) {
                TextButton(onClick=::back) { ActionLabel(stringResource(R.string.h_back),R.drawable.ic_field_arrow_back) }
                Text(stringResource(R.string.map_title), Modifier.padding(top=12.dp), style=MaterialTheme.typography.titleLarge)
            }
            navigationContent()
            if(!navigationMode)FlowRow(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                HydrantStatus.entries.forEach { status ->
                    Row(horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                        Text("●",Modifier.clearAndSetSemantics {},color=Color(HydrantMapLayers.color(status)))
                        Text(stringResource(statusLabel(status)),style=MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if(onSelectStart!=null) {
                Text(stringResource(R.string.plans_pick_start_hint),Modifier.padding(horizontal=16.dp))
                TextButton(onClick={startPoint?.let { onSelectStart(it.latitude,it.longitude) }},enabled=startPoint!=null) {
                    Text(stringResource(R.string.plans_use_start))
                }
            }
            if(dataLoading)LinearProgressIndicator(Modifier.fillMaxWidth())
            LocationControls(hydrants, onLocation={location=it;onLocationUpdate(it)}, onCenter={cancelFocus();centerRequested=true;onRecenter()},
                requestLocationKey=requestLocationKey,
                centerLabel=if(navigationMode)R.string.nav_follow else R.string.map_my_location,
                dataLoading=dataLoading,
                onUseLocation=onAddHydrant?.let { { fix: Location ->
                    if(canCreate) { cancelFocus();addHydrant?.invoke(fix.latitude,fix.longitude,fix.accuracy) }
                } },useLocationLabel=R.string.h_add,actionEnabled=creationEnabled,
                onUnavailable={centerRequested=false},
                onSelect={ h -> selectedId=h.id;cancelFocus();userPan();focus=GeoPoint(h.latitude!!,h.longitude!!) },
                additionalActions={ if(!navigationMode)OfflineMapControls(displayedStyle, visibleBounds={
                    if(loading || failed || !valid) null else saved.view?.takeIf { !it.released && it.width>0 && it.height>0 }
                        ?.nativeMap?.projection?.visibleRegion?.latLngBounds
                }, onShow={ region ->
                    cancelFocus();regionBounds=region.definition.bounds
                    saved.bundle=saved.snapshot()
                    displayedStyle=region.definition.styleURL ?: styleUrl
                    attempt++
                }) })
            dataError?.let { FieldBanner(stringResource(errorLabel(it)), FieldTone.DANGER, Modifier.padding(horizontal=16.dp)) }
            if(route!=null) {
                RouteAttribution(route.provider)
                Text(stringResource(R.string.routes_completed_legend),Modifier.padding(horizontal=16.dp))
                if(!route.valid)FieldBanner(stringResource(R.string.routes_stale),FieldTone.WARNING)
            }
            if(!navigationMode && routeData?.numbers?.size==1)Text(stringResource(R.string.routes_single_stop),Modifier.padding(horizontal=16.dp))
            else if(!navigationMode && routeData!=null && !routeData.hasRoad && routeData.numbers.isNotEmpty())
                Text(stringResource(R.string.routes_no_road_geometry),Modifier.padding(horizontal=16.dp))
            if(!navigationMode && !dataLoading && dataError==null && route==null) {
                val notice=when { hydrants.isEmpty()->R.string.map_empty;validCount==0->R.string.map_no_coordinates
                    validCount<hydrants.size->R.string.map_missing_coordinates;else->null }
                notice?.let { Text(stringResource(it,hydrants.size-validCount),Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.bodySmall) }
            }
            if(loading)LinearProgressIndicator(Modifier.fillMaxWidth())
            if(loading)Text(stringResource(R.string.map_loading),Modifier.padding(horizontal=16.dp))
            if(failed || !valid) {
                FieldBanner(stringResource(if(valid) R.string.map_error else R.string.map_unconfigured),FieldTone.WARNING,Modifier.padding(horizontal=16.dp))
                CompactAction(onClick=::retry,modifier=Modifier.padding(horizontal=16.dp)) { ActionLabel(stringResource(R.string.map_retry),R.drawable.ic_field_refresh) }
            }
            }
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val popupHeight=maxHeight*0.65f
            key(displayedStyle, attempt) {
                    // Factory creates one native view per entry/retry; ordinary recomposition only updates it.
                    AndroidView(modifier=Modifier.fillMaxSize().onSizeChanged { mapSize=it }, factory={ context ->
                        MapLibre.getInstance(context.applicationContext)
                        LifecycleMapView(context, lifecycle, saved.bundle).apply {
                            saved.view=this
                            beforeRelease={if(saved.view===this) saved.bundle=saved.snapshot()}
                            contentDescription=context.getString(R.string.map_canvas)
                            var readyMap: MapLibreMap? = null
                            var fallback = false
                            fun install(style: Style) {
                                if(!released) {
                                    hydrantLayers=HydrantMapLayers(style); hydrantLayers?.update(currentData,currentSelection)
                                    routeLayers=PlanRouteLayers(style);routeLayers?.update(currentRoute)
                                    updateLocation(currentLocation,navigationMode)
                                    renderReady=true
                                }
                            }
                            val fail: () -> Unit = {
                                if(!released && !fallback) {
                                    failed=true; loading=false;renderReady=false;hydrantLayers=null;routeLayers=null
                                    if(!fallback && readyMap != null) {
                                        fallback=true
                                        // Finish the SDK failure dispatch before replacing its style callback.
                                        post { if(!released) {
                                            hydrantLayers=null;routeLayers=null
                                            readyMap?.setStyle(Style.Builder().fromJson(HydrantMapLayers.OFFLINE_STYLE)) { install(it) }
                                        } }
                                    }
                                }
                            }
                            addOnDidFailLoadingMapListener { _ -> fail() }
                            if(!released) getMapAsync { map ->
                                if(!released) {
                                    readyMap=map
                                    nativeMap=map
                                    map.addOnCameraMoveStartedListener { reason ->
                                        if(reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) { cancelFocus();userPan() }
                                    }
                                    if(saved.bundle == null) map.cameraPosition = CameraPosition.Builder().target(LatLng(46.15, 14.95)).zoom(6.0).build()
                                    map.addOnMapLongClickListener { point ->
                                        if(released || selectingStart || !canCreate || addHydrant==null || !GeoPoint(point.latitude,point.longitude).valid)false
                                        else {
                                            cancelFocus()
                                            addHydrant?.invoke(point.latitude,point.longitude,null)
                                            true
                                        }
                                    }
                                    map.addOnMapClickListener { point ->
                                        if(released || hydrantLayers==null) false else if(selectingStart) {
                                            startPoint=GeoPoint(point.latitude,point.longitude);cancelFocus();true
                                        } else {
                                            val pixel=map.projection.toScreenLocation(point)
                                            val radius=12f * resources.displayMetrics.density
                                            val routing=currentRoute
                                            val layers=if(routing!=null)arrayOf(PlanRouteLayers.STOP_LAYER) else HydrantMapLayers.layerIds
                                            val hits=map.queryRenderedFeatures(pixel, *layers).ifEmpty {
                                                map.queryRenderedFeatures(RectF(pixel.x-radius,pixel.y-radius,pixel.x+radius,pixel.y+radius), *layers)
                                            }
                                            val id=hits.mapNotNull { it.getStringProperty("uuid") }.distinct()
                                                .filter { uuid -> if(routing!=null)uuid in routing.stopCoordinates else currentRows.any { it.id==uuid && HydrantMapLayers.valid(it) } }
                                                .minWithOrNull(compareBy<String> { uuid ->
                                                    val position=routing?.stopCoordinates?.get(uuid) ?: currentRows.first { it.id==uuid }.let { LatLng(it.latitude!!,it.longitude!!) }
                                                    val p=map.projection.toScreenLocation(position)
                                                    (p.x-pixel.x)*(p.x-pixel.x)+(p.y-pixel.y)*(p.y-pixel.y)
                                                }.thenBy { it })
                                            cancelFocus();selectedId=id
                                            selectedId != null
                                        }
                                    }
                                    // Keep MapLibre's attribution controls and source attribution visible.
                                    try {
                                        if(valid) map.setStyle(displayedStyle) { if(!released && !fallback) { install(it); loading=false; failed=false } }
                                        else fail()
                                    } catch(_: RuntimeException) { fail() }
                                }
                            }
                        }
                    }, update={ view -> if(!view.released) {
                        view.hydrantLayers?.update(visibleData, selected?.id)
                        view.routeLayers?.update(routeData)
                        view.nativeMap?.style?.takeIf { it.isFullyLoaded }?.let { style -> StartPointLayer.update(style,startPoint) }
                        if(!navigationMode && renderReady && mapSize.width>0 && mapSize.height>0 && view.width>0 && view.height>0 && routeData!=null &&
                            fittedRoute!=routeData.key && routeData.points.isNotEmpty()) {
                            val target=routeData
                            view.post { if(!view.released && view.routeLayers!=null && currentRoute?.key==target.key && fittedRoute!=target.key) {
                                val points=target.points.distinctBy { it.latitude to it.longitude }
                                view.nativeMap?.let { map ->
                                    if(points.size==1)map.moveCamera(CameraUpdateFactory.newLatLngZoom(points.first(),15.0))
                                    else map.moveCamera(CameraUpdateFactory.newLatLngBounds(LatLngBounds.Builder().includes(points).build(),48))
                                    fittedRoute=target.key
                                }
                            } }
                        }
                        view.updateLocation(location,navigationMode)
                        regionBounds?.let { bounds -> view.nativeMap?.let { map -> if(renderReady) {
                            regionBounds=null
                            map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds,32))
                            map.moveCamera(CameraUpdateFactory.zoomTo(map.cameraPosition.zoom.coerceIn(
                                OfflineMapPolicy.MIN_ZOOM.toDouble(),OfflineMapPolicy.MAX_ZOOM.toDouble())))
                        } } }
                        if(navigationMode && focus==null && renderReady && (followUser || centerRequested)) {
                            location?.takeIf(::usableNavigationLocation)?.let { fix ->
                                view.nativeMap?.let { map -> view.navigationCamera.follow(map,fix,view.width,view.height,centerRequested) }
                                centerRequested=false
                            }
                        }
                        val target=focus ?: location?.takeIf { !navigationMode && (centerRequested || (followUser && it.elapsedRealtimeNanos!=lastFollowed)) && freshLocation(it) }?.let { GeoPoint(it.latitude,it.longitude) }
                        view.nativeMap?.let { map -> if(target!=null && renderReady) {
                            centerRequested=false;focus=null;lastFollowed=location?.elapsedRealtimeNanos ?: 0L
                            map.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(target.latitude,target.longitude),maxOf(map.cameraPosition.zoom,15.0)))
                        } }
                    } }, onReset=null, onRelease={
                        if(saved.view===it) { saved.bundle=saved.snapshot();saved.view=null }
                        it.release()
                    })
            }
            if(navigationMode && !followUser)Surface(Modifier.align(Alignment.TopEnd).padding(12.dp),
                shape=MaterialTheme.shapes.medium,tonalElevation=3.dp) {
                CompactAction(onClick={cancelFocus();centerRequested=true;onRecenter()},
                    enabled=location?.let(::usableNavigationLocation)==true) {
                    ActionLabel(stringResource(R.string.nav_follow),R.drawable.ic_field_my_location)
                }
            }
            popupId?.let { id -> key(id) {
                // Leave the native attribution/logo edge visible; the card scrolls on short screens.
                Box(Modifier.align(Alignment.BottomCenter).padding(start=12.dp,end=12.dp,bottom=48.dp)
                    .heightIn(max=popupHeight).verticalScroll(rememberScrollState())) {
                    HydrantMapPopup(id,selected,routeStops[id]?.code,
                        open=if(selected!=null && onOpenHydrant!=null && canOpenHydrant(id))({cancelFocus();onOpenHydrant(id)}) else null,
                        close={selectedId=null;cancelFocus()},photo=photoPreview)
                }
            } }
            }
        }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun RouteAttribution(provider: String="GraphHopper") {
    val uri=LocalUriHandler.current
    Column(Modifier.padding(horizontal=16.dp)) {
        Text(stringResource(R.string.routes_attribution,provider),style=MaterialTheme.typography.bodySmall)
        FlowRow {
            if(provider.contains("OSRM"))TextButton(onClick={uri.openUri("https://project-osrm.org/")}) { Text("OSRM") }
            if(provider.contains("GraphHopper"))TextButton(onClick={uri.openUri("https://www.graphhopper.com/")}) { Text("GraphHopper") }
            TextButton(onClick={uri.openUri("https://www.openstreetmap.org/copyright")}) { Text("© OpenStreetMap") }
        }
    }
}

private class SavedMap(var bundle: Bundle? = null) {
    var view: LifecycleMapView? = null
    fun snapshot() = Bundle().also { state ->
        val current = view
        if(current != null && !current.released) current.onSaveInstanceState(state)
        else bundle?.let { state.putAll(it) }
    }
}

private fun usableNavigationLocation(fix: Location)=freshLocation(fix) && fix.hasAccuracy() &&
    fix.accuracy<=NavigationThresholds.MAX_ACCURACY_METERS &&
    SystemClock.elapsedRealtime()-fix.elapsedRealtimeNanos/1_000_000<=NavigationThresholds.MAX_FIX_AGE_MILLIS

/** Owns the native view for exactly one Compose AndroidView attachment. */
private class LifecycleMapView(context: Context, private val lifecycle: Lifecycle, saved: Bundle?) : MapView(context) {
    var nativeMap: MapLibreMap? = null
    var hydrantLayers: HydrantMapLayers? = null
    var routeLayers: PlanRouteLayers? = null
    var beforeRelease: (() -> Unit)? = null
    private var lastLocation: Location? = null
    private var locationStyle: Style? = null
    val navigationCamera = NavigationCamera()
    fun updateLocation(fix: Location?, navigation: Boolean = false) {
        if(released) return
        val map=nativeMap ?: return
        val component=map.locationComponent
        if(fix == null || !freshLocation(fix) || !hasLocationPermission(context) || (navigation && !usableNavigationLocation(fix))) {
            lastLocation=null
            if(component.isLocationComponentActivated && component.isLocationComponentEnabled) component.isLocationComponentEnabled=false
            return
        }
        val style=map.style ?: return
        if(locationStyle !== style) { locationStyle=style;lastLocation=null }
        try {
            if(!component.isLocationComponentActivated) {
                component.activateLocationComponent(LocationComponentActivationOptions.builder(context,style).useDefaultLocationEngine(false).build())
                component.cameraMode=CameraMode.NONE
                component.renderMode=RenderMode.NORMAL
            }
            val renderedFix=if(navigation)navigationCamera.location(fix) else fix
            val mode=if(navigation && renderedFix.hasBearing())RenderMode.GPS else RenderMode.NORMAL
            if(component.renderMode!=mode)component.renderMode=mode
            if(!component.isLocationComponentEnabled) component.isLocationComponentEnabled=true
            val old=lastLocation
            if(old==null || old.elapsedRealtimeNanos!=fix.elapsedRealtimeNanos || old.latitude!=fix.latitude ||
                old.longitude!=fix.longitude || old.accuracy!=fix.accuracy) {
                component.forceLocationUpdate(renderedFix);lastLocation=Location(fix)
            }
        } catch(_: SecurityException) { if(component.isLocationComponentActivated) component.isLocationComponentEnabled=false }
    }
    var released = false
        private set
    private var started = false
    private var resumed = false
    private val memory = object : ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: Configuration) = Unit
        override fun onLowMemory() { if(!released) this@LifecycleMapView.onLowMemory() }
        override fun onTrimMemory(level: Int) { if(!released) this@LifecycleMapView.onLowMemory() }
    }
    private val observer = LifecycleEventObserver { _, event ->
        if(!released) when(event) {
            Lifecycle.Event.ON_START -> if(!started) { onStart(); started=true }
            Lifecycle.Event.ON_RESUME -> if(!resumed) { onResume(); resumed=true }
            Lifecycle.Event.ON_PAUSE -> pause()
            Lifecycle.Event.ON_STOP -> stop()
            Lifecycle.Event.ON_DESTROY -> release()
            else -> Unit
        }
    }
    init {
        onCreate(saved)
        context.applicationContext.registerComponentCallbacks(memory)
        // addObserver catches up START/RESUME when the map is opened in an already resumed activity.
        if(lifecycle.currentState == Lifecycle.State.DESTROYED) release() else lifecycle.addObserver(observer)
    }
    private fun pause() { if(resumed) { onPause(); resumed=false } }
    private fun stop() { pause(); if(started) { onStop(); started=false } }
    fun release() {
        if(released) return
        beforeRelease?.invoke();beforeRelease=null
        released=true
        lastLocation=null;locationStyle=null
        nativeMap=null
        hydrantLayers=null
        routeLayers=null
        lifecycle.removeObserver(observer)
        context.applicationContext.unregisterComponentCallbacks(memory)
        stop()
        onDestroy()
    }
}
