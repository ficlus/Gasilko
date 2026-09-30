package si.gasilko.app.feature.map

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import si.gasilko.app.core.ui.*
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.Hydrant
import si.gasilko.app.feature.hydrants.presentation.statusLabel
import si.gasilko.app.feature.map.domain.*
import java.text.NumberFormat

private tailrec fun Context.activity(): Activity? = when(this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** Permission prompts happen only in user actions. Precise fixes stay in memory. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun LocationControls(hydrants: List<Hydrant>, onLocation: (Location?) -> Unit,
    onCenter: () -> Unit, onSelect: (Hydrant) -> Unit, onUnavailable: () -> Unit,
    dataLoading: Boolean = false,
    onUseLocation: ((Location)->Unit)? = null, useLocationLabel: Int = R.string.h_use_location,
    onUseRequested: ()->Unit = {},
    locationOnly: Boolean = false, actionEnabled: Boolean = true, requestKey: String = "",
    additionalActions: @Composable () -> Unit = {}) {
    val context=LocalContext.current
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var useRequested by rememberSaveable(requestKey) { mutableStateOf(false) }
    var enabled by remember { mutableStateOf(!locationOnly && hasLocationPermission(context)) }
    var denied by rememberSaveable { mutableStateOf(false) }
    var permanent by rememberSaveable { mutableStateOf(false) }
    var showNearby by rememberSaveable { mutableStateOf(false) }
    var location by remember { mutableStateOf(LocationState()) }
    var refresh by remember { mutableIntStateOf(0) }
    val updateLocation by rememberUpdatedState(onLocation)
    val useLocation by rememberUpdatedState(onUseLocation)
    val launcher=rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        enabled=hasLocationPermission(context)
        denied=!enabled
        if(!enabled) { useRequested=false;onUnavailable() }
        permanent=!enabled && result.isNotEmpty() && context.activity()?.let { activity ->
            !activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION) &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)
        } == true
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        enabled=hasLocationPermission(context) && (!locationOnly || useRequested)
        if(enabled) { denied=false; permanent=false }
    }
    LaunchedEffect(enabled,lifecycle,refresh,locationOnly && useRequested,locationOnly && actionEnabled) {
        if(enabled && (!locationOnly || (useRequested && actionEnabled))) lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                foregroundLocations(context.applicationContext).collect { value ->
                    location=value
                    updateLocation(value.fix)
                    if(value.notice==LocationNotice.DENIED) { denied=true;enabled=false;onUnavailable() }
                }
            } catch(e: CancellationException) { throw e }
            catch(_: Exception) { location=LocationState(notice=LocationNotice.UNAVAILABLE); updateLocation(null) }
            finally { location=location.copy(fix=null); updateLocation(null) }
        } else {
            location=if(locationOnly)LocationState(notice=location.notice?.takeUnless { it==LocationNotice.SEARCHING }) else LocationState()
            updateLocation(null)
        }
    }
    DisposableEffect(Unit) { onDispose { updateLocation(null) } }
    fun request() {
        if(hasLocationPermission(context)) {
            denied=false;permanent=false;location=LocationState(notice=LocationNotice.SEARCHING)
            enabled=true;refresh++;return
        }
        if(!permanent) {
            denied=false;location=LocationState(notice=LocationNotice.SEARCHING)
            launcher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        } else { useRequested=false;onUnavailable() }
    }
    val fix=location.fix?.takeIf(::freshLocation)
    LaunchedEffect(fix,useRequested,actionEnabled,requestKey) {
        if(useRequested && actionEnabled && fix!=null && lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
            hasLocationPermission(context) && freshLocation(fix)) {
            useRequested=false
            useLocation?.invoke(Location(fix))
        }
    }
    val point=fix?.let { GeoPoint(it.latitude,it.longitude) }
    // Include both input identities so an in-flight calculation can never show an old scope/fix.
    val calculated by produceState(Triple<List<Hydrant>?, GeoPoint?, List<NearbyHydrant>>(null,null,emptyList()), hydrants, point, showNearby) {
        value=Triple(hydrants,point,if(showNearby && point!=null) withContext(Dispatchers.Default) { NearbyHydrants.ordered(point,hydrants) } else emptyList())
    }
    val nearby=calculated.third.takeIf { !dataLoading && calculated.first == hydrants && calculated.second == point }.orEmpty()
    LaunchedEffect(denied,permanent,location.notice) {
        if(denied || permanent || location.notice in listOf(LocationNotice.DENIED,LocationNotice.DISABLED,
                LocationNotice.UNAVAILABLE,LocationNotice.STALE)) { useRequested=false;onUnavailable() }
    }
    Column(Modifier.padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
            if(!locationOnly) {
                CompactAction(onClick={onCenter();request()}) { ActionLabel(stringResource(R.string.map_my_location),R.drawable.ic_field_my_location) }
                CompactAction(onClick={showNearby=true;request()}) { Text(stringResource(R.string.map_nearby)) }
            }
            if(onUseLocation!=null) CompactAction(onClick={
                onUseRequested()
                if(fix!=null && freshLocation(fix) && hasLocationPermission(context))useLocation?.invoke(Location(fix))
                else { useRequested=true;request() }
            },enabled=actionEnabled && !useRequested) { Text(stringResource(useLocationLabel)) }
            additionalActions()
        }
        val message=when {
            permanent -> R.string.map_location_permanent
            denied || location.notice==LocationNotice.DENIED -> R.string.map_location_denied
            location.notice==LocationNotice.SEARCHING -> R.string.map_location_searching
            location.notice==LocationNotice.DISABLED -> R.string.map_location_disabled
            location.notice==LocationNotice.STALE -> R.string.map_location_stale
            location.notice==LocationNotice.UNAVAILABLE -> R.string.map_location_unavailable
            else -> null
        }
        message?.let { FieldBanner(stringResource(it),if(it==R.string.map_location_searching)FieldTone.INFO else FieldTone.WARNING) }
        if(fix!=null && !locationOnly) {
            Text(stringResource(if(context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED)
                R.string.map_location_accuracy else R.string.map_location_approximate, NumberFormat.getIntegerInstance().format(fix.accuracy)),style=MaterialTheme.typography.bodySmall)
        }
        if(permanent || location.notice==LocationNotice.DISABLED) TextButton(onClick={
            val intent=if(permanent) Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:${context.packageName}"))
                else Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            try { context.startActivity(intent) } catch(_: android.content.ActivityNotFoundException) { denied=true }
        }) { ActionLabel(stringResource(R.string.map_location_settings),R.drawable.ic_field_my_location) }
        if(showNearby) AlertDialog(onDismissRequest={showNearby=false}, title={Text(stringResource(R.string.map_nearby))},
            text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                FieldBanner(stringResource(R.string.map_nearby_notice))
                if(fix==null)Text(stringResource(message ?: R.string.map_location_searching))
                else if(dataLoading || calculated.first != hydrants || calculated.second != point)LinearProgressIndicator(Modifier.fillMaxWidth())
                else if(nearby.isEmpty())Text(stringResource(R.string.map_nearby_empty))
                LazyColumn(Modifier.heightIn(max=300.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    items(nearby,key={it.hydrant.id}) { item ->
                        SecondaryAction(onClick={
                            if(fix!=null && freshLocation(fix)) { onSelect(item.hydrant);showNearby=false }
                            else { location=LocationState(notice=LocationNotice.STALE);updateLocation(null) }
                        }) {
                            Column(Modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(6.dp)) {
                                Text(item.hydrant.code ?: (stringResource(R.string.h_pending_code)+" · "+item.hydrant.id),style=MaterialTheme.typography.titleMedium)
                                StatusBadge(stringResource(statusLabel(item.hydrant.status)))
                                val kilometers=item.meters>=1000
                                val number=NumberFormat.getNumberInstance().apply { maximumFractionDigits=if(kilometers)2 else 0 }
                                Text(stringResource(if(kilometers)R.string.map_distance_km else R.string.map_distance_m,
                                    number.format(if(kilometers)item.meters/1000 else item.meters)))
                            }
                        }
                    }
                }
            }}, confirmButton={TextButton(onClick={showNearby=false}) { Text(stringResource(R.string.h_back)) }})
    }
}
