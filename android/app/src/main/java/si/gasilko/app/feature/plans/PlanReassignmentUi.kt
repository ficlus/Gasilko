package si.gasilko.app.feature.plans

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.*
import si.gasilko.app.R
import si.gasilko.app.feature.teams.InspectionTeam
import java.time.Instant
import java.text.DateFormat
import java.util.Date

// A UI availability hint only. The server still verifies current authorization and commits atomically.
@Composable internal fun planNetworkAvailable(): Boolean {
    val context=LocalContext.current.applicationContext
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    return produceState(false,context,lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                callbackFlow {
                    val manager=context.getSystemService(ConnectivityManager::class.java)
                    fun publish() {
                        val caps=manager.getNetworkCapabilities(manager.activeNetwork)
                        trySend(caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true)
                    }
                    val callback=object: ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) { publish() }
                        override fun onLost(network: Network) { publish() }
                        override fun onCapabilitiesChanged(network: Network,caps: NetworkCapabilities) { publish() }
                    }
                    manager.registerDefaultNetworkCallback(callback);publish()
                    awaitClose { manager.unregisterNetworkCallback(callback) }
                }.collect { value=it }
            } finally { value=false }
        }
    }.value
}

@Composable internal fun ReassignmentDialog(item: PlanItem,destinations: List<InspectionTeam>,busy: Boolean,
    online: Boolean,confirm: (PlanReassign)->Unit,close: ()->Unit) {
    var destination by remember(item.id,item.executionVersion) { mutableStateOf<String?>(null) }
    var reason by remember(item.id,item.executionVersion) { mutableStateOf("") }
    AlertDialog(onDismissRequest={if(!busy)close()},title={Text(stringResource(R.string.reassign_title))},
        text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.reassign_destination))
            destinations.forEach { team ->
                FilterChip(selected=destination==team.id,onClick={destination=team.id},enabled=!busy,label={Text(team.name)})
            }
            OutlinedTextField(reason,{reason=it.take(2000)},enabled=!busy,label={Text(stringResource(R.string.reassign_reason))})
            if(!online)Text(stringResource(R.string.reassign_offline))
        }},
        confirmButton={TextButton(onClick={
            confirm(PlanReassign(item.context(),item.teamId!!,destination!!,reason))
        },enabled=!busy && online && reason.isNotBlank() && destinations.any { it.id==destination }) {
            Text(stringResource(R.string.reassign_confirm))
        }},dismissButton={TextButton(onClick=close,enabled=!busy) { Text(stringResource(R.string.h_back)) }})
}

@Composable internal fun ReassignmentHistory(item: PlanItem,events: List<PlanReassignment>,teams: List<InspectionTeam>,close: ()->Unit) {
    fun name(id: String?)=teams.find { it.id==id }?.name ?: id.orEmpty()
    AlertDialog(onDismissRequest=close,title={Text(stringResource(R.string.reassign_history))},text={
        Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.reassign_current_team,name(item.teamId)))
            if(events.isEmpty())Text(stringResource(R.string.reassign_no_history))
            events.sortedWith(compareByDescending<PlanReassignment> { it.version }.thenByDescending { it.id }).forEach { event ->
                Text(name(event.fromTeam)+" → "+name(event.toTeam),style=MaterialTheme.typography.titleSmall)
                Text(event.reason)
                Text(stringResource(R.string.reassign_actor,event.actor))
                val time=runCatching { DateFormat.getDateTimeInstance().format(Date.from(Instant.parse(event.createdAt))) }.getOrDefault(event.createdAt)
                Text(time)
            }
        }
    },confirmButton={TextButton(onClick=close) { Text(stringResource(R.string.h_back)) }})
}
