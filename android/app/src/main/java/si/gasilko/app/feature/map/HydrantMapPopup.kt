package si.gasilko.app.feature.map

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.Hydrant
import si.gasilko.app.feature.hydrants.presentation.statusLabel

/** Reusable presentation only; selection, authorized data and navigation belong to the caller. */
@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun HydrantMapPopup(id: String,hydrant: Hydrant?,fallbackCode: String?,
    open: (()->Unit)?,close: ()->Unit,photo: @Composable (Hydrant)->Unit) {
    OperationalCard {
        Text(hydrant?.code ?: fallbackCode ?: stringResource(R.string.h_pending_code),style=MaterialTheme.typography.titleLarge)
        if(hydrant?.code==null && fallbackCode==null)Text(id,style=MaterialTheme.typography.labelSmall)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            CompactAction(onClick={open?.invoke()},enabled=open!=null) { Text(stringResource(R.string.map_open_hydrant)) }
            TextButton(onClick=close) { Text(stringResource(R.string.map_clear_selection)) }
        }
        if(hydrant!=null) {
            StatusBadge(stringResource(statusLabel(hydrant.status)))
            if(!hydrant.active)StatusBadge(stringResource(R.string.h_inactive))
            photo(hydrant)
            hydrant.address?.takeIf { it.isNotBlank() }?.let { Text(it) }
            hydrant.description?.takeIf { it.isNotBlank() }?.let { Text(it) }
        } else Text(stringResource(R.string.h_unavailable))
    }
}
