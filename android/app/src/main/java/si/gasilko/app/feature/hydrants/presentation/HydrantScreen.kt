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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.inspections.presentation.*
import si.gasilko.app.feature.inspections.domain.InspectionMode
import si.gasilko.app.feature.photos.presentation.*
import si.gasilko.app.feature.inspections.domain.inspectionDue
import java.time.Instant
import java.text.DateFormat
import java.util.Date

fun activeLabel(active: ActiveFilter): Int = when(active) { ActiveFilter.ACTIVE->R.string.h_active_only; ActiveFilter.INACTIVE->R.string.h_inactive_only; ActiveFilter.ALL->R.string.h_all }
fun statusLabel(status: HydrantStatus): Int = when(status) {
    HydrantStatus.WORKING -> R.string.h_working
    HydrantStatus.NOT_WORKING -> R.string.h_not_working
    HydrantStatus.NEEDS_INSPECTION -> R.string.h_needs_inspection
    HydrantStatus.UNKNOWN -> R.string.h_unknown
}
private fun hydrantTone(status: HydrantStatus)=when(status) {
    HydrantStatus.WORKING->FieldTone.SUCCESS
    HydrantStatus.NOT_WORKING->FieldTone.DANGER
    HydrantStatus.NEEDS_INSPECTION->FieldTone.WARNING
    HydrantStatus.UNKNOWN->FieldTone.NEUTRAL
}
fun errorLabel(error: RegistryError): Int = when(error) {
    RegistryError.REASSIGNMENT_PENDING -> R.string.reassign_pending
    RegistryError.EXECUTION_PENDING -> R.string.execution_pending
    RegistryError.EXECUTION_CHANGED -> R.string.execution_changed
    RegistryError.ROUTE_ASSIGNMENTS -> R.string.routes_assignments_required
    RegistryError.ROUTE_COORDINATES -> R.string.routes_coordinates_required
    RegistryError.ROUTE_UNREACHABLE -> R.string.routes_unreachable
    RegistryError.ROUTE_LIMIT -> R.string.routes_limit
    RegistryError.ROUTE_CONFIGURATION -> R.string.routes_configuration
    RegistryError.ROUTE_PROVIDER -> R.string.routes_provider_error
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
    val photoState by model.photos.state.collectAsStateWithLifecycle()
    si.gasilko.app.feature.photos.presentation.PhotoAcquisitionHost(model.photos)
    val observedSync by model.sync.collectAsStateWithLifecycle()
    val sync = observedSync.takeIf { it.organization == state.organization?.id }
    var showHome by rememberSaveable(state.organization?.id) { mutableStateOf(true) }
    var planQuery by remember(model,model.photoScope,state.organization?.id) {
        mutableStateOf<HydrantQuery?>(model.navigation.state.value.takeIf { it.active && it.organization==state.organization?.id }
            ?.let { state.query.copy(organization=it.organization) })
    }
    var planEntry by remember { mutableIntStateOf(0) }
    var showTeams by remember(model,model.photoScope,state.organization?.id) { mutableStateOf(false) }
    var showConflicts by remember(state.organization?.id) { mutableStateOf(false) }
    var conflictSequence by remember(state.organization?.id) { mutableStateOf<Long?>(null) }
    LaunchedEffect(model) { if(!model.photos.state.value.busy)model.refresh() }
    LaunchedEffect(state.notificationPlanId) {
        if(state.notificationPlanId!=null) { showHome=false;showTeams=false;planQuery=state.query;planEntry++ }
    }
    if(planQuery!=null && state.writable && state.planStop==null && state.selected==null) {
        key(model,model.photoScope,state.organization!!.id,planEntry) {
            OrganizationFrame(state.organization?.name) {
                si.gasilko.app.feature.plans.PlansScreen(model,planQuery!!) { planQuery=null }
            }
        }
        return
    }
    if(showTeams && state.manages && state.writable) {
        key(model,model.photoScope,state.organization!!.id,planEntry) {
            OrganizationFrame(state.organization?.name) {
                si.gasilko.app.feature.teams.TeamsScreen(model,state.organization!!.id) { showTeams=false }
            }
        }
        return
    }
    var showMap by rememberSaveable(state.organization?.id) { mutableStateOf(false) }
    var mapDetail by rememberSaveable(state.organization?.id) { mutableStateOf(false) }
    val mapState = key(state.organization?.id) { rememberSaveableStateHolder() }
    val historyHydrant=state.selected
    var gallery by remember(model,model.photoScope,state.organization?.id,historyHydrant?.id) { mutableStateOf(false) }
    var galleryInspection by remember(model,model.photoScope,state.organization?.id,historyHydrant?.id) { mutableStateOf<String?>(null) }
    var viewedPhoto by remember(model,model.photoScope,state.organization?.id,historyHydrant?.id) { mutableStateOf<String?>(null) }
    val photoFlow=remember(model,model.photoScope,state.organization?.id,historyHydrant?.id) {
        historyHydrant?.let { model.photoEntries(it.organization,it.id) }
            ?: kotlinx.coroutines.flow.flowOf(PhotoGalleryState())
    }
    val allPhotos=key(model,model.photoScope,state.organization?.id,historyHydrant?.id) {
        photoFlow.collectAsStateWithLifecycle(initialValue=PhotoGalleryState()).value
    }
    val permanentPhotos=allPhotos.copy(entries=allPhotos.entries.filter { it.photo.category==si.gasilko.app.feature.photos.domain.PhotoCategory.HYDRANT })
    val galleryState=if(galleryInspection==null)permanentPhotos else allPhotos.copy(entries=allPhotos.entries.filter {
        it.photo.category==si.gasilko.app.feature.photos.domain.PhotoCategory.INSPECTION && it.photo.inspectionId==galleryInspection
    })
    val photoCounts=allPhotos.entries.filter { it.photo.category==si.gasilko.app.feature.photos.domain.PhotoCategory.INSPECTION }
        .mapNotNull { it.photo.inspectionId }.groupingBy { it }.eachCount()
    val openInspectionPhotos: (String)->Unit = { galleryInspection=it;viewedPhoto=null;gallery=true }
    if(historyHydrant!=null && (gallery || viewedPhoto!=null)) {
        key(model,model.photoScope,historyHydrant.organization,historyHydrant.id,galleryInspection) {
            OrganizationFrame(state.organization?.name) {
                if(viewedPhoto!=null)PhotoViewer(model,galleryState.entries.find { it.photo.id==viewedPhoto }) { viewedPhoto=null }
                else PhotoGalleryScreen(model,historyHydrant.organization,historyHydrant.id,
                    historyHydrant.code ?: stringResource(R.string.h_pending_code),galleryState,
                    state.loading || state.mutating || photoState.busy,
                    galleryInspection==null && state.writable && (historyHydrant.active || state.manages),sync?.phase,
                    {viewedPhoto=it},{gallery=false;galleryInspection=null},galleryInspection)
            }
        }
        return
    }
    if(state.showHistory && historyHydrant!=null) {
        val h=historyHydrant
        val historyFlow=remember(model,h.organization,h.id) { model.inspectionHistory(h.organization,h.id) }
        key(model,h.organization,h.id) {
            val history by historyFlow.collectAsStateWithLifecycle(initialValue=InspectionHistoryState())
            OrganizationFrame(state.organization?.name) {
                InspectionHistoryScreen(h.code ?: stringResource(R.string.h_pending_code),history,state.historyRefreshing,
                    state.historyError,sync?.phase,model::refreshHistory,model::syncNow,model::closeHistory,photoCounts,openInspectionPhotos)
            }
        }
        return
    }
    state.inspectionDraft?.let { draft ->
        val label=state.selected?.code ?: stringResource(R.string.h_pending_code)
        val context=LocalContext.current
        val inspectionBusy=state.mutating || photoState.busy
        val identification: @Composable ()->Unit = {
            if(draft.planContext!=null)PermanentHydrantPhoto(model,draft.organization,draft.hydrantId,label,
                refreshMetadata=draft.completion==null)
        }
        val stagedPhotos: @Composable ()->Unit = {
            StagedInspectionPhotos(draft.photos,!inspectionBusy && draft.completion==null,
                {model.addInspectionPhoto(context)},model::removeInspectionPhoto)
        }
        OrganizationFrame(state.organization?.name) {
            if(draft.mode==InspectionMode.GUIDED)GuidedInspectionScreen(draft,label,inspectionBusy,state.error,
                model::answerInspectionCheck,model::changeInspection,model::moveGuided,model::completeInspection,model::cancelInspection,model::changeMeasurements,stagedPhotos,identification)
            else if(draft.mode==InspectionMode.CLASSIC)ClassicInspectionScreen(draft,label,inspectionBusy,state.error,
                model::answerInspectionCheck,model::changeInspection,model::completeInspection,model::cancelInspection,model::changeMeasurements,stagedPhotos,identification)
            else QuickInspectionScreen(draft,label,inspectionBusy,state.error,model::changeInspection,
                {model.completeInspection()},model::cancelInspection,stagedPhotos,identification)
        }
        return
    }
    LaunchedEffect(mapDetail,state.selected?.id,state.loading,state.form) {
        if(mapDetail && !state.loading && state.selected==null && state.form==null)mapDetail=false
    }
    if(showMap && !mapDetail && state.writable) {
        val mapFlow = remember(model,state.query) { model.mapHydrants(state.query) }
        // A new scope/filter must not display the previous collector's last emission.
        val mapData = key(model,state.query) {
            val observed by mapFlow.collectAsStateWithLifecycle(initialValue=MapHydrantsState(loading=true))
            observed
        }
        OrganizationFrame(state.organization?.name) {
            mapState.SaveableStateProvider("map") {
                si.gasilko.app.feature.map.MapScreen(onBack={showMap=false}, hydrants=mapData.rows,
                    dataLoading=mapData.loading, dataError=mapData.error ?: state.error,
                    photoPreview={ h -> PermanentHydrantPhoto(model,h.organization,h.id) },
                    canOpenHydrant={!state.loading && !state.mutating && !photoState.busy},
                    creationEnabled=!state.loading && !state.mutating,
                    onAddHydrant={ latitude,longitude,accuracy ->
                        model.addAt(latitude,longitude,accuracy)
                        if(model.state.value.form!=null)mapDetail=true
                    },
                    onOpenHydrant={ id -> if(!state.loading && !state.mutating) { model.open(id); mapDetail=true } })
            }
        }
        return
    }
    val busy=state.loading || state.mutating || photoState.busy
    var showFilters by remember { mutableStateOf(false) }
    val keyboard=LocalSoftwareKeyboardController.current
    BackHandler(state.selected!=null || state.form!=null) { if(!photoState.busy) { if(state.form!=null)model.cancelForm() else model.back() } }
    val atHome=showHome && state.selected==null && state.form==null
    BackHandler(!showHome && state.selected==null && state.form==null) { if(!busy)showHome=true }
    Scaffold { padding ->
    BoxWithConstraints(Modifier.fillMaxSize().padding(padding).imePadding()) {
        val availableHeight = maxHeight
    Column(Modifier.fillMaxSize().padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        ScrollableHeader(availableHeight * 0.5f) {
            AppHeader(
                title=stringResource(if(atHome)R.string.shell_home else R.string.h_title),
                organization=state.organization?.name,
                home=if(!atHome && state.selected==null && state.form==null)({showHome=true}) else null,
                enabled=!busy,refresh=model::refresh,requestAccess=requestAccess,signOut=signOut,
                canRequestAccess=!busy && state.form==null,canSignOut=!state.mutating && !photoState.busy)
            if(atHome)Choice(stringResource(R.string.h_organization),state.organization?.name ?: stringResource(R.string.h_select_organization),
                state.organizations.map { it.id to it.name },!busy && state.form==null && state.organizations.size>1,"organization",model::switchOrganization)
            if(busy){LinearProgressIndicator(Modifier.fillMaxWidth());Text(stringResource(if(state.mutating)R.string.h_saving else R.string.auth_loading))}
            state.error?.let { FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER,modifier=Modifier.testTag("registry-error")) }
            if(state.conflict)Text(stringResource(if(state.selected!=null)R.string.h_conflict else R.string.h_conflict_reload),modifier=Modifier.testTag("conflict"))
            if(atHome && state.organization==null && !busy)FieldBanner(stringResource(R.string.h_no_organization))
            if(state.organization!=null && !state.writable)Text(stringResource(R.string.h_organization_inactive))
            if(!atHome)RegistrySyncOverview(state,sync,busy,model::syncNow,{showConflicts=true})
        }
        when {
            atHome -> HomeDashboard(Modifier.weight(1f),!busy,state.writable,state.manages,
                hydrants={showHome=false},map={showMap=true;mapDetail=false},
                plans={planQuery=state.query.copy(organization=state.organization!!.id)},teams={showTeams=true}) {
                if(state.organization!=null)OperationalCard {
                    SectionHeading(stringResource(R.string.shell_operations))
                    RegistrySyncOverview(state,sync,busy,model::syncNow,{showConflicts=true})
                }
            }
            state.form!=null -> HydrantFormContent(state,model,Modifier.weight(1f))
            state.selected!=null -> HydrantDetails(state,model,Modifier.weight(1f),permanentPhotos,
                {galleryInspection=null;gallery=true},{galleryInspection=null;viewedPhoto=it},photoCounts,openInspectionPhotos)
            else -> {
                if(state.organization!=null) {
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        PrimaryAction(onClick=model::add,enabled=!busy && state.writable,modifier=Modifier.testTag("add")){Text(stringResource(R.string.h_add))}
                        SecondaryAction(onClick={showFilters=!showFilters},enabled=!busy,modifier=Modifier.testTag("filters")){Text(stringResource(R.string.h_filters))}
                    }
                    if(state.query.filtered)Text(listOfNotNull(state.query.search.takeIf{it.isNotBlank()},state.query.type?.let { typeName(state.types.find { type->type.id==it }) },state.query.status?.let{stringResource(statusLabel(it))},stringResource(activeLabel(state.query.active))).joinToString(" · "))
                }
                if(showFilters && state.organization!=null) {
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
                LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    if(!busy && state.rows.isEmpty())item { Text(stringResource(if(state.organization==null)R.string.h_no_organization else if(state.query.filtered)R.string.h_no_matches else R.string.h_empty)) }
                    items(state.rows,key={it.id}) { h ->
                        OutlinedCard(onClick={model.open(h.id)},enabled=!busy,modifier=Modifier.fillMaxWidth().testTag("hydrant-${h.id}"),
                            colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface)) {
                            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                                Text(h.code ?: stringResource(R.string.h_pending_code),style=MaterialTheme.typography.titleLarge)
                                Text(typeName(state.types.find { it.id==h.type }),style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
                                StatusBadge(stringResource(statusLabel(h.status)),hydrantTone(h.status))
                                Text(h.address ?: h.description ?: stringResource(R.string.h_coordinates),style=MaterialTheme.typography.bodyLarge)
                                if(!h.active)StatusBadge(stringResource(R.string.h_inactive))
                                if(h.id in sync?.pendingIds.orEmpty())StatusBadge(stringResource(R.string.h_unsynced),FieldTone.WARNING)
                            }
                        }
                    }
                    if(state.more)item { TextButton(onClick=model::loadMore,enabled=!busy){Text(stringResource(R.string.access_load_more))} }
                }
            }
        }
    } } }
    if(showConflicts && sync != null) {
        val conflict = sync.conflicts.find { it.sequence == conflictSequence }
        AlertDialog(onDismissRequest={if(!busy) { showConflicts=false; conflictSequence=null }},
            title={Text(stringResource(R.string.h_sync_review))},
            text={Column(Modifier.heightIn(max=440.dp).verticalScroll(rememberScrollState()), verticalArrangement=Arrangement.spacedBy(8.dp)) {
                state.error?.let { FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER) }
                if(conflict == null) {
                    if(sync.conflicts.isEmpty())FieldBanner(stringResource(R.string.h_conflicts_resolved),FieldTone.SUCCESS)
                    sync.conflicts.forEach { item ->
                        SecondaryAction(onClick={conflictSequence=item.sequence}, enabled=!busy,modifier=Modifier.fillMaxWidth()) { Text(item.local.code ?: item.local.id) }
                    }
                } else {
                    Text(conflict.local.id)
                    Text(stringResource(when(conflict.operation) {
                        "CREATE" -> R.string.h_add; "UPDATE" -> R.string.h_edit
                        "CHANGE_STATUS" -> R.string.h_change_status; else -> R.string.h_active_state
                    }), style=MaterialTheme.typography.titleMedium)
                    FieldBanner(stringResource(R.string.h_conflict_local),FieldTone.NEUTRAL)
                    DetailFields(conflict.local,state.types)
                    if(conflict.intent != conflict.local) {
                        HorizontalDivider(Modifier.padding(vertical=8.dp))
                        FieldBanner(stringResource(R.string.h_conflict_intent),FieldTone.WARNING)
                        DetailFields(conflict.intent,state.types)
                    }
                    HorizontalDivider(Modifier.padding(vertical=8.dp))
                    FieldBanner(stringResource(R.string.h_conflict_server),FieldTone.INFO)
                    conflict.server?.let { DetailFields(it,state.types) } ?: Text(stringResource(R.string.h_conflict_server_missing))
                    FieldBanner(stringResource(R.string.h_resolution_notice),FieldTone.WARNING)
                    SecondaryAction(modifier=Modifier.fillMaxWidth(),onClick={model.resolveConflict(conflict.sequence,ConflictResolution.KEEP_SERVER)}, enabled=!busy && state.writable && conflict.server!=null) { Text(stringResource(R.string.h_keep_server)) }
                    SecondaryAction(modifier=Modifier.fillMaxWidth(),onClick={model.resolveConflict(conflict.sequence,ConflictResolution.KEEP_LOCAL)}, enabled=!busy && state.writable && conflict.server!=null && (state.manages || conflict.operation !in listOf("UPDATE","SET_ACTIVE"))) { Text(stringResource(R.string.h_keep_local)) }
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
    Column(verticalArrangement=Arrangement.spacedBy(2.dp)) {
        Text(stringResource(label),style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value?.takeIf { it.isNotBlank() } ?: stringResource(R.string.h_missing),style=MaterialTheme.typography.bodyLarge)
    }
}
@Composable private fun DetailFields(h: Hydrant, types: List<HydrantType>) {
    SectionHeading(stringResource(R.string.ui_location))
    OperationalCard {
        Field(R.string.h_address,h.address);Field(R.string.h_description,h.description)
        Field(R.string.h_latitude,h.latitude?.toString());Field(R.string.h_longitude,h.longitude?.toString())
    }
    SectionHeading(stringResource(R.string.ui_technical))
    OperationalCard {
        Field(R.string.h_code,h.code ?: stringResource(R.string.h_pending_code));Field(R.string.h_type,typeName(types.find { it.id==h.type }))
        Field(R.string.h_status,stringResource(statusLabel(h.status)))
        Field(R.string.h_interval,h.interval?.toString() ?: stringResource(R.string.h_inherit_interval))
        Field(R.string.h_active_state,stringResource(if(h.active)R.string.h_active else R.string.h_inactive));Field(R.string.h_version,h.version.toString())
        Field(R.string.h_notes,h.notes)
    }
}
@Composable private fun HydrantDetails(state: RegistryState,model: HydrantViewModel,modifier: Modifier,
    gallery: PhotoGalleryState, openGallery: ()->Unit, openPhoto: (String)->Unit,
    photoCounts: Map<String,Int>, openInspectionPhotos: (String)->Unit) {
    val photoState by model.photos.state.collectAsStateWithLifecycle()
    val context=LocalContext.current
    val h=state.selected?:return;val enabled=!state.loading && !state.mutating && !photoState.busy
    var status by remember(h.id,h.version,h.status) { mutableStateOf(h.status) }
    Column(modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        ScreenHeading(h.code ?: stringResource(R.string.h_pending_code),stringResource(R.string.h_details))
        StatusBadge(stringResource(statusLabel(h.status)),hydrantTone(h.status))
        TextButton(onClick=model::back,enabled=enabled){Text(stringResource(R.string.h_back))}
        if(state.inspectionSaved)FieldBanner(stringResource(R.string.inspection_saved),FieldTone.SUCCESS)
        if(state.planStop?.inspectionId!=null)StatusBadge(stringResource(R.string.execution_completed),FieldTone.SUCCESS)
        if(state.writable && (h.active || state.manages) && state.planStop?.inspectionId==null) {
            SectionHeading(stringResource(R.string.ui_inspections))
            PrimaryAction(onClick={model.startInspection(InspectionMode.QUICK)},enabled=enabled,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(R.string.inspection_start_quick))
            }
            SecondaryAction(onClick={model.startInspection(InspectionMode.GUIDED)},enabled=enabled,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(R.string.inspection_start_guided))
            }
            SecondaryAction(onClick={model.startInspection(InspectionMode.CLASSIC)},enabled=enabled,modifier=Modifier.fillMaxWidth().heightIn(min=56.dp)) {
                Text(stringResource(R.string.inspection_start_classic))
            }
        }
        DetailFields(h,state.types)
        SectionHeading(stringResource(R.string.ui_photos))
        PhotoPreview(model,gallery,enabled,openGallery,openPhoto)
        if(state.writable && (h.active || state.manages)) {
            OutlinedButton(onClick={model.addPhoto(context)},enabled=enabled) { Text(stringResource(R.string.photo_add)) }
        }
        if(photoState.step==si.gasilko.app.feature.photos.presentation.PhotoStep.SAVED)
            FieldBanner(stringResource(R.string.photo_saved_pending),FieldTone.INFO)
        SectionHeading(stringResource(R.string.ui_management))
        if(state.reviewDraft!=null && state.manages)Button(onClick=model::reviewDraft,enabled=enabled,modifier=Modifier.testTag("review-draft")){Text(stringResource(R.string.h_review_draft))}
        if(state.writable && (h.active || state.manages)) {
            Choice(stringResource(R.string.h_status),stringResource(statusLabel(status)),HydrantStatus.entries.map { it.name to stringResource(statusLabel(it)) },enabled,"status",{status=HydrantStatus.valueOf(it)})
            Button(onClick={model.status(status)},enabled=enabled && status!=h.status,modifier=Modifier.testTag("save-status")){Text(stringResource(R.string.h_change_status))}
        }
        if(state.manages && state.writable) {
            Button(onClick=model::edit,enabled=enabled,modifier=Modifier.testTag("edit")){Text(stringResource(R.string.h_edit))}
            OutlinedButton(onClick=model::requestActive,enabled=enabled,modifier=Modifier.testTag("set-active")){Text(stringResource(if(h.active)R.string.h_deactivate else R.string.h_reactivate))}
        }
        val historyFlow=remember(model,h.organization,h.id) { model.inspectionHistory(h.organization,h.id) }
        key(model,h.organization,h.id) {
            val history by historyFlow.collectAsStateWithLifecycle(initialValue=InspectionHistoryState())
            val now by model.inspectionClock.collectAsStateWithLifecycle(initialValue=Instant.now())
            if(history.loaded && history.error==null)InspectionDueDetails(inspectionDue(history.rows.maxOfOrNull { it.completedAt },
                h.interval,state.organization?.inspectionIntervalMonths,now))
            SectionHeading(stringResource(R.string.inspection_local_history))
            TextButton(onClick=model::openHistory,enabled=enabled) { Text(stringResource(R.string.inspection_history_title)) }
            history.error?.let { Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error) }
            if(history.loaded && history.rows.isEmpty() && history.error==null)Text(stringResource(R.string.inspection_history_empty))
            // Compact local preview; full history and online-history controls belong to M5.6.
            history.entries.take(5).forEach { entry ->
                HorizontalDivider()
                InspectionHistoryItem(entry,photoCounts[entry.inspection.id] ?: 0,openInspectionPhotos)
            }
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
        if(form.baseVersion==null) {
            si.gasilko.app.feature.map.LocationControls(emptyList(),onLocation={},onCenter={},onSelect={},onUnavailable={},
                locationOnly=true,actionEnabled=enabled && state.writable,
                requestKey=form.id+":"+form.latitude+":"+form.longitude,
                onUseRequested=model::requestFormLocation,
                onUseLocation={fix -> model.useFormLocation(form,fix.latitude,fix.longitude,fix.accuracy)})
            form.coordinateAccuracy?.let { accuracy ->
                Text(stringResource(R.string.h_coordinate_accuracy,accuracy))
                if(accuracy>50f)Text(stringResource(R.string.h_location_low_accuracy),color=MaterialTheme.colorScheme.error)
            }
        }
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
