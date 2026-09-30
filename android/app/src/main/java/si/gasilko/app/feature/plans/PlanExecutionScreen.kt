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
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.presentation.*
import si.gasilko.app.feature.map.MapScreen

@Composable
fun PlanExecutionScreen(model: HydrantViewModel,query: HydrantQuery,initialPlan: String?=null,back: ()->Unit) {
    val registry by model.state.collectAsStateWithLifecycle()
    val flow=remember(model,query) { model.planData(query) }
    val view by flow.collectAsStateWithLifecycle(initialValue=PlanViewData())
    val data=view.data
    val scope=rememberCoroutineScope()
    var planId by remember { mutableStateOf(initialPlan) }
    var teamId by remember { mutableStateOf<String?>(null) }
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
    val teamIds=data.teams.filter { it.active && it.planId==plan?.id && (registry.manages || it.teamId in data.executableTeams) }
        .map { it.teamId }.sorted()
    val selected=teamId?.takeIf { it in teamIds } ?: teamIds.firstOrNull()
    val all=data.items.filter { it.planId==plan?.id && it.active }
    // Without road order, UUID provides a stable display-only list. Never persist a fabricated route.
    val stops=all.filter { it.teamId==selected }.sortedWith(compareBy<PlanItem> { it.inspectionId!=null }
        .thenBy { it.routeOrder ?: Int.MAX_VALUE }.thenBy { it.hydrantId })
    val next=stops.firstOrNull { it.inspectionId==null && it.skipReason==null } ?: stops.firstOrNull { it.inspectionId==null }
    val route=data.routes.find { it.planId==plan?.id && it.teamId==selected && it.valid }
    val routeLabels=remember(route) { route?.orderedStops().orEmpty().associateBy { it.hydrantId } }
    if(map && route!=null && view.error==null) {
        MapScreen(onBack={map=false},hydrants=emptyList(),onOpenHydrant=null,route=route)
        return
    }
    Scaffold { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.execution_title),style=MaterialTheme.typography.headlineSmall)
            Row {
                TextButton(onClick=::leave,enabled=!busy) { Text(stringResource(R.string.h_back)) }
                TextButton(onClick={run { model.refreshPlans(query.organization) }},enabled=!busy) { Text(stringResource(R.string.h_refresh)) }
                TextButton(onClick=model::syncNow,enabled=!busy) { Text(stringResource(R.string.execution_sync)) }
            }
            if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
            (error ?: view.error)?.let { Text(stringResource(errorLabel(it)),color=MaterialTheme.colorScheme.error) }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                if(plan==null) {
                    if(active.isEmpty())item { Text(stringResource(R.string.execution_empty)) }
                    items(active,key={it.id}) { p ->
                        OutlinedButton(onClick={planId=p.id;teamId=null},enabled=!busy) { Text(p.name) }
                    }
                } else {
                    item {
                        Text(plan.name,style=MaterialTheme.typography.titleLarge)
                        ExecutionProgress(all)
                        TextButton(onClick={planId=null;teamId=null},enabled=!busy) { Text(stringResource(R.string.plans_title)) }
                    }
                    items(teamIds,key={"team-"+it}) { id ->
                        OutlinedButton(onClick={teamId=id},enabled=!busy) {
                            Text((if(selected==id)"✓ " else "")+(view.teams.teams.find { it.id==id }?.name ?: id.take(8)))
                        }
                        ExecutionProgress(all.filter { it.teamId==id })
                    }
                    item {
                        if(route!=null)TextButton(onClick={map=true},enabled=!busy) { Text(stringResource(R.string.routes_map)) }
                        else Text(stringResource(R.string.execution_no_route))
                        if(registry.manages)TextButton(onClick={run {
                            val request=routeRequest ?: PlanRouting(plan.id,plan.version,remaining=true).also { routeRequest=it }
                            model.routePlan(query.organization,request);routeRequest=null
                        }},enabled=!busy) { Text(stringResource(R.string.execution_reroute)) }
                        if(all.any { it.id in data.pendingItems })Text(stringResource(R.string.execution_pending))
                    }
                    items(stops,key={it.id}) { item ->
                        val completed=item.inspectionId!=null
                        val skipped=!completed && item.skipReason!=null
                        Card(colors=CardDefaults.cardColors(containerColor=when {
                            completed->MaterialTheme.colorScheme.secondaryContainer
                            skipped->MaterialTheme.colorScheme.tertiaryContainer
                            else->MaterialTheme.colorScheme.surfaceVariant })) {
                            Column(Modifier.padding(12.dp)) {
                                if(item.id==next?.id)Text(stringResource(R.string.execution_next),style=MaterialTheme.typography.titleMedium)
                                val code=view.candidates.hydrants.find { it.id==item.hydrantId }?.code
                                    ?: routeLabels[item.hydrantId]?.code ?: item.hydrantId.take(8)
                                Text((item.routeOrder?.toString()?.plus(". ") ?: "")+code)
                                Text(stringResource(if(completed)R.string.execution_completed else if(skipped)R.string.execution_skipped else R.string.execution_open))
                                item.skipReason?.let { Text(it) }
                                if(item.id in data.attentionItems)Text(stringResource(R.string.execution_attention),color=MaterialTheme.colorScheme.error)
                                else if(item.id in data.pendingItems)Text(stringResource(R.string.execution_pending_short))
                                Row {
                                    TextButton(onClick={run { model.openPlanStop(query.organization,plan.id,item.id) }},enabled=!busy) {
                                        Text(stringResource(R.string.h_details))
                                    }
                                    if(!completed)TextButton(onClick={skipping=item;reason="";skipRequest=null},enabled=!busy) {
                                        Text(stringResource(R.string.execution_skip))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
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
    Text(stringResource(R.string.execution_progress,completed,items.size,items.size-completed,
        items.count { it.inspectionId==null && it.skipReason!=null }))
}
