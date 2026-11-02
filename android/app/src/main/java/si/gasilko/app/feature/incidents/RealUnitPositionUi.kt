package si.gasilko.app.feature.incidents

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.core.ui.*

@Composable internal fun RealUnitPositionBadge(view: RealUnitPositionView) {
    StatusBadge("□ "+stringResource(if(view.availability==RealUnitAvailability.LOCKED)R.string.c3_locked else R.string.c3_unavailable),FieldTone.NEUTRAL)
}
/** Conditional legend only; no green/amber unit state is claimed without a real source. */
@Composable internal fun RealUnitLocationNotice(compact: Boolean=true) {
    var expanded by remember {mutableStateOf(!compact)}
    StatusBadge("□ "+stringResource(R.string.c3_title)+" · "+stringResource(R.string.c3_unavailable),FieldTone.NEUTRAL)
    TextButton(onClick={expanded=!expanded}){Text(stringResource(R.string.c3_legend))}
    if(expanded)Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.c3_source))
        Text(stringResource(R.string.c3_no_time));Text(stringResource(R.string.c3_no_accuracy))
        Text(stringResource(R.string.c3_distinction));Text(stringResource(R.string.c3_sim))
        StatusBadge("■ "+stringResource(R.string.c3_current,(REAL_UNIT_STALE_SECONDS/60).toString()),FieldTone.SUCCESS)
        StatusBadge("▧ "+stringResource(R.string.c3_last_known,(REAL_UNIT_STALE_SECONDS/60).toString(),(REAL_UNIT_EXPIRE_SECONDS/60).toString()),FieldTone.WARNING)
        StatusBadge("□ "+stringResource(R.string.c3_expired,(REAL_UNIT_EXPIRE_SECONDS/60).toString()),FieldTone.NEUTRAL)
        Text(stringResource(R.string.c3_retention),style=MaterialTheme.typography.bodySmall)
    }
}
