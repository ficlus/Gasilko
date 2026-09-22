package si.gasilko.app.feature.map

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapView
import si.gasilko.app.BuildConfig
import si.gasilko.app.R
import java.net.URI

/** Base-map UI only. Future hydrant layers must consume the existing Room repository. */
@Composable
fun MapScreen(onBack: () -> Unit, styleUrl: String = BuildConfig.MAP_STYLE_URL) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var attempt by remember { mutableIntStateOf(0) }
    BackHandler(onBack=onBack)
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Row(Modifier.padding(horizontal=16.dp), horizontalArrangement=Arrangement.spacedBy(16.dp)) {
                TextButton(onClick=onBack) { Text(stringResource(R.string.h_back)) }
                Text(stringResource(R.string.map_title), Modifier.padding(top=12.dp), style=MaterialTheme.typography.titleLarge)
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
                            addOnDidFailLoadingMapListener { _ ->
                                if(!released) { failed=true; loading=false }
                            }
                            if(!released) getMapAsync { map ->
                                if(!released) {
                                    if(saved.bundle == null) map.cameraPosition = CameraPosition.Builder().target(LatLng(46.15, 14.95)).zoom(6.0).build()
                                    // Keep MapLibre's attribution controls and source attribution visible.
                                    try {
                                        map.setStyle(styleUrl) { if(!released) { loading=false; failed=false } }
                                    } catch(_: RuntimeException) { failed=true; loading=false }
                                }
                            }
                        }
                    }, onReset=null, onRelease={
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
        lifecycle.removeObserver(observer)
        context.applicationContext.unregisterComponentCallbacks(memory)
        stop()
        onDestroy()
    }
}
