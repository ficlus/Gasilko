package si.gasilko.app.feature.map

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.unit.dp
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
import si.gasilko.app.R
import java.net.URI

/** Rendering only: all hydrants are supplied by the existing local repository/ViewModel. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun MapScreen(onBack: () -> Unit, hydrants: List<Hydrant>, onOpenHydrant: (String) -> Unit,
    dataLoading: Boolean = false, dataError: RegistryError? = null, styleUrl: String = BuildConfig.MAP_STYLE_URL) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var attempt by rememberSaveable { mutableIntStateOf(0) }
    var displayedStyle by rememberSaveable(styleUrl) { mutableStateOf(styleUrl) }
    var regionBounds by remember { mutableStateOf<LatLngBounds?>(null) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var location by remember { mutableStateOf<Location?>(null) }
    var centerRequested by rememberSaveable { mutableStateOf(false) }
    var focus by remember { mutableStateOf<GeoPoint?>(null) }
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
    val selected = hydrants.find { it.id == selectedId && HydrantMapLayers.valid(it) }
    val validCount = remember(hydrants) { hydrants.count(HydrantMapLayers::valid) }
    val data by produceState<Pair<List<Hydrant>?,String>>(null to HydrantMapLayers.EMPTY, hydrants) {
        value = hydrants to withContext(Dispatchers.Default) { HydrantMapLayers.data(hydrants) }
    }
    // Never retain old features while a new scoped/filter result is being serialized.
    val visibleData = if(data.first == hydrants) data.second else HydrantMapLayers.EMPTY
    val currentData by rememberUpdatedState(visibleData)
    val currentRows by rememberUpdatedState(hydrants)
    val currentSelection by rememberUpdatedState(selected?.id)
    LaunchedEffect(hydrants, dataLoading) { if(!dataLoading && selected == null) selectedId=null }
    BackHandler(onBack=::back)
    Scaffold { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
        val headerHeight=maxHeight*0.5f
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.heightIn(max=headerHeight).verticalScroll(rememberScrollState())) {
            Row(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(16.dp)) {
                TextButton(onClick=::back) { Text(stringResource(R.string.h_back)) }
                Text(stringResource(R.string.map_title), Modifier.padding(top=12.dp), style=MaterialTheme.typography.titleLarge)
            }
            FlowRow(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                HydrantStatus.entries.forEach { status ->
                    Row(horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                        Text("●",Modifier.clearAndSetSemantics {},color=Color(HydrantMapLayers.color(status)))
                        Text(stringResource(statusLabel(status)),style=MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if(dataLoading)LinearProgressIndicator(Modifier.fillMaxWidth())
            LocationControls(hydrants, onLocation={location=it}, onCenter={cancelFocus();centerRequested=true},
                dataLoading=dataLoading,
                onUnavailable={centerRequested=false},
                onSelect={ h -> selectedId=h.id;cancelFocus();focus=GeoPoint(h.latitude!!,h.longitude!!) },
                additionalActions={ OfflineMapControls(displayedStyle, visibleBounds={
                    if(loading || failed || !valid) null else saved.view?.takeIf { !it.released && it.width>0 && it.height>0 }
                        ?.nativeMap?.projection?.visibleRegion?.latLngBounds
                }, onShow={ region ->
                    cancelFocus();regionBounds=region.definition.bounds
                    saved.bundle=saved.snapshot()
                    displayedStyle=region.definition.styleURL ?: styleUrl
                    attempt++
                }) })
            dataError?.let { Text(stringResource(errorLabel(it)), Modifier.padding(horizontal=16.dp), color=MaterialTheme.colorScheme.error) }
            if(!dataLoading && dataError==null) {
                val notice=when { hydrants.isEmpty()->R.string.map_empty;validCount==0->R.string.map_no_coordinates
                    validCount<hydrants.size->R.string.map_missing_coordinates;else->null }
                notice?.let { Text(stringResource(it,hydrants.size-validCount),Modifier.padding(horizontal=16.dp),style=MaterialTheme.typography.bodySmall) }
            }
            selected?.let { h ->
                Column(Modifier.padding(horizontal=16.dp)) {
                    Column {
                        Text(stringResource(R.string.map_selected),Modifier.semantics { heading() },style=MaterialTheme.typography.labelSmall)
                        Text(h.code ?: stringResource(R.string.h_pending_code))
                        if(h.code == null)Text(h.id, style=MaterialTheme.typography.labelSmall)
                        Text(stringResource(statusLabel(h.status)))
                        if(!h.active)Text(stringResource(R.string.h_inactive))
                    }
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick={cancelFocus();onOpenHydrant(h.id)}) { Text(stringResource(R.string.h_details)) }
                        TextButton(onClick={selectedId=null;cancelFocus()}) { Text(stringResource(R.string.map_clear_selection)) }
                    }
                }
            }
            if(loading)LinearProgressIndicator(Modifier.fillMaxWidth())
            if(loading)Text(stringResource(R.string.map_loading),Modifier.padding(horizontal=16.dp))
            if(failed || !valid) {
                Text(stringResource(if(valid) R.string.map_error else R.string.map_unconfigured),Modifier.padding(horizontal=16.dp))
                TextButton(onClick=::retry,modifier=Modifier.padding(horizontal=16.dp)) { Text(stringResource(R.string.map_retry)) }
            }
            }
            key(displayedStyle, attempt) {
                    // Factory creates one native view per entry/retry; ordinary recomposition only updates it.
                    AndroidView(modifier=Modifier.weight(1f).fillMaxWidth(), factory={ context ->
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
                                    updateLocation(currentLocation)
                                    renderReady=true
                                }
                            }
                            val fail: () -> Unit = {
                                if(!released && !fallback) {
                                    failed=true; loading=false;renderReady=false;hydrantLayers=null
                                    if(!fallback && readyMap != null) {
                                        fallback=true
                                        // Finish the SDK failure dispatch before replacing its style callback.
                                        post { if(!released) {
                                            hydrantLayers=null
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
                                        if(reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) cancelFocus()
                                    }
                                    if(saved.bundle == null) map.cameraPosition = CameraPosition.Builder().target(LatLng(46.15, 14.95)).zoom(6.0).build()
                                    map.addOnMapClickListener { point ->
                                        if(released || hydrantLayers==null) false else {
                                            val pixel=map.projection.toScreenLocation(point)
                                            val radius=12f * resources.displayMetrics.density
                                            val hits=map.queryRenderedFeatures(pixel, *HydrantMapLayers.layerIds).ifEmpty {
                                                map.queryRenderedFeatures(RectF(pixel.x-radius,pixel.y-radius,pixel.x+radius,pixel.y+radius), *HydrantMapLayers.layerIds)
                                            }
                                            val id=hits.mapNotNull { it.getStringProperty("uuid") }.distinct()
                                                .filter { uuid -> currentRows.any { it.id==uuid && HydrantMapLayers.valid(it) } }
                                                .minWithOrNull(compareBy<String> { uuid ->
                                                    val h=currentRows.first { it.id==uuid }
                                                    val p=map.projection.toScreenLocation(LatLng(h.latitude!!,h.longitude!!))
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
                        view.updateLocation(location)
                        regionBounds?.let { bounds -> view.nativeMap?.let { map -> if(renderReady) {
                            regionBounds=null
                            map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds,32))
                            map.moveCamera(CameraUpdateFactory.zoomTo(map.cameraPosition.zoom.coerceIn(
                                OfflineMapPolicy.MIN_ZOOM.toDouble(),OfflineMapPolicy.MAX_ZOOM.toDouble())))
                        } } }
                        val target=focus ?: location?.takeIf { centerRequested && freshLocation(it) }?.let { GeoPoint(it.latitude,it.longitude) }
                        view.nativeMap?.let { map -> if(target!=null && renderReady) {
                            centerRequested=false;focus=null
                            map.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(target.latitude,target.longitude),maxOf(map.cameraPosition.zoom,15.0)))
                        } }
                    } }, onReset=null, onRelease={
                        if(saved.view===it) { saved.bundle=saved.snapshot();saved.view=null }
                        it.release()
                    })
            }
        }
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

/** Owns the native view for exactly one Compose AndroidView attachment. */
private class LifecycleMapView(context: Context, private val lifecycle: Lifecycle, saved: Bundle?) : MapView(context) {
    var nativeMap: MapLibreMap? = null
    var hydrantLayers: HydrantMapLayers? = null
    var beforeRelease: (() -> Unit)? = null
    private var lastLocation: Location? = null
    private var locationStyle: Style? = null
    fun updateLocation(fix: Location?) {
        if(released) return
        val map=nativeMap ?: return
        val component=map.locationComponent
        if(fix == null || !freshLocation(fix) || !hasLocationPermission(context)) {
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
            if(!component.isLocationComponentEnabled) component.isLocationComponentEnabled=true
            val old=lastLocation
            if(old==null || old.elapsedRealtimeNanos!=fix.elapsedRealtimeNanos || old.latitude!=fix.latitude ||
                old.longitude!=fix.longitude || old.accuracy!=fix.accuracy) {
                component.forceLocationUpdate(fix);lastLocation=Location(fix)
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
        lifecycle.removeObserver(observer)
        context.applicationContext.unregisterComponentCallbacks(memory)
        stop()
        onDestroy()
    }
}
