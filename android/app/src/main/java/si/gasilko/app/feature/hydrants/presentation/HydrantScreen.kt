package si.gasilko.app.feature.hydrants.presentation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.feature.hydrants.domain.*

fun activeLabel(active: ActiveFilter): Int = when(active) { ActiveFilter.ACTIVE->R.string.h_active_only; ActiveFilter.INACTIVE->R.string.h_inactive_only; ActiveFilter.ALL->R.string.h_all }
fun statusLabel(status: HydrantStatus): Int = when(status) {
    HydrantStatus.WORKING -> R.string.h_working
    HydrantStatus.NOT_WORKING -> R.string.h_not_working
    HydrantStatus.NEEDS_INSPECTION -> R.string.h_needs_inspection
    HydrantStatus.UNKNOWN -> R.string.h_unknown
}
fun errorLabel(error: RegistryError): Int = when(error) {
    RegistryError.NETWORK -> R.string.h_network
    RegistryError.EXPIRED -> R.string.auth_offline_expired
    RegistryError.FORBIDDEN -> R.string.h_forbidden
    RegistryError.VALIDATION -> R.string.h_validation
    RegistryError.CONFLICT -> R.string.h_conflict
    RegistryError.UNAVAILABLE -> R.string.h_unavailable
    RegistryError.LOCATION -> R.string.h_location_required
    RegistryError.COORDINATES -> R.string.h_coordinates_invalid
    RegistryError.INTERVAL -> R.string.h_interval_invalid
    RegistryError.TYPE -> R.string.h_type_required
    RegistryError.SERVER -> R.string.h_server
}
@Composable private fun typeName(type: HydrantType?): String {
    if(type==null)return stringResource(R.string.h_type_unavailable)
    val resource=if(type.organization==null)when(type.code){
        "ABOVE_GROUND"->R.string.h_above_ground;"UNDERGROUND"->R.string.h_underground
        "WALL"->R.string.h_wall;"OTHER"->R.string.h_other;else->null
    }else null
    return resource?.let { stringResource(it) } ?: type.name
}
@Composable
private fun Choice(label: String, selected: String, choices: List<Pair<String,String>>, enabled: Boolean, tag: String, choose: (String)->Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick={expanded=true},enabled=enabled,modifier=Modifier.fillMaxWidth().testTag(tag)) { Text("$label: $selected") }
        DropdownMenu(expanded=expanded && enabled,onDismissRequest={expanded=false}) {
            choices.forEach { (id,name)->DropdownMenuItem(text={Text(name)},onClick={expanded=false;choose(id)},modifier=Modifier.testTag("$tag-$id")) }
        }
    }
}
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun HydrantScreen(model: HydrantViewModel, requestAccess: ()->Unit = {}, signOut: ()->Unit = {}) {
    val state by model.state.collectAsStateWithLifecycle()
    val observedSync by model.sync.collectAsStateWithLifecycle()
    val sync = observedSync.takeIf { it.organization == state.organization?.id }
    var showConflicts by remember(state.organization?.id) { mutableStateOf(false) }
    var conflictSequence by remember(state.organization?.id) { mutableStateOf<Long?>(null) }
    LaunchedEffect(model) { model.refresh() }
    var showMap by remember(state.organization?.id) { mutableStateOf(false) }
    if(showMap) {
        si.gasilko.app.feature.map.MapScreen(onBack={showMap=false})
        return
    }
    val busy=state.loading || state.mutating
    var showFilters by remember { mutableStateOf(false) }
    val keyboard=LocalSoftwareKeyboardController.current
    BackHandler(state.selected!=null || state.form!=null) { if(state.form!=null)model.cancelForm() else model.back() }
    Scaffold { padding -> Column(Modifier.fillMaxSize().padding(padding).imePadding().padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.h_title),style=MaterialTheme.typography.headlineMedium)
        Choice(stringResource(R.string.h_organization),state.organization?.name ?: stringResource(R.string.h_select_organization),
            state.organizations.map { it.id to it.name },!busy && state.form==null && state.organizations.size>1,"organization",model::switchOrganization)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(onClick={showMap=true},enabled=!busy && state.form==null && state.organization!=null){Text(stringResource(R.string.map_title))}
            TextButton(onClick=model::refresh,enabled=!busy,modifier=Modifier.testTag("refresh")){Text(stringResource(R.string.h_refresh))}
            TextButton(onClick=requestAccess,enabled=!busy && state.form==null){Text(stringResource(R.string.access_request_access))}
            TextButton(onClick=signOut,enabled=!state.mutating){Text(stringResource(R.string.auth_sign_out))}
        }
        if(busy){LinearProgressIndicator(Modifier.fillMaxWidth());Text(stringResource(if(state.mutating)R.string.h_saving else R.string.auth_loading))}
        state.error?.let { Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error,modifier=Modifier.testTag("registry-error")) }
        if(state.conflict)Text(stringResource(if(state.selected!=null)R.string.h_conflict else R.string.h_conflict_reload),modifier=Modifier.testTag("conflict"))
        if(state.organization!=null && !state.writable)Text(stringResource(R.string.h_organization_inactive))
        if(state.organization != null) {
            Text(stringResource(when(sync?.phase) {
                SyncPhase.SYNCHRONIZED -> R.string.h_sync_done
                SyncPhase.SYNCING -> R.string.h_sync_running
                SyncPhase.RETRY -> R.string.h_sync_retry
                SyncPhase.CONFLICT -> R.string.h_sync_conflict
                else -> R.string.h_sync_pending
            }))
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                TextButton(onClick=model::syncNow, enabled=!busy && state.writable && sync?.phase != SyncPhase.SYNCING) { Text(stringResource(R.string.h_sync_now)) }
                if(!sync?.conflicts.isNullOrEmpty()) TextButton(onClick={showConflicts=true}, enabled=!busy && state.form==null) { Text(stringResource(R.string.h_sync_review)) }
            }
            if(state.selected?.id in sync?.pendingIds.orEmpty()) Text(stringResource(R.string.h_unsynced))
        }
        when {
            state.form!=null -> HydrantFormContent(state,model,Modifier.weight(1f))
            state.selected!=null -> HydrantDetails(state,model,Modifier.weight(1f))
            else -> {
                if(state.organization!=null) {
                    Button(onClick=model::add,enabled=!busy && state.writable,modifier=Modifier.testTag("add")){Text(stringResource(R.string.h_add))}
                    TextButton(onClick={showFilters=!showFilters},enabled=!busy,modifier=Modifier.testTag("filters")){Text(stringResource(R.string.h_filters))}
                    if(state.query.filtered)Text(listOfNotNull(state.query.search.takeIf{it.isNotBlank()},state.query.type?.let { typeName(state.types.find { type->type.id==it }) },state.query.status?.let{stringResource(statusLabel(it))},stringResource(activeLabel(state.query.active))).joinToString(" · "))
                }
                LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    if(showFilters && state.organization!=null)item {
                        Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                            val q=state.filterDraft
                            OutlinedTextField(q.search,{model.changeFilters(q.copy(search=it.take(200)))},label={Text(stringResource(R.string.h_search_hint))},enabled=!busy,modifier=Modifier.fillMaxWidth().testTag("search-input"))
                            Choice(stringResource(R.string.h_type),q.type?.let { typeName(state.types.find { type->type.id==it }) } ?: stringResource(R.string.h_all),
                                listOf("" to stringResource(R.string.h_all))+state.types.map { it.id to typeName(it) },!busy,"filter-type",{model.changeFilters(q.copy(type=it.ifBlank{null}))})
                            Choice(stringResource(R.string.h_status),q.status?.let{stringResource(statusLabel(it))} ?: stringResource(R.string.h_all),
                                listOf("" to stringResource(R.string.h_all))+HydrantStatus.entries.map{it.name to stringResource(statusLabel(it))},!busy,"filter-status",{model.changeFilters(q.copy(status=it.takeIf{it.isNotBlank()}?.let(HydrantStatus::valueOf)))})
                            if(state.manages)Choice(stringResource(R.string.h_active_state),stringResource(activeLabel(q.active)),ActiveFilter.entries.map{it.name to stringResource(activeLabel(it))},!busy,"filter-active",{model.changeFilters(q.copy(active=ActiveFilter.valueOf(it)))})
                            Button(onClick={keyboard?.hide();model.applyFilters();showFilters=false},enabled=!busy,modifier=Modifier.testTag("apply-filters")){Text(stringResource(R.string.h_search))}
                            TextButton(onClick={keyboard?.hide();model.clearFilters();showFilters=false},enabled=!busy,modifier=Modifier.testTag("clear-filters")){Text(stringResource(R.string.h_clear_filters))}
                        }
                    }
                    if(!busy && state.rows.isEmpty())item { Text(stringResource(if(state.organization==null)R.string.h_no_organization else if(state.query.filtered)R.string.h_no_matches else R.string.h_empty)) }
                    items(state.rows,key={it.id}) { h ->
                        OutlinedCard(onClick={model.open(h.id)},enabled=!busy,modifier=Modifier.fillMaxWidth().testTag("hydrant-${h.id}")) {
                            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                                Text(h.code ?: stringResource(R.string.h_pending_code),style=MaterialTheme.typography.titleMedium)
                                Text(typeName(state.types.find { it.id==h.type }))
                                Text(stringResource(statusLabel(h.status)))
                                Text(h.address ?: h.description ?: stringResource(R.string.h_coordinates))
                                if(!h.active)Text(stringResource(R.string.h_inactive))
                                if(h.id in sync?.pendingIds.orEmpty())Text(stringResource(R.string.h_unsynced))
                            }
                        }
                    }
                    if(state.more)item { TextButton(onClick=model::loadMore,enabled=!busy){Text(stringResource(R.string.access_load_more))} }
                }
            }
        }
    } }
    if(showConflicts && sync != null) {
        val conflict = sync.conflicts.find { it.sequence == conflictSequence }
        AlertDialog(onDismissRequest={if(!busy) { showConflicts=false; conflictSequence=null }},
            title={Text(stringResource(R.string.h_sync_review))},
            text={Column(Modifier.heightIn(max=440.dp).verticalScroll(rememberScrollState()), verticalArrangement=Arrangement.spacedBy(8.dp)) {
                state.error?.let { Text(stringResource(errorLabel(it)), color=MaterialTheme.colorScheme.error) }
                if(conflict == null) {
                    if(sync.conflicts.isEmpty())Text(stringResource(R.string.h_conflicts_resolved))
                    sync.conflicts.forEach { item ->
                        OutlinedButton(onClick={conflictSequence=item.sequence}, enabled=!busy) { Text(item.local.code ?: item.local.id) }
                    }
                } else {
                    Text(conflict.local.id)
                    Text(stringResource(when(conflict.operation) {
                        "CREATE" -> R.string.h_add; "UPDATE" -> R.string.h_edit
                        "CHANGE_STATUS" -> R.string.h_change_status; else -> R.string.h_active_state
                    }), style=MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.h_conflict_local), style=MaterialTheme.typography.titleMedium)
                    DetailFields(conflict.local,state.types)
                    if(conflict.intent != conflict.local) {
                        Text(stringResource(R.string.h_conflict_intent), style=MaterialTheme.typography.titleMedium)
                        DetailFields(conflict.intent,state.types)
                    }
                    Text(stringResource(R.string.h_conflict_server), style=MaterialTheme.typography.titleMedium)
                    conflict.server?.let { DetailFields(it,state.types) } ?: Text(stringResource(R.string.h_conflict_server_missing))
                    Text(stringResource(R.string.h_resolution_notice))
                    OutlinedButton(onClick={model.resolveConflict(conflict.sequence,ConflictResolution.KEEP_SERVER)}, enabled=!busy && state.writable && conflict.server!=null) { Text(stringResource(R.string.h_keep_server)) }
                    OutlinedButton(onClick={model.resolveConflict(conflict.sequence,ConflictResolution.KEEP_LOCAL)}, enabled=!busy && state.writable && conflict.server!=null && (state.manages || conflict.operation !in listOf("UPDATE","SET_ACTIVE"))) { Text(stringResource(R.string.h_keep_local)) }
                    TextButton(onClick={conflictSequence=null}, enabled=!busy) { Text(stringResource(R.string.h_back)) }
                }
            }}, confirmButton={TextButton(onClick={showConflicts=false;conflictSequence=null}, enabled=!busy) { Text(stringResource(R.string.h_back)) }})
    }
    if(state.confirmDeactivate)AlertDialog(onDismissRequest=model::dismissDeactivate,
        title={Text(stringResource(R.string.h_deactivate))},text={Text(stringResource(R.string.h_deactivate_confirm))},
        confirmButton={TextButton(onClick=model::confirmDeactivate,modifier=Modifier.testTag("confirm-deactivate")){Text(stringResource(R.string.h_deactivate))}},
        dismissButton={TextButton(onClick=model::dismissDeactivate){Text(stringResource(R.string.h_cancel))}})
}
@Composable private fun Field(label: Int, value: String?) {
    Text(stringResource(label),style=MaterialTheme.typography.labelLarge)
    Text(value?.takeIf { it.isNotBlank() } ?: stringResource(R.string.h_missing))
}
@Composable private fun DetailFields(h: Hydrant, types: List<HydrantType>) {
    Field(R.string.h_code,h.code ?: stringResource(R.string.h_pending_code));Field(R.string.h_type,typeName(types.find { it.id==h.type }))
    Field(R.string.h_status,stringResource(statusLabel(h.status)));Field(R.string.h_latitude,h.latitude?.toString());Field(R.string.h_longitude,h.longitude?.toString())
    Field(R.string.h_address,h.address);Field(R.string.h_description,h.description);Field(R.string.h_notes,h.notes)
    Field(R.string.h_interval,h.interval?.toString() ?: stringResource(R.string.h_inherit_interval))
    Field(R.string.h_active_state,stringResource(if(h.active)R.string.h_active else R.string.h_inactive));Field(R.string.h_version,h.version.toString())
}
@Composable private fun HydrantDetails(state: RegistryState,model: HydrantViewModel,modifier: Modifier) {
    val h=state.selected?:return;val enabled=!state.loading && !state.mutating
    var status by remember(h.id,h.version,h.status) { mutableStateOf(h.status) }
    Column(modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.h_details),style=MaterialTheme.typography.titleLarge)
        TextButton(onClick=model::back,enabled=enabled){Text(stringResource(R.string.h_back))}
        DetailFields(h,state.types)
        if(state.reviewDraft!=null && state.manages)Button(onClick=model::reviewDraft,enabled=enabled,modifier=Modifier.testTag("review-draft")){Text(stringResource(R.string.h_review_draft))}
        if(state.writable && (h.active || state.manages)) {
            Choice(stringResource(R.string.h_status),stringResource(statusLabel(status)),HydrantStatus.entries.map { it.name to stringResource(statusLabel(it)) },enabled,"status",{status=HydrantStatus.valueOf(it)})
            Button(onClick={model.status(status)},enabled=enabled && status!=h.status,modifier=Modifier.testTag("save-status")){Text(stringResource(R.string.h_change_status))}
        }
        if(state.manages && state.writable) {
            Button(onClick=model::edit,enabled=enabled,modifier=Modifier.testTag("edit")){Text(stringResource(R.string.h_edit))}
            OutlinedButton(onClick=model::requestActive,enabled=enabled,modifier=Modifier.testTag("set-active")){Text(stringResource(if(h.active)R.string.h_deactivate else R.string.h_reactivate))}
        }
        Spacer(Modifier.height(16.dp))
    }
}
@Composable private fun HydrantFormContent(state: RegistryState,model: HydrantViewModel,modifier: Modifier) {
    val form=state.form?:return;val enabled=!state.loading && !state.mutating
    Column(modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Text(stringResource(if(form.baseVersion==null)R.string.h_add else R.string.h_edit),style=MaterialTheme.typography.titleLarge)
        if(state.conflict && state.selected!=null){Text(stringResource(R.string.h_latest));DetailFields(state.selected,state.types);Text(stringResource(R.string.h_your_draft))}
        val choices=state.types.filter { it.active }.map { type -> type.id to stringResource(R.string.h_type_choice,typeName(type),stringResource(if(type.organization==null)R.string.h_global else R.string.h_local)) }
        Choice(stringResource(R.string.h_type),typeName(state.types.find { it.id==form.type }),choices,enabled,"type",{model.changeForm(form.copy(type=it))})
        // Text keyboard keeps minus signs and locale decimal separators available.
        FormText(R.string.h_latitude,form.latitude,enabled,"latitude"){model.changeForm(form.copy(latitude=it))}
        FormText(R.string.h_longitude,form.longitude,enabled,"longitude"){model.changeForm(form.copy(longitude=it))}
        FormText(R.string.h_address,form.address,enabled,"address"){model.changeForm(form.copy(address=it))}
        FormText(R.string.h_description,form.description,enabled,"description"){model.changeForm(form.copy(description=it))}
        if(form.baseVersion==null)Choice(stringResource(R.string.h_status),stringResource(statusLabel(form.status)),HydrantStatus.entries.map { it.name to stringResource(statusLabel(it)) },enabled,"create-status",{model.changeForm(form.copy(status=HydrantStatus.valueOf(it)))})
        FormText(R.string.h_notes,form.notes,enabled,"notes"){model.changeForm(form.copy(notes=it))}
        FormText(R.string.h_interval,form.interval,enabled,"interval",true){model.changeForm(form.copy(interval=it))}
        Text(stringResource(R.string.h_form_notice))
        Button(onClick=model::save,enabled=enabled,modifier=Modifier.testTag("save")){Text(stringResource(R.string.h_save))}
        TextButton(onClick=model::cancelForm,enabled=enabled,modifier=Modifier.testTag("cancel")){Text(stringResource(R.string.h_cancel))}
    }
}
@Composable private fun FormText(label: Int,value: String,enabled: Boolean,tag: String,numeric: Boolean=false,change: (String)->Unit) {
    OutlinedTextField(value,change,enabled=enabled,label={Text(stringResource(label))},modifier=Modifier.fillMaxWidth().testTag(tag),
        keyboardOptions=KeyboardOptions(keyboardType=if(numeric)KeyboardType.Number else KeyboardType.Text))
}
