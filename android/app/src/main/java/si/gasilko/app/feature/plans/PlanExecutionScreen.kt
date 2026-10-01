package si.gasilko.app.feature.plans

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.*
import si.gasilko.app.feature.map.MapScreen
import si.gasilko.app.feature.map.navigation.NavigationScreen
import si.gasilko.app.feature.photos.presentation.PermanentHydrantPhoto
import si.gasilko.app.feature.photos.presentation.ApproachHydrantPhoto

@Composable
@OptIn(ExperimentalLayoutApi::class)
fun PlanExecutionScreen(model: HydrantViewModel,query: HydrantQuery,initialPlan: String?=null,back: ()->Unit) {
    val registry by model.state.collectAsStateWithLifecycle()
    val navigation by model.navigation.state.collectAsStateWithLifecycle()
    val flow=remember(model,query) { model.planData(query) }
    val view by flow.collectAsStateWithLifecycle(initialValue=PlanViewData())
    val data=view.data
    val scope=rememberCoroutineScope()
    val online=planNetworkAvailable()
    var reassigning by remember { mutableStateOf<PlanItem?>(null) }
    var historyItem by remember { mutableStateOf<String?>(null) }
    var planId by remember { mutableStateOf(navigation.plan.takeIf { navigation.active } ?: initialPlan) }
    var teamId by remember { mutableStateOf(navigation.team.takeIf { navigation.active }) }
    var map by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<RegistryError?>(null) }
    var skipping by remember { mutableStateOf<PlanItem?>(null) }
    var reason by remember { mutableStateOf("") }
    var skipRequest by remember { mutableStateOf<PlanSkip?>(null) }
    var routeRequest by remember { mutableStateOf<PlanRouting?>(null) }
    fun run(action: suspend ()->Unit) {
        if(busy)return
        busy=true;error=null
        scope.launch { try { action() } catch(e: CancellationException) { throw e }
            catch(e: Exception) {
                error=(e as? RegistryFailure)?.reason ?: RegistryError.SERVER
                if(error in listOf(RegistryError.CONFLICT,RegistryError.VALIDATION))routeRequest=null
            }
            finally { busy=false } }
    }
    fun leave() { if(!busy) { if(map)map=false else { model.leaveExecution();back() } } }
    BackHandler(onBack=::leave)
    LaunchedEffect(query.organization) { run { model.refreshPlans(query.organization) } }
    val active=data.plans.filter { p -> p.status=="ACTIVE" && (registry.manages ||
        data.teams.any { it.planId==p.id && it.active && it.teamId in data.executableTeams }) }
    val plan=active.find { it.id==planId }
    val teamIds=data.teams.filter { it.active && it.planId==plan?.id }
        .map { it.teamId }.sorted()
    val selected=teamId?.takeIf { it in teamIds } ?: teamIds.firstOrNull { it in data.executableTeams } ?: teamIds.firstOrNull()
    val canExecute=registry.manages || selected in data.executableTeams
    fun destinations(item: PlanItem)=view.teams.teams.filter { team -> team.active && team.id in teamIds && team.id!=item.teamId &&
        (registry.manages || item.teamId in data.executableTeams || team.id in data.executableTeams) }.sortedBy { it.id }
    val all=data.items.filter { it.planId==plan?.id && it.active }
    // Without road order, UUID provides a stable display-only list. Never persist a fabricated route.
    val stops=all.filter { it.teamId==selected }.sortedWith(compareBy<PlanItem> { it.inspectionId!=null }
        .thenBy { it.routeOrder ?: Int.MAX_VALUE }.thenBy { it.hydrantId })
    val next=stops.firstOrNull { it.inspectionId==null && it.skipReason==null } ?: stops.firstOrNull { it.inspectionId==null }
    val route=data.routes.find { it.planId==plan?.id && it.teamId==selected }
    LaunchedEffect(plan?.id,selected,route?.valid) { if(route==null)map=false }
    val remaining=stops.filter { it.inspectionId==null }.map { it.id }.toSet()
    val navigationReady=route?.valid==true && stops.none { it.id in data.pendingItems } &&
        data.reassignmentRequests.none { it.context.planId==plan?.id }
    LaunchedEffect(plan,selected,route,remaining,navigationReady,view.error,canExecute) {
        if(navigation.active) {
            if(navigation.organization!=query.organization || view.error in listOf(RegistryError.EXPIRED,RegistryError.FORBIDDEN) ||
                (!registry.manages && data.plans.any { it.id==navigation.plan } && navigation.team !in data.executableTeams) ||
                (data.plans.any { it.id==navigation.plan && it.status!="ACTIVE" }) ||
                (plan!=null && (navigation.plan!=plan.id || navigation.team!=selected || !canExecute)))model.navigation.stop()
            else if(plan!=null)model.navigation.updatePlan(plan.version,route?.calculatedAt.orEmpty(),navigationReady,remaining)
        }
    }
    if(navigation.active && plan!=null && navigation.plan==plan.id && navigation.team==selected && canExecute && view.error==null) {
        NavigationScreen(model.navigation,view.candidates.hydrants.filter { h -> stops.any { it.hydrantId==h.id } },stops,route,
            onOpen={id -> stops.find { it.hydrantId==id }?.let { item -> run { model.openPlanStop(query.organization,plan.id,item.id) } } },
            canOpen={id -> !busy && stops.any { it.hydrantId==id && data.reassignmentRequests.none { r -> r.context.itemId==it.id } } },
            photo={h -> PermanentHydrantPhoto(model,h.organization,h.id)},
            targetPhoto={h,visible,expanded -> ApproachHydrantPhoto(model,h.organization,h.id,visible,expanded)})
        return
    }
    val routeLabels=remember(route) { route?.orderedStops().orEmpty().associateBy { it.hydrantId } }
    if(map && route!=null && view.error==null) {
        MapScreen(onBack={map=false},
            hydrants=view.candidates.hydrants.filter { h -> stops.any { it.hydrantId==h.id } },
            onOpenHydrant={ id -> stops.find { it.hydrantId==id }?.let { item ->
                if(canExecute && !busy && data.reassignmentRequests.none { it.context.itemId==item.id })
                    run { model.openPlanStop(query.organization,item.planId,item.id) }
            } },route=route,completedHydrants=stops.filter { it.inspectionId!=null }.map { it.hydrantId }.toSet(),routeHydrantIds=stops.map { it.hydrantId }.toSet(),
            completedRouteNumbers=stops.filter { it.inspectionId!=null && it.routeOrder!=null }.associate { it.hydrantId to it.routeOrder!! },
            canOpenHydrant={ id -> canExecute && !busy && stops.any { item ->
                item.hydrantId==id && data.reassignmentRequests.none { it.context.itemId==item.id }
            } },
            photoPreview={ h -> PermanentHydrantPhoto(model,h.organization,h.id) })
        return
    }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            ScreenHeading(stringResource(R.string.execution_title))
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                TextButton(onClick=::leave,enabled=!busy) { Text(stringResource(R.string.h_back)) }
                TextButton(onClick={run { model.refreshPlans(query.organization) }},enabled=!busy) { Text(stringResource(R.string.h_refresh)) }
                TextButton(onClick=model::syncNow,enabled=!busy) { Text(stringResource(R.string.execution_sync)) }
            }
            if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
            (error ?: view.error)?.let { FieldBanner(stringResource(errorLabel(it)),FieldTone.DANGER) }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                if(plan==null) {
                    if(active.isEmpty())item { Text(stringResource(R.string.execution_empty)) }
                    items(active,key={it.id}) { p ->
                        SecondaryAction(onClick={planId=p.id;teamId=null},enabled=!busy,modifier=Modifier.fillMaxWidth()) { Text(p.name) }
                    }
                } else {
                    item {
                        SectionHeading(plan.name)
                        ExecutionProgress(all)
                        TextButton(onClick={planId=null;teamId=null;routeRequest=null},enabled=!busy) { Text(stringResource(R.string.plans_title)) }
                        if(!online)FieldBanner(stringResource(R.string.reassign_offline),FieldTone.WARNING)
                    }
                    items(teamIds,key={"team-"+it}) { id ->
                        SecondaryAction(onClick={teamId=id;routeRequest=null},enabled=!busy,modifier=Modifier.fillMaxWidth()) {
                            Text((if(selected==id)"✓ " else "")+(view.teams.teams.find { it.id==id }?.name ?: id.take(8)))
                        }
                        ExecutionProgress(all.filter { it.teamId==id })
                    }
                    item {
                        if(canExecute)TextButton(onClick={selected?.let { team ->
                            model.startNavigation(query.organization,plan.id,team,plan.version,route?.calculatedAt.orEmpty())
                        }},enabled=!busy && online && navigationReady && remaining.isNotEmpty()) { Text(stringResource(R.string.nav_start)) }
                        if(route?.valid==false)FieldBanner(stringResource(R.string.routes_stale),FieldTone.WARNING)
                        if(route!=null)TextButton(onClick={map=true},enabled=!busy) { Text(stringResource(R.string.routes_map)) }
                        else FieldBanner(stringResource(R.string.execution_no_route))
                        if(canExecute)TextButton(onClick={run {
                            val request=routeRequest ?: PlanRouting(plan.id,plan.version,remaining=true,teamId=selected).also { routeRequest=it }
                            model.routePlan(query.organization,request);routeRequest=null
                        }},enabled=!busy && online) { Text(stringResource(R.string.execution_reroute)) }
                        if(all.any { it.id in data.pendingItems })FieldBanner(stringResource(R.string.execution_pending),FieldTone.WARNING)
                        data.reassignmentRequests.filter { it.context.planId==plan.id }.forEach { request ->
                            Text(stringResource(R.string.reassign_pending))
                            Text((view.teams.teams.find { it.id==request.fromTeam }?.name ?: request.fromTeam)+" → "+
                                (view.teams.teams.find { it.id==request.toTeam }?.name ?: request.toTeam))
                            Text(request.reason)
                            TextButton(onClick={run { model.reassignPlanItem(query.organization,request) }},enabled=!busy && online) {
                                Text(stringResource(R.string.reassign_retry,request.context.itemId.take(8)))
                            }
                        }
                    }
                    items(stops,key={it.id}) { item ->
                        val completed=item.inspectionId!=null
                        val skipped=!completed && item.skipReason!=null
                        val uncertain=data.reassignmentRequests.any { it.context.itemId==item.id }
                        val history=data.reassignments.filter { it.itemId==item.id }
                        OperationalCard(emphasized=item.id==next?.id) {
                                if(item.id==next?.id)StatusBadge(stringResource(R.string.execution_next),FieldTone.INFO)
                                val code=view.candidates.hydrants.find { it.id==item.hydrantId }?.code
                                    ?: routeLabels[item.hydrantId]?.code ?: item.hydrantId.take(8)
                                Text((item.routeOrder?.toString()?.plus(". ") ?: "")+code,style=MaterialTheme.typography.titleLarge)
                                Text(stringResource(R.string.reassign_current_team,view.teams.teams.find { it.id==item.teamId }?.name ?: item.teamId.orEmpty()))
                                if(history.isNotEmpty())Text(stringResource(R.string.reassign_changed))
                                StatusBadge(stringResource(if(completed)R.string.execution_completed else if(skipped)R.string.execution_skipped else R.string.execution_open),
                                    if(completed)FieldTone.SUCCESS else if(skipped)FieldTone.WARNING else FieldTone.NEUTRAL)
                                item.skipReason?.let { Text(it) }
                                if(item.id in data.attentionItems)FieldBanner(stringResource(R.string.execution_attention),FieldTone.WARNING)
                                else if(item.id in data.pendingItems)StatusBadge(stringResource(R.string.execution_pending_short),FieldTone.WARNING)
                                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                                    if(canExecute)TextButton(onClick={run { model.openPlanStop(query.organization,plan.id,item.id) }},enabled=!busy && !uncertain) {
                                        Text(stringResource(R.string.h_details))
                                    }
                                    if(!completed && canExecute)TextButton(onClick={skipping=item;reason="";skipRequest=null},enabled=!busy && !uncertain) {
                                        Text(stringResource(R.string.execution_skip))
                                    }
                                }
                                if(!completed && destinations(item).isNotEmpty())TextButton(onClick={reassigning=item},
                                    enabled=!busy && online && !uncertain && item.id !in data.pendingItems) {
                                    Text(stringResource(if(canExecute)R.string.reassign_transfer else R.string.reassign_take))
                                }
                                TextButton(onClick={historyItem=item.id},enabled=!busy) { Text(stringResource(R.string.reassign_history)) }
                        }
                    }
                }
            }
        }
    }
    reassigning?.let { item ->
        ReassignmentDialog(item,destinations(item),busy,online,{ request ->
            reassigning=null
            run { model.reassignPlanItem(query.organization,request) }
        },{reassigning=null},currentTeam=view.teams.teams.find { it.id==item.teamId }?.name ?: item.teamId.orEmpty())
    }
    historyItem?.let { id -> all.find { it.id==id }?.let { item ->
        ReassignmentHistory(item,data.reassignments.filter { it.itemId==id },view.teams.teams) { historyItem=null }
    } }
    skipping?.let { item -> AlertDialog(onDismissRequest={if(!busy)skipping=null},
        title={Text(stringResource(R.string.execution_skip))},
        text={OutlinedTextField(reason,{reason=it.take(2000)},enabled=!busy && skipRequest==null,
            label={Text(stringResource(R.string.execution_skip_reason))})},
        confirmButton={TextButton(onClick={run {
            val request=skipRequest ?: PlanSkip(item.context(),reason).also { skipRequest=it }
            model.skipPlanItem(query.organization,request);skipping=null;skipRequest=null
        }},enabled=!busy && reason.isNotBlank()) { Text(stringResource(R.string.execution_skip)) }},
        dismissButton={TextButton(onClick={skipping=null;skipRequest=null},enabled=!busy) { Text(stringResource(R.string.h_back)) }})
    }
}
@Composable private fun ExecutionProgress(items: List<PlanItem>) {
    val completed=items.count { it.inspectionId!=null }
    OperationalCard {
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
            Metric("$completed / ${items.size}",stringResource(R.string.execution_completed),FieldTone.SUCCESS,Modifier.weight(1f))
            Metric((items.size-completed).toString(),stringResource(R.string.ui_remaining),FieldTone.NEUTRAL,Modifier.weight(1f))
            Metric(items.count { it.inspectionId==null && it.skipReason!=null }.toString(),stringResource(R.string.ui_skipped),FieldTone.WARNING,Modifier.weight(1f))
        }
        LinearProgressIndicator(progress={if(items.isEmpty())0f else completed.toFloat()/items.size},modifier=Modifier.fillMaxWidth(),
            color=MaterialTheme.operations.success,trackColor=MaterialTheme.colorScheme.surfaceVariant)
    }
}
