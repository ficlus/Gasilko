package si.gasilko.app.feature.hydrants.presentation

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.*

/** Navigation only: no additional collectors, counts, queries or domain state. */
@Composable internal fun HomeDashboard(modifier: Modifier,enabled: Boolean,writable: Boolean,manages: Boolean,
    hydrants: ()->Unit,map: ()->Unit,plans: ()->Unit,teams: ()->Unit,overview: @Composable ()->Unit) {
    LazyColumn(modifier,verticalArrangement=Arrangement.spacedBy(12.dp),contentPadding=PaddingValues(bottom=16.dp)) {
        item { overview() }
        item { HomeEntry(R.string.h_title,R.string.shell_hydrants_hint,enabled,hydrants) }
        item { HomeEntry(R.string.map_title,R.string.shell_map_hint,enabled && writable,map) }
        if(writable)item { HomeEntry(R.string.plans_title,R.string.shell_plans_hint,enabled,plans) }
        if(manages && writable)item { HomeEntry(R.string.teams_title,R.string.shell_teams_hint,enabled,teams) }
        item { HomeEntry(R.string.inspection_history_title,R.string.shell_history_hint,enabled,hydrants) }
    }
}

@Composable private fun HomeEntry(title: Int,description: Int,enabled: Boolean,open: ()->Unit) {
    OutlinedCard(onClick=open,enabled=enabled,modifier=Modifier.fillMaxWidth().heightIn(min=88.dp),
        colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title),style=MaterialTheme.typography.titleLarge)
            Text(stringResource(description),style=MaterialTheme.typography.bodyMedium,
                color=if(enabled)MaterialTheme.colorScheme.onSurfaceVariant else LocalContentColor.current)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun RegistrySyncOverview(state: RegistryState,sync: RegistrySyncState?,busy: Boolean,
    syncNow: ()->Unit,review: ()->Unit) {
        if(state.organization != null) {
            StatusBadge(stringResource(when(sync?.phase) {
                SyncPhase.SYNCHRONIZED -> R.string.h_sync_done
                SyncPhase.SYNCING -> R.string.h_sync_running
                SyncPhase.RETRY -> R.string.h_sync_retry
                SyncPhase.CONFLICT -> R.string.h_sync_conflict
                else -> R.string.h_sync_pending
            }),when(sync?.phase) {
                SyncPhase.SYNCHRONIZED->FieldTone.SUCCESS
                SyncPhase.CONFLICT,SyncPhase.RETRY->FieldTone.WARNING
                SyncPhase.SYNCING->FieldTone.INFO
                else->FieldTone.NEUTRAL
            })
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                TextButton(onClick=syncNow, enabled=!busy && state.writable && sync?.phase != SyncPhase.SYNCING) { Text(stringResource(R.string.h_sync_now)) }
                if(!sync?.conflicts.isNullOrEmpty()) TextButton(onClick=review, enabled=!busy && state.form==null) { Text(stringResource(R.string.h_sync_review)) }
            }
            if(state.selected?.id in sync?.pendingIds.orEmpty()) Text(stringResource(R.string.h_unsynced))
        }
}
