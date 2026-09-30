package si.gasilko.app.feature.inspections.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.InspectionHistoryState
import si.gasilko.app.feature.hydrants.presentation.errorLabel
import si.gasilko.app.feature.inspections.domain.*
import java.text.DateFormat
import java.util.Date

@Composable
fun InspectionHistoryItem(entry: InspectionHistoryEntry, photoCount: Int = 0, viewPhotos: (String)->Unit = {}) {
    val inspection=entry.inspection
    Text(DateFormat.getDateTimeInstance(DateFormat.SHORT,DateFormat.SHORT).format(Date(inspection.completedAt)))
    Text(stringResource(inspectionModeLabel(inspection.mode)),style=MaterialTheme.typography.titleMedium)
    StatusBadge(stringResource(inspectionResultLabel(inspection.result)),inspectionTone(inspection.result))
    Text(stringResource(R.string.inspection_inspector_unknown))
    Text(stringResource(when(entry.state) {
        InspectionSyncState.SYNCED -> R.string.inspection_synced
        InspectionSyncState.PENDING -> R.string.inspection_pending
        InspectionSyncState.ATTENTION -> R.string.inspection_attention
    }))
    if(entry.durableIssue)Text(stringResource(R.string.inspection_immutable_issue),color=MaterialTheme.colorScheme.error)
    else if(entry.state==InspectionSyncState.ATTENTION)Text(stringResource(R.string.inspection_retry_queue))
    InspectionMeasurementValues(inspection.pressureBar,inspection.flowLMin)
    inspection.notes?.takeIf { it.isNotBlank() }?.let { Text(it) }
    if(inspection.mode!=InspectionMode.QUICK) {
        Text(stringResource(R.string.photo_count,photoCount))
        TextButton(onClick={viewPhotos(inspection.id)}) { Text(stringResource(R.string.inspection_view_photos)) }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
fun InspectionHistoryScreen(hydrantLabel: String, history: InspectionHistoryState, refreshing: Boolean,
    refreshError: RegistryError?, phase: SyncPhase?, refresh: ()->Unit, sync: ()->Unit, back: ()->Unit,
    photoCounts: Map<String,Int> = emptyMap(), viewPhotos: (String)->Unit = {}) {
    BackHandler(onBack=back)
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            ScreenHeading(stringResource(R.string.inspection_history_title),hydrantLabel)
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
                TextButton(onClick=refresh,enabled=!refreshing) { Text(stringResource(R.string.h_refresh)) }
                TextButton(onClick=sync,enabled=phase!=SyncPhase.SYNCING) { Text(stringResource(R.string.h_sync_now)) }
            }
            if(refreshing || !history.loaded && history.error==null)LinearProgressIndicator(Modifier.fillMaxWidth())
            if(phase==SyncPhase.SYNCING)Text(stringResource(R.string.h_sync_running))
            refreshError?.let {
                Text(stringResource(R.string.inspection_refresh_failed),color=MaterialTheme.colorScheme.error)
                Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error)
            }
            history.error?.let { Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error) }
            if(phase==SyncPhase.CONFLICT)Text(stringResource(R.string.inspection_queue_conflict))
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                if(history.loaded && history.entries.isEmpty())item { Text(stringResource(R.string.inspection_history_empty)) }
                items(history.entries,key={it.inspection.id}) { entry ->
                    OutlinedCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(6.dp)) { InspectionHistoryItem(entry,photoCounts[entry.inspection.id] ?: 0,viewPhotos) }
                    }
                }
            }
        }
    }
}
