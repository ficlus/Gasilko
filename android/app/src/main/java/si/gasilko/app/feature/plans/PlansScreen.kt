package si.gasilko.app.feature.plans

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.*
import si.gasilko.app.feature.teams.TeamData
import si.gasilko.app.feature.map.MapScreen
import si.gasilko.app.feature.map.RouteAttribution
import java.time.Instant
import java.text.DateFormat
import java.util.Date
import java.util.UUID

data class PlanViewData(val data: PlanData=PlanData(),val teams: TeamData=TeamData(),
    val candidates: PlanCandidates=PlanCandidates(),val error: RegistryError?=null)
private data class PlanDraft(val id: String=UUID.randomUUID().toString(),val version: Long=0,val name: String="",
    val status: PlanStatus=PlanStatus.DRAFT,val mode: SelectionMode=SelectionMode.MANUAL,
    val teams: Set<String> = emptySet(),val hydrants: Set<String> = emptySet(),val snapshot: String="{}",
    val latitude: String="",val longitude: String="",val returnToStart: Boolean=false) {
    val editable get()=status==PlanStatus.DRAFT || status==PlanStatus.PLANNED
    fun request(status: PlanStatus): PlanSave {
        fun coordinate(s: String): Double? {
            if(s.isBlank())return null
            return s.trim().replace(',','.').toDoubleOrNull()?.takeIf { it.isFinite() }
                ?: throw RegistryFailure(RegistryError.COORDINATES)
        }
        val lat=coordinate(latitude);val lon=coordinate(longitude)
        if((lat==null)!=(lon==null) || (lat!=null && lat !in -90.0..90.0) || (lon!=null && lon !in -180.0..180.0))
            throw RegistryFailure(RegistryError.COORDINATES)
        return PlanSave(id,version,name.trim(),status,mode,snapshot,lat,lon,returnToStart,teams.sorted(),hydrants.sorted())
    }
}
private fun planDraft(p: InspectionPlan, data: PlanData) = PlanDraft(p.id,p.version,p.name,
    PlanStatus.valueOf(p.status),SelectionMode.valueOf(p.selectionMode),
    data.teams.filter { it.planId==p.id && it.active }.map { it.teamId }.toSet(),
    data.items.filter { it.planId==p.id && it.active }.map { it.hydrantId }.toSet(),p.selectionSnapshot,
    p.startLatitude?.toString().orEmpty(),p.startLongitude?.toString().orEmpty(),p.returnToStart)
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun PlansScreen(model: HydrantViewModel,query: HydrantQuery,back: ()->Unit) {
    val registry by model.state.collectAsStateWithLifecycle()
    var execution by remember { mutableStateOf(registry.executionPlanId) }
    if(!registry.manages || execution!=null) {
        PlanExecutionScreen(model,query,execution) { execution=null;if(!registry.manages)back() }
        return
    }
    val flow=remember(model,query) { model.planData(query) }
    val observed by flow.collectAsStateWithLifecycle(initialValue=PlanViewData())
    val scope=rememberCoroutineScope()
    var draft by remember { mutableStateOf<PlanDraft?>(null) }
    var pending by remember { mutableStateOf<PlanSave?>(null) }
    var assigning by remember { mutableStateOf<PlanAssignment?>(null) }
    var routing by remember { mutableStateOf<PlanRouting?>(null) }
    var activating by remember { mutableStateOf<PlanAssignment?>(null) }
    var mapTeam by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<RegistryError?>(null) }
    var cancel by remember { mutableStateOf(false) }
    fun refresh(candidates: Boolean=false) {
        if(busy)return
        busy=true;error=null
        scope.launch {
            try {
                if(candidates)model.refreshPlanCandidates(query.organization)
                else { model.refreshPlans(query.organization);draft=null;pending=null;assigning=null;routing=null;activating=null;mapTeam=null }
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER }
            finally { busy=false }
        }
    }
    fun submit(status: PlanStatus) {
        if(busy || assigning!=null || routing!=null || activating!=null)return
        val request=try { pending ?: draft?.request(status) ?: return }
            catch(e: RegistryFailure) { error=e.reason;return }
        pending=request;busy=true;error=null
        scope.launch {
            try { model.savePlan(query.organization,request);pending=null;draft=null;cancel=false }
            catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error in listOf(RegistryError.VALIDATION,RegistryError.CONFLICT))pending=null
            } finally { busy=false }
        }
    }
    fun assign() {
        if(busy || pending!=null || routing!=null || activating!=null)return
        val current=draft
        val request=assigning ?: current?.let { PlanAssignment(it.id,it.version) } ?: return
        assigning=request;busy=true;error=null
        scope.launch {
            try {
                val result=model.assignPlan(query.organization,request)
                draft=result.plans.find { it.id==request.id }?.let { planDraft(it,result) }
                assigning=null
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error in listOf(RegistryError.VALIDATION,RegistryError.CONFLICT))assigning=null
            } finally { busy=false }
        }
    }
    fun route() {
        if(busy || pending!=null || assigning!=null || activating!=null)return
        val request=routing ?: draft?.let { PlanRouting(it.id,it.version) } ?: return
        routing=request;busy=true;error=null
        scope.launch {
            try {
                val result=model.routePlan(query.organization,request)
                draft=result.plans.find { it.id==request.id }?.let { planDraft(it,result) }
                routing=null
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.ROUTE_PROVIDER
                if(error in listOf(RegistryError.VALIDATION,RegistryError.CONFLICT,RegistryError.ROUTE_ASSIGNMENTS,
                    RegistryError.ROUTE_COORDINATES))routing=null
            } finally { busy=false }
        }
    }
    fun activate() {
        if(busy)return
        val request=activating ?: draft?.let { PlanAssignment(it.id,it.version) } ?: return
        activating=request;busy=true;error=null
        scope.launch {
            try {
                model.activatePlan(query.organization,request)
                activating=null;execution=request.id
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error in listOf(RegistryError.CONFLICT,RegistryError.VALIDATION))activating=null
            } finally { busy=false }
        }
    }
    fun leave() { if(!busy) { if(mapTeam!=null)mapTeam=null else if(draft!=null)draft=null else back() } }
    BackHandler(onBack=::leave)
    LaunchedEffect(query.organization) { refresh() }
    val data=observed.data
    val d=draft
    val hasPendingHydrants=observed.candidates.hydrants.any { it.id in (d?.hydrants ?: emptySet()) && it.version==0L }
    val editable=d?.editable==true && !busy && pending==null && assigning==null && routing==null && activating==null
    val saved=data.plans.find { it.id==d?.id }
    val savedDraft=saved?.let { planDraft(it,data) }
    val unchanged=d!=null && d==savedDraft
    val savedTeams=data.teams.filter { it.planId==saved?.id && it.active }.map { it.teamId }.toSet()
    val assignedItems=data.items.filter { it.planId==saved?.id && it.active }
    val assignmentByHydrant=assignedItems.associateBy { it.hydrantId }
    val assignedCounts=assignedItems.groupingBy { it.teamId }.eachCount()
    val unassigned=assignedItems.count { it.teamId==null || it.teamId !in savedTeams }
    val routes=data.routes.filter { it.planId==saved?.id && it.valid && it.teamId in savedTeams }
    val shownRoute=routes.find { it.teamId==mapTeam }
    if(shownRoute!=null && observed.error==null && unchanged) {
        MapScreen(onBack={mapTeam=null},hydrants=emptyList(),onOpenHydrant=null,route=shownRoute)
        return
    }
    Scaffold { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding).imePadding()) {
        val availableHeight = maxHeight
        Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            ScrollableHeader(availableHeight * 0.5f) {
                ScreenHeading(stringResource(R.string.plans_title))
                FieldBanner(stringResource(R.string.plans_online_notice))
                FlowRow {
                    TextButton(onClick=::leave,enabled=!busy) { Text(stringResource(R.string.h_back)) }
                    TextButton(onClick={refresh()},enabled=!busy) { Text(stringResource(R.string.h_refresh)) }
                    if(d==null)TextButton(onClick={draft=PlanDraft(snapshot=planSelectionSnapshot(query,observed.candidates.incomplete))},
                        enabled=!busy && pending==null && assigning==null && routing==null && activating==null) { Text(stringResource(R.string.plans_new)) }
                    if(pending!=null)TextButton(onClick={submit(pending!!.status)},enabled=!busy) { Text(stringResource(R.string.photo_retry)) }
                    if(assigning!=null)TextButton(onClick=::assign,enabled=!busy) { Text(stringResource(R.string.photo_retry)) }
                    if(routing!=null)TextButton(onClick=::route,enabled=!busy) { Text(stringResource(R.string.photo_retry)) }
                    if(activating!=null)TextButton(onClick=::activate,enabled=!busy) { Text(stringResource(R.string.photo_retry)) }
                }
                if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                (error ?: observed.error)?.let {
                    FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER)
                    Text(stringResource(R.string.plans_retry))
                }
            }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                if(d==null) {
                    if(data.plans.isEmpty())item { Text(stringResource(R.string.plans_empty)) }
                    items(data.plans,key={it.id}) { p ->
                        OutlinedCard(onClick={
                            draft=planDraft(p,data)
                        },enabled=!busy && pending==null && assigning==null && routing==null && activating==null,modifier=Modifier.fillMaxWidth(),
                            colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface)) {
                            Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                                Text(p.name,style=MaterialTheme.typography.titleLarge)
                                StatusBadge(stringResource(planStatusLabel(PlanStatus.valueOf(p.status))),when(PlanStatus.valueOf(p.status)) {
                                    PlanStatus.ACTIVE,PlanStatus.PLANNED->FieldTone.INFO
                                    PlanStatus.COMPLETED->FieldTone.SUCCESS
                                    else->FieldTone.NEUTRAL
                                })
                            }
                        }
                    }
                } else {
                    item {
                        if(d.status==PlanStatus.PLANNED)PrimaryAction(onClick=::activate,enabled=editable && unchanged) {
                            Text(stringResource(R.string.execution_activate))
                        }
                        if(d.status==PlanStatus.ACTIVE)PrimaryAction(onClick={execution=d.id},enabled=!busy) {
                            Text(stringResource(R.string.execution_title))
                        }
                    }
                    item {
                        SectionHeading(stringResource(R.string.plans_assignment_title))
                        Text(stringResource(R.string.plans_assignment_note))
                        if(!unchanged && d.editable)Text(stringResource(R.string.plans_assignment_save_first))
                        if(saved!=null) {
                            savedTeams.sorted().forEach { team ->
                                val name=observed.teams.teams.find { it.id==team }?.name ?: team.take(8)
                                Text(stringResource(R.string.plans_assignment_count,name,assignedCounts[team] ?: 0))
                            }
                            Text(stringResource(R.string.plans_unassigned_count,unassigned))
                            if(unassigned>0)FieldBanner(stringResource(R.string.plans_unassigned_warning),FieldTone.WARNING)
                        }
                        if(d.editable)TextButton(onClick=::assign,enabled=editable && unchanged && assignedItems.isNotEmpty() &&
                            savedTeams.isNotEmpty() && savedTeams.all { id->observed.teams.teams.any { it.id==id && it.active } }) {
                            Text(stringResource(R.string.plans_assign))
                        }
                    }
                    item {
                        SectionHeading(stringResource(R.string.routes_title))
                        Text(stringResource(R.string.routes_notice))
                        if(saved?.startLatitude==null)Text(stringResource(R.string.routes_no_start))
                        if(!unchanged && d.editable)Text(stringResource(R.string.routes_save_first))
                        if(d.editable)TextButton(onClick=::route,enabled=editable && unchanged && unassigned==0 &&
                            assignedItems.isNotEmpty() && savedTeams.isNotEmpty()) { Text(stringResource(R.string.routes_calculate)) }
                        if(routes.isEmpty())Text(stringResource(R.string.routes_missing))
                        else RouteAttribution()
                    }
                    items(routes,key={"route-"+it.teamId}) { route ->
                        Text(observed.teams.teams.find { it.id==route.teamId }?.name ?: route.teamId.take(8),
                            style=MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.routes_totals,route.distanceM/1000.0,kotlin.math.ceil(route.durationS/60.0).toInt()))
                        val date=runCatching { DateFormat.getDateTimeInstance().format(Date.from(Instant.parse(route.calculatedAt))) }
                            .getOrDefault(route.calculatedAt)
                        Text(stringResource(R.string.routes_calculated,route.provider,date))
                        val stops=remember(route) { route.orderedStops() }
                        stops.forEach { stop -> Text(stringResource(R.string.routes_stop,stop.order,
                            stop.code ?: stringResource(R.string.h_pending_code),stop.hydrantId.take(8))) }
                        if(stops.isNotEmpty())TextButton(onClick={mapTeam=route.teamId},enabled=unchanged && !busy && observed.error==null) {
                            Text(stringResource(R.string.routes_map))
                        }
                    }
                    item {
                        OperationalCard {
                            StatusBadge(stringResource(planStatusLabel(d.status)))
                            OutlinedTextField(d.name,{draft=d.copy(name=it.take(120))},enabled=editable,
                                label={Text(stringResource(R.string.plans_name))},singleLine=true,modifier=Modifier.fillMaxWidth())
                        }
                        SectionHeading(stringResource(R.string.teams_title))
                    }
                    items(observed.teams.teams,key={"team-"+it.id}) { t ->
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                            Checkbox(t.id in d.teams,{checked->draft=d.copy(teams=if(checked)d.teams+t.id else d.teams-t.id)},enabled=editable)
                            Text(t.name+" · "+stringResource(if(t.active)R.string.h_active else R.string.h_inactive),modifier=Modifier.weight(1f))
                        }
                    }
                    items((d.teams-observed.teams.teams.map { it.id }.toSet()).sorted(),key={"missing-team-"+it}) { id ->
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                            Checkbox(true,{draft=d.copy(teams=d.teams-id)},enabled=editable)
                            Text(stringResource(R.string.plans_uncached,id),modifier=Modifier.weight(1f))
                        }
                    }
                    item {
                        SectionHeading(stringResource(R.string.plans_hydrants))
                        FieldBanner(stringResource(R.string.plans_frozen))
                        if(observed.candidates.incomplete)FieldBanner(stringResource(R.string.plans_incomplete),FieldTone.WARNING)
                        Text(stringResource(R.string.inspection_due_local))
                        TextButton(onClick={refresh(true)},enabled=editable) { Text(stringResource(R.string.plans_refresh_candidates)) }
                        SelectionMode.entries.forEach { mode ->
                            Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                                RadioButton(d.mode==mode,onClick={
                                    draft=d.copy(mode=mode,hydrants=if(mode==SelectionMode.MANUAL)d.hydrants else observed.candidates.select(mode),
                                        snapshot=planSelectionSnapshot(query,observed.candidates.incomplete))
                                },enabled=editable)
                                Text(stringResource(selectionLabel(mode)),modifier=Modifier.weight(1f))
                            }
                        }
                        if(d.mode!=SelectionMode.MANUAL)TextButton(onClick={
                            draft=d.copy(hydrants=observed.candidates.select(d.mode),snapshot=planSelectionSnapshot(query,observed.candidates.incomplete))
                        },enabled=editable) { Text(stringResource(R.string.plans_reselect)) }
                        Text(stringResource(R.string.plans_count,d.hydrants.size))
                        if(hasPendingHydrants)Text(stringResource(R.string.plans_pending),color=MaterialTheme.colorScheme.error)
                    }
                    val visible=if(d.mode==SelectionMode.MANUAL)observed.candidates.hydrants else observed.candidates.hydrants.filter { it.id in d.hydrants }
                    items(visible,key={"hydrant-"+it.id}) { h ->
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                            if(d.mode==SelectionMode.MANUAL)Checkbox(h.id in d.hydrants,{checked->
                                draft=d.copy(hydrants=if(checked)d.hydrants+h.id else d.hydrants-h.id,
                                    snapshot=planSelectionSnapshot(query,observed.candidates.incomplete))
                            },enabled=editable)
                            Text((h.code ?: stringResource(R.string.h_pending_code))+" · "+h.id.take(8)+
                                if(h.active)"" else " · "+stringResource(R.string.h_inactive),modifier=Modifier.weight(1f))
                        }
                        if(saved!=null && assignmentByHydrant.containsKey(h.id)) {
                            val team=assignmentByHydrant[h.id]?.teamId
                            Text(if(team==null || team !in savedTeams)stringResource(R.string.plans_unassigned)
                                else observed.teams.teams.find { it.id==team }?.name ?: team.take(8))
                        }
                    }
                    items((d.hydrants-observed.candidates.hydrants.map { it.id }.toSet()).sorted(),key={"missing-hydrant-"+it}) { id ->
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                            if(d.mode==SelectionMode.MANUAL)Checkbox(true,{draft=d.copy(hydrants=d.hydrants-id)},enabled=editable)
                            Text(stringResource(R.string.plans_uncached,id),modifier=Modifier.weight(1f))
                        }
                        if(saved!=null && assignmentByHydrant.containsKey(id)) {
                            val team=assignmentByHydrant[id]?.teamId
                            Text(if(team==null || team !in savedTeams)stringResource(R.string.plans_unassigned)
                                else observed.teams.teams.find { it.id==team }?.name ?: team.take(8))
                        }
                    }
                    item {
                        SectionHeading(stringResource(R.string.plans_start))
                        OperationalCard {
                            OutlinedTextField(d.latitude,{draft=d.copy(latitude=it)},enabled=editable,
                                label={Text(stringResource(R.string.h_latitude))},singleLine=true,modifier=Modifier.fillMaxWidth())
                            OutlinedTextField(d.longitude,{draft=d.copy(longitude=it)},enabled=editable,
                                label={Text(stringResource(R.string.h_longitude))},singleLine=true,modifier=Modifier.fillMaxWidth())
                            Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
                                Checkbox(d.returnToStart,{draft=d.copy(returnToStart=it)},enabled=editable)
                                Text(stringResource(R.string.plans_return),modifier=Modifier.weight(1f))
                            }
                        }
                        Spacer(Modifier.height(12.dp))
                        if(d.editable)FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                            SecondaryAction(onClick={submit(PlanStatus.DRAFT)},enabled=editable && !hasPendingHydrants && d.name.isNotBlank()) { Text(stringResource(R.string.plans_save_draft)) }
                            PrimaryAction(onClick={submit(PlanStatus.PLANNED)},enabled=editable && !hasPendingHydrants && d.name.isNotBlank() &&
                                d.teams.isNotEmpty() && d.hydrants.isNotEmpty() &&
                                d.teams.all { id->observed.teams.teams.any { it.id==id && it.active } }) {
                                Text(stringResource(R.string.plans_mark_planned))
                            }
                            if(d.version>0)TextButton(onClick={cancel=true},enabled=editable) { Text(stringResource(R.string.plans_cancel)) }
                        }
                    }
                }
            }
        }
        }
    }
    if(cancel)AlertDialog(onDismissRequest={if(!busy)cancel=false},
        title={Text(stringResource(R.string.plans_cancel))},text={Text(stringResource(R.string.plans_cancel_confirm))},
        confirmButton={TextButton(onClick={submit(PlanStatus.CANCELLED)},enabled=!busy) { Text(stringResource(R.string.plans_cancel)) }},
        dismissButton={TextButton(onClick={cancel=false},enabled=!busy) { Text(stringResource(R.string.h_back)) }})
}
private fun selectionLabel(mode: SelectionMode)=when(mode) {
    SelectionMode.MANUAL->R.string.plans_manual
    SelectionMode.OVERDUE->R.string.inspection_overdue
    SelectionMode.DUE_SOON_AND_OVERDUE->R.string.plans_due
    SelectionMode.ALL->R.string.plans_all
    SelectionMode.CURRENT_FILTER->R.string.plans_filter
}
private fun planStatusLabel(status: PlanStatus)=when(status) {
    PlanStatus.DRAFT->R.string.plans_draft
    PlanStatus.PLANNED->R.string.plans_planned
    PlanStatus.ACTIVE->R.string.h_active
    PlanStatus.COMPLETED->R.string.plans_completed
    PlanStatus.CANCELLED->R.string.plans_cancelled
}

