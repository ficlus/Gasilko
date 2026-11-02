package si.gasilko.app.feature.incidents

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import si.gasilko.app.R
import si.gasilko.app.core.ui.*

/** Explicit capability read only; never requests OS permission or starts a location flow. */
@Composable internal fun VehicleLocationCapabilityCard(model: IncidentViewModel,incident: String,fingerprint: String) {
    key(model,incident,fingerprint) {
        var requested by remember {mutableStateOf(false)}
        var result by remember {mutableStateOf<VehicleLocationCheck?>(null)}
        LaunchedEffect(requested) {
            if(requested) {
                result=try {model.vehicleLocationCapability(incident)}
                    catch(e: CancellationException){throw e}
                    catch(_: Exception){VehicleLocationCheck.UNAVAILABLE}
            }
        }
        Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
            StatusBadge(stringResource(R.string.c2_off),FieldTone.NEUTRAL)
            Text(stringResource(R.string.c2_blocked),style=MaterialTheme.typography.bodySmall)
            Text(stringResource(R.string.c2_no_capture),style=MaterialTheme.typography.bodySmall)
            if(result!=null)Text(stringResource(if(result==VehicleLocationCheck.DISABLED)R.string.c2_server_off else R.string.c2_unverified))
            if(requested && result==null)LinearProgressIndicator()
            OutlinedButton(enabled=!requested,onClick={requested=true}) {Text(stringResource(R.string.c2_check))}
        }
    }
}
