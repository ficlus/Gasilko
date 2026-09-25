package si.gasilko.app.feature.map

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.maplibre.android.geometry.LatLngBounds
import si.gasilko.app.R
import java.text.NumberFormat
import java.util.Locale

@Composable
internal fun OfflineMapControls(style: String, visibleBounds: ()->LatLngBounds?,
    onShow: (OfflineMapRegion)->Unit) {
    val context=LocalContext.current
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val maps=remember { OfflineMaps.get(context) }
    val state by maps.state.collectAsStateWithLifecycle()
    var open by rememberSaveable { mutableStateOf(false) }
    var bounds by rememberSaveable(stateSaver=listSaver<LatLngBounds?,Double>(
        save={ b -> b?.let { listOf(it.latitudeNorth,it.longitudeEast,it.latitudeSouth,it.longitudeWest) }.orEmpty() },
        restore={ if(it.size==4) runCatching { LatLngBounds.from(it[0],it[1],it[2],it[3]) }.getOrNull() else null })) {
        mutableStateOf<LatLngBounds?>(null)
    }
    var name by rememberSaveable { mutableStateOf("") }
    var deleting by remember { mutableStateOf<Long?>(null) }
    DisposableEffect(maps,lifecycle) {
        var attached=false
        fun stop() { if(attached) { attached=false;maps.detach() } }
        val observer=LifecycleEventObserver { _,event ->
            when(event) {
                Lifecycle.Event.ON_START -> if(!attached) { attached=true;maps.attach() }
                Lifecycle.Event.ON_STOP, Lifecycle.Event.ON_DESTROY -> stop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer);stop() }
    }
    TextButton(onClick={ bounds=visibleBounds();open=true }) {
        val active=state.regions.count { it.downloading }
        Text(if(active>0) stringResource(R.string.offline_active_downloads,active) else stringResource(R.string.offline_maps))
    }
    if(!open) return
    val supported=OfflineMapPolicy.supported(style)
    val valid=OfflineMapPolicy.valid(bounds)
    val duplicate=bounds?.let { b -> state.regions.any {
        it.definition.styleURL==style && OfflineMapPolicy.sameArea(it.definition.bounds,b)
    } } == true
    AlertDialog(onDismissRequest={open=false},title={Text(stringResource(R.string.offline_maps))},
        text={Column(Modifier.heightIn(max=480.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.offline_notice))
            if(!supported)Text(stringResource(R.string.offline_unsupported))
            Text(stringResource(R.string.offline_visible_area))
            bounds?.let { Text(areaLabel(it),style=MaterialTheme.typography.bodySmall) }
            if(!valid)Text(stringResource(R.string.offline_invalid_area))
            Text(stringResource(R.string.offline_limits,OfflineMapPolicy.MIN_ZOOM,OfflineMapPolicy.MAX_ZOOM))
            if(duplicate)Text(stringResource(R.string.offline_duplicate))
            OutlinedTextField(name,{name=it.take(80)},label={Text(stringResource(R.string.offline_name))},singleLine=true)
            Button(onClick={bounds?.let { maps.create(name,it,style,context.resources.displayMetrics.density) }},
                enabled=supported && valid && !duplicate && name.isNotBlank() && !state.busy && !state.error) {
                Text(stringResource(R.string.offline_download))
            }
            if(state.busy)LinearProgressIndicator(Modifier.fillMaxWidth())
            if(state.error) {
                Text(stringResource(R.string.offline_error))
                TextButton(onClick=maps::reload) { Text(stringResource(R.string.map_retry)) }
            }
            if(!state.busy && !state.error && state.regions.isEmpty())Text(stringResource(R.string.offline_empty))
            state.regions.forEach { row ->
                HorizontalDivider()
                Text(row.name,style=MaterialTheme.typography.titleSmall)
                row.definition.bounds?.let { Text(areaLabel(it),style=MaterialTheme.typography.bodySmall) }
                val status=row.status
                val complete=status?.isComplete==true
                val overLimit=(status?.completedResourceSize ?: 0)>=OfflineMapPolicy.MAX_BYTES
                Text(stringResource(when {
                    row.deleting -> R.string.offline_deleting
                    row.failed -> R.string.offline_failed
                    complete -> R.string.offline_complete
                    row.downloading -> R.string.offline_downloading
                    status==null -> R.string.offline_checking
                    else -> R.string.offline_paused
                }))
                if(overLimit && !complete)Text(stringResource(R.string.offline_size_limit))
                if(row.downloading && status==null)LinearProgressIndicator(Modifier.fillMaxWidth())
                if(status!=null) {
                    val number=NumberFormat.getNumberInstance().apply { maximumFractionDigits=1 }
                    Text(stringResource(R.string.offline_size,number.format(status.completedResourceSize/1048576.0)))
                    if(!complete) {
                        if(status.isRequiredResourceCountPrecise && status.requiredResourceCount>0) {
                            val progress=(status.completedResourceCount.toDouble()/status.requiredResourceCount).coerceIn(0.0,1.0).toFloat()
                            LinearProgressIndicator(progress={progress},modifier=Modifier.fillMaxWidth())
                            Text(stringResource(R.string.offline_progress,number.format(progress*100)))
                        } else {
                            if(row.downloading)LinearProgressIndicator(Modifier.fillMaxWidth())
                            Text(stringResource(R.string.offline_resources,status.completedResourceCount))
                        }
                    }
                }
                if(!OfflineMapPolicy.supported(row.definition.styleURL.orEmpty()) && !complete)
                    Text(stringResource(R.string.offline_unsupported))
                Row {
                    TextButton(onClick={onShow(row);open=false},enabled=complete && !row.deleting) { Text(stringResource(R.string.offline_show)) }
                    if(row.downloading) TextButton(onClick={maps.pause(row.id)}) { Text(stringResource(R.string.offline_pause)) }
                    else if(!complete)TextButton(onClick={maps.start(row.id)},enabled=!row.deleting && !overLimit &&
                        OfflineMapPolicy.supported(row.definition.styleURL.orEmpty())) { Text(stringResource(R.string.offline_resume)) }
                }
                TextButton(onClick={deleting=row.id},enabled=!row.deleting) { Text(stringResource(R.string.offline_delete)) }
            }
        }},confirmButton={TextButton(onClick={open=false}) { Text(stringResource(R.string.h_back)) }})
    state.regions.find { it.id==deleting }?.let { row ->
        AlertDialog(onDismissRequest={deleting=null},title={Text(stringResource(R.string.offline_delete))},
            text={Text(stringResource(R.string.offline_delete_confirm,row.name))},
            confirmButton={TextButton(onClick={deleting=null;maps.delete(row.id)}) { Text(stringResource(R.string.offline_delete)) }},
            dismissButton={TextButton(onClick={deleting=null}) { Text(stringResource(R.string.h_back)) }})
    }
}

private fun areaLabel(bounds: LatLngBounds) = String.format(Locale.getDefault(),
    "%.4f, %.4f → %.4f, %.4f",bounds.latitudeSouth,bounds.longitudeWest,bounds.latitudeNorth,bounds.longitudeEast)
