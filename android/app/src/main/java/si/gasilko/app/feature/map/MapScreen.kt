package si.gasilko.app.feature.map

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.graphics.RectF
import android.location.Location
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
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
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import kotlinx.coroutines.Dispatchers
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
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var location by remember { mutableStateOf<Location?>(null) }
    var centerRequested by rememberSaveable { mutableStateOf(false) }
    var focus by remember { mutableStateOf<GeoPoint?>(null) }
    val currentLocation by rememberUpdatedState(location)
    val selected = hydrants.find { it.id == selectedId && HydrantMapLayers.valid(it) }
    val data by produceState(HydrantMapLayers.EMPTY, hydrants) {
        value = withContext(Dispatchers.Default) { HydrantMapLayers.data(hydrants) }
    }
    val visibleData = if(hydrants.isEmpty()) HydrantMapLayers.EMPTY else data
    val currentData by rememberUpdatedState(visibleData)
    val currentRows by rememberUpdatedState(hydrants)
    val currentSelection by rememberUpdatedState(selected?.id)
    LaunchedEffect(hydrants, dataLoading) { if(!dataLoading && selected == null) selectedId=null }
    BackHandler(onBack=onBack)
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Row(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(16.dp)) {
                TextButton(onClick=onBack) { Text(stringResource(R.string.h_back)) }
                Text(stringResource(R.string.map_title), Modifier.padding(top=12.dp), style=MaterialTheme.typography.titleLarge)
            }
            FlowRow(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                HydrantStatus.entries.forEach { status ->
                    Text("● " + stringResource(statusLabel(status)), color=Color(HydrantMapLayers.color(status)), style=MaterialTheme.typography.labelSmall)
                }
            }
            if(dataLoading)LinearProgressIndicator(Modifier.fillMaxWidth())
            LocationControls(hydrants, onLocation={location=it}, onCenter={centerRequested=true;focus=null},
                onSelect={ h -> selectedId=h.id;centerRequested=false;focus=GeoPoint(h.latitude!!,h.longitude!!) })
            dataError?.let { Text(stringResource(errorLabel(it)), Modifier.padding(horizontal=16.dp), color=MaterialTheme.colorScheme.error) }
            selected?.let { h ->
                Row(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(h.code ?: stringResource(R.string.h_pending_code))
                        if(h.code == null)Text(h.id, style=MaterialTheme.typography.labelSmall)
                        Text(stringResource(statusLabel(h.status)))
                        if(!h.active)Text(stringResource(R.string.h_inactive))
                    }
                    TextButton(onClick={onOpenHydrant(h.id)}) { Text(stringResource(R.string.h_details)) }
                }
            }
            key(styleUrl, attempt) {
                val saved = rememberSaveable(saver=Saver<SavedMap, Bundle>(
                    save={it.snapshot()}, restore={SavedMap(it)})) { SavedMap() }
                var loading by remember { mutableStateOf(true) }
                var failed by remember { mutableStateOf(false) }
                val valid = remember(styleUrl) {
                    runCatching { URI(styleUrl).let { it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null } }.getOrDefault(false)
                }
                if(valid) {
                    // Factory creates one native view per entry/retry; ordinary recomposition only updates it.
                    AndroidView(modifier=Modifier.weight(1f).fillMaxWidth(), factory={ context ->
                        MapLibre.getInstance(context.applicationContext)
                        LifecycleMapView(context, lifecycle, saved.bundle).apply {
                            saved.view=this
                            var readyMap: MapLibreMap? = null
                            var fallback = false
                            fun install(style: Style) {
                                if(!released) {
                                    hydrantLayers=HydrantMapLayers(style); hydrantLayers?.update(currentData,currentSelection)
                                    updateLocation(currentLocation)
                                }
                            }
                            val fail: () -> Unit = {
                                if(!released) {
                                    failed=true; loading=false
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
                                        if(reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) { centerRequested=false;focus=null }
                                    }
                                    if(saved.bundle == null) map.cameraPosition = CameraPosition.Builder().target(LatLng(46.15, 14.95)).zoom(6.0).build()
                                    map.addOnMapClickListener { point ->
                                        if(released) false else {
                                            val pixel=map.projection.toScreenLocation(point)
                                            val radius=12f * resources.displayMetrics.density
                                            val hits=map.queryRenderedFeatures(pixel, *HydrantMapLayers.layerIds).ifEmpty {
                                                map.queryRenderedFeatures(RectF(pixel.x-radius,pixel.y-radius,pixel.x+radius,pixel.y+radius), *HydrantMapLayers.layerIds)
                                            }
                                            val id=hits
                                                .mapNotNull { it.getStringProperty("uuid") }.sorted().firstOrNull()
                                            selectedId=id?.takeIf { uuid -> currentRows.any { it.id==uuid && HydrantMapLayers.valid(it) } }
                                            selectedId != null
                                        }
                                    }
                                    // Keep MapLibre's attribution controls and source attribution visible.
                                    try {
                                        map.setStyle(styleUrl) { if(!released) { install(it); loading=false; failed=false } }
                                    } catch(_: RuntimeException) { fail() }
                                }
                            }
                        }
                    }, update={ view -> if(!view.released) {
                        view.hydrantLayers?.update(visibleData, selected?.id)
                        view.updateLocation(location)
                        val target=focus ?: location?.takeIf { centerRequested }?.let { GeoPoint(it.latitude,it.longitude) }
                        view.nativeMap?.let { map -> if(target!=null && map.style!=null) {
                            centerRequested=false;focus=null
                            map.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(target.latitude,target.longitude),maxOf(map.cameraPosition.zoom,15.0)))
                        } }
                    } }, onReset=null, onRelease={
                        saved.bundle=saved.snapshot(); saved.view=null; it.release()
                    })
                } else Spacer(Modifier.weight(1f))
                if(loading && valid) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text(stringResource(R.string.map_loading), Modifier.padding(16.dp))
                }
                if(failed || !valid) {
                    Text(stringResource(if(valid) R.string.map_error else R.string.map_unconfigured), Modifier.padding(horizontal=16.dp))
                    TextButton(onClick={attempt++}, modifier=Modifier.padding(horizontal=16.dp)) { Text(stringResource(R.string.map_retry)) }
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
    fun updateLocation(fix: Location?) {
        if(released) return
        val map=nativeMap ?: return
        val component=map.locationComponent
        if(fix == null || !hasLocationPermission(context)) {
            if(component.isLocationComponentActivated) component.isLocationComponentEnabled=false
            return
        }
        val style=map.style ?: return
        try {
            if(!component.isLocationComponentActivated) {
                component.activateLocationComponent(LocationComponentActivationOptions.builder(context,style).useDefaultLocationEngine(false).build())
                component.cameraMode=CameraMode.NONE
                component.renderMode=RenderMode.NORMAL
            }
            component.isLocationComponentEnabled=true
            component.forceLocationUpdate(fix)
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
        released=true
        nativeMap=null
        hydrantLayers=null
        lifecycle.removeObserver(observer)
        context.applicationContext.unregisterComponentCallbacks(memory)
        stop()
        onDestroy()
    }
}
