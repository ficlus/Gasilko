package si.gasilko.app.feature.incidents

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import si.gasilko.app.R
import si.gasilko.app.core.ui.*

@Composable internal fun vehicleStatus(code: String)=stringResource(when(code) {
    "SHARING"->R.string.gps_sharing;"ACQUIRING_FIX"->R.string.gps_fix_wait;"POOR_ACCURACY"->R.string.gps_accuracy
    "OFFLINE"->R.string.gps_offline;"STOP_PENDING_SERVER"->R.string.gps_stop_pending;"STOPPED"->R.string.gps_stopped
    "PERMISSION_DENIED","PERMISSION_REQUIRED"->R.string.gps_permission
    "POLICY_UNAPPROVED","CAPABILITY_DISABLED"->R.string.gps_policy;"RETENTION_NOT_READY"->R.string.gps_retention
    "DEVICE_APPROVAL_REQUIRED"->R.string.gps_device_approval
    "CREDENTIAL_REVOKED"->R.string.gps_denied
    "SESSION_EXPIRED","CHALLENGE_EXPIRED"->R.string.gps_expired;"NOT_AUTHORIZED","SCOPE_CHANGED"->R.string.gps_denied
    "OUTCOME_UNKNOWN","BACKEND_UNAVAILABLE"->R.string.gps_unknown;else->R.string.gps_unavailable
})
@Composable internal fun rememberVehiclePositions(model: IncidentViewModel,incident: String,fingerprint: String,locked: Boolean): List<VehicleFix> {
    val owner=LocalLifecycleOwner.current
    @Suppress("UNUSED_VARIABLE") val localStatus by VehicleLocationRuntime.state.collectAsStateWithLifecycle()
    val repo=model.vehicleLocations
    val scopeIdentity=repo.account+"/"+repo.organization+"/"+incident+"/"+fingerprint
    val identity=remember(scopeIdentity,locked){scopeIdentity+"/"+newVehicleOperation()}
    val currentIdentity=rememberUpdatedState(identity)
    val state=produceState<Pair<String,List<VehicleFix>>>(identity to emptyList(),identity,locked,owner) {
        value=identity to emptyList()
        if(locked)return@produceState
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                repo.context(incident,fingerprint) // One OFF-compatible probe; no polling when rejected.
                coroutineScope {
                    launch {while(isActive){delay(1000);value=identity to value.second.filter {it.usable()}}}
                    while(isActive) {value=identity to repo.positions(incident,fingerprint);delay(10000)}
                }
            } catch(e: CancellationException){throw e}
            catch(_: Exception){value=identity to emptyList()}
            finally {if(currentIdentity.value==identity)value=identity to emptyList()}
        }
    }
    return if(state.value.first==identity && !locked)state.value.second.filter {it.usable() && !VehicleLocationRuntime.stopped(it.session)} else emptyList()
}
@Composable @OptIn(ExperimentalLayoutApi::class)
internal fun VehicleLocationPanel(model: IncidentViewModel,incident: String,fingerprint: String) {
    val repo=model.vehicleLocations
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val scope=rememberCoroutineScope()
    val identity=repo.account+"/"+repo.organization+"/"+incident+"/"+fingerprint
    key(identity) {
        var data by remember {mutableStateOf<JsonObject?>(null)}
        var error by remember {mutableStateOf("")}
        var busy by remember {mutableStateOf(false)}
        var proof by remember {mutableStateOf(false)}
        var keyHash by remember {mutableStateOf("")}
        var accepted by remember(data?.obj("policy")?.text("id")) {mutableStateOf(false)}
        val runtime by VehicleLocationRuntime.state.collectAsStateWithLifecycle()
        val collecting=VehicleLocationRuntime.active!=null || VehicleLocationRuntime.pendingFor(repo.account)!=null
        val owned=VehicleLocationRuntime.active?.let {it.repository.account==repo.account && it.repository.organization==repo.organization && it.incident==incident}==true
        fun action(block: suspend ()->Unit) {
            if(busy)return
            busy=true
            scope.launch {
                try {block();error=""}
                catch(e: CancellationException){throw e}
                catch(e: Exception){error=if(e is VehicleLocationFailure)e.code else "OUTCOME_UNKNOWN"}
                finally {busy=false}
            }
        }
        DisposableEffect(identity) {onDispose {
            if(VehicleLocationRuntime.active?.repository!==repo)repo.revokeLocal()
        }}
        OperationalCard {
            Text(stringResource(R.string.gps_title),style=MaterialTheme.typography.titleMedium)
            if(owned || (runtime=="STOP_PENDING_SERVER" && VehicleLocationRuntime.pendingFor(repo.account)!=null))Text(vehicleStatus(runtime))
            if(!owned && data==null && error.isEmpty())Text(stringResource(R.string.gps_unavailable))
            if(error.isNotEmpty())FieldBanner(vehicleStatus(error),FieldTone.WARNING)
            if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
            OutlinedButton(enabled=!busy && !collecting,onClick={action {data=repo.context(incident,fingerprint);proof=false;accepted=false}}) {
                Text(stringResource(R.string.gps_review))
            }
            data?.let {current->
                val vehicles=current.rows("vehicles")
                val vehicle=vehicles.singleOrNull()
                val policy=current.obj("policy")
                if(vehicle==null)Text(stringResource(R.string.gps_driver_only))
                else {
                    Text(vehicle.text("label"),style=MaterialTheme.typography.titleMedium)
                    val language=LocalContext.current.resources.configuration.locales[0].language
                    Text(policy.obj("notice").text(language).ifEmpty {policy.obj("notice").text("default")})
                    Text(stringResource(R.string.gps_policy_version,policy.text("version")))
                    OutlinedButton(enabled=!busy && !owned,onClick={action {keyHash=repo.enroll(incident,vehicle,policy).text("publicKeySha256");proof=true}}) {
                        Text(stringResource(R.string.gps_enroll))
                    }
                    if(keyHash.isNotEmpty())Text(stringResource(R.string.gps_key_fingerprint,keyHash))
                    if(proof)Text(stringResource(R.string.gps_proof_inactive))
                    Row {Checkbox(checked=accepted,onCheckedChange={accepted=it},enabled=proof && !busy && !collecting)
                        Text(stringResource(R.string.gps_agree))}
                    Button(enabled=proof && accepted && !busy && !collecting,onClick={action {
                        check(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
                        repo.consent(incident,policy)
                        val session=repo.start(incident)
                        val (keys,credential)=repo.keys()
                        val ticket=VehicleLocationTicket(repo,incident,vehicle.text("label"),session,keys,credential,repo.armedStop())
                        // A late callback may not launch location from a background Activity.
                        VehicleLocationRuntime.begin(ticket)
                        if(!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                            VehicleLocationRuntime.stopNow("ERROR");return@action
                        }
                        VehicleLocationRuntime.state.value="PERMISSION_REQUIRED"
                        VehicleLocationRuntime.permissionRequest.value=ticket
                    }}) {Text(stringResource(R.string.gps_start))}
                }
                OutlinedButton(enabled=!busy && !owned,onClick={action {repo.revokeDevice();data=null;proof=false;accepted=false}}) {
                    Text(stringResource(R.string.gps_revoke))
                }
            }
            FlowRow {
                TextButton(enabled=owned,onClick={VehicleLocationRuntime.stopNow("USER_STOP")}){Text(stringResource(R.string.gps_stop))}
                TextButton(enabled=owned,onClick={VehicleLocationRuntime.stopNow("LEFT_VEHICLE")}){Text(stringResource(R.string.gps_leave))}
                TextButton(enabled=!owned && !busy,onClick={action {repo.flushStop()}}){Text(stringResource(R.string.gps_retry_stop))}
            }
            Text(stringResource(R.string.gps_offline_stop),style=MaterialTheme.typography.bodySmall)
        }
    }
}

/** Root-owned launcher survives ordinary auth-refresh/loading recompositions.
 * Origin is NOT saved across process death; a result with no origin fails closed. */
@Composable internal fun VehicleLocationPermissionHost() {
    val context=LocalContext.current
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val scope=rememberCoroutineScope()
    val request by VehicleLocationRuntime.permissionRequest.collectAsStateWithLifecycle()
    var origin by remember {mutableStateOf<VehicleLocationTicket?>(null)}
    var launched by remember {mutableStateOf<String?>(null)}
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val ticket=origin;origin=null
        if(ticket!=null && VehicleLocationRuntime.active===ticket)scope.launch {
            val resumed=withTimeoutOrNull((ticket.deadline-android.os.SystemClock.elapsedRealtime()).coerceIn(1,90000)) {
                lifecycle.currentStateFlow.first {it.isAtLeast(Lifecycle.State.RESUMED)};true
            }==true
            val fine=ContextCompat.checkSelfPermission(context,Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED
            val notifications=Build.VERSION.SDK_INT<33 || ContextCompat.checkSelfPermission(context,Manifest.permission.POST_NOTIFICATIONS)==PackageManager.PERMISSION_GRANTED
            if(resumed && fine && notifications && ticket.current() && VehicleLocationRuntime.permissionRequest.value===ticket) {
                try {
                    context.startForegroundService(Intent(context,VehicleLocationService::class.java).putExtra("nonce",ticket.nonce))
                    VehicleLocationRuntime.permissionRequest.value=null
                } catch(_: Exception){VehicleLocationRuntime.stopNow("ERROR")}
            } else if(VehicleLocationRuntime.active===ticket)VehicleLocationRuntime.stopNow("PERMISSION_REVOKED")
        }
    }
    DisposableEffect(request?.nonce) {
        val owned=request
        onDispose {if(owned!=null && VehicleLocationRuntime.active===owned && VehicleLocationRuntime.permissionRequest.value===owned)
            VehicleLocationRuntime.stopNow("ERROR")}
    }
    LaunchedEffect(request?.nonce,origin==null) {
        val ticket=request ?: return@LaunchedEffect
        if(origin!=null || launched==ticket.nonce)return@LaunchedEffect
        val resumed=withTimeoutOrNull((ticket.deadline-android.os.SystemClock.elapsedRealtime()).coerceIn(1,90000)) {
            lifecycle.currentStateFlow.first {it.isAtLeast(Lifecycle.State.RESUMED)};true
        }==true
        if(resumed && ticket.current()) {
            origin=ticket;launched=ticket.nonce
            permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION,Manifest.permission.ACCESS_FINE_LOCATION)+
                if(Build.VERSION.SDK_INT>=33)arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray())
        } else if(VehicleLocationRuntime.active===ticket)VehicleLocationRuntime.stopNow("ERROR")
    }
}
