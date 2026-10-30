package si.gasilko.app.feature.incidents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.serialization.json.*
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import si.gasilko.app.feature.hydrants.presentation.HydrantViewModel
import si.gasilko.app.feature.map.domain.GeoPoint
import java.util.UUID
import java.text.DateFormat
import java.util.Date

@Composable internal fun label(row: JsonObject): String {
    val de=LocalConfiguration.current.locales[0].language=="de"
    return row.text(if(de)"label_de" else "label_sl")
}
@Composable internal fun stateName(value: String)=stringResource(when(value) {
    "ISSUED"->R.string.field_issued
    "ACKNOWLEDGED"->R.string.field_acknowledged
    "IN_PROGRESS"->R.string.field_in_progress
    "BLOCKED"->R.string.field_blocked
    "COMPLETED"->R.string.field_completed
    "UNABLE"->R.string.field_unable
    "CANCELLED"->R.string.field_cancelled
    "LOCAL_PENDING"->R.string.field_pending
    "SENDING"->R.string.field_sending
    "SERVER_CONFIRMED"->R.string.field_confirmed
    "OUTCOME_UNKNOWN"->R.string.field_uncertain
    "NEEDS_ATTENTION"->R.string.field_attention
    else->R.string.field_status
})
@Composable private fun actionName(value: String)=stringResource(when(value) {
    "ACKNOWLEDGED"->R.string.field_ack
    "IN_PROGRESS"->R.string.field_start_resume
    "BLOCKED"->R.string.field_block
    "COMPLETED"->R.string.field_complete
    else->R.string.field_cannot
})
private fun point(geometry: JsonObject): GeoPoint? {
    if(geometry.text("type")!="Point")return null
    val coordinates=geometry["coordinates"] as? JsonArray ?: return null
    val lon=coordinates.getOrNull(0)?.jsonPrimitive?.doubleOrNull ?: return null
    val lat=coordinates.getOrNull(1)?.jsonPrimitive?.doubleOrNull ?: return null
    return GeoPoint(lat,lon).takeIf { it.valid }
}
@Composable
@OptIn(ExperimentalLayoutApi::class)
fun IncidentScreen(model: IncidentViewModel,registry: HydrantViewModel,organizationName: String,initialIncident: String?,navigationEvent: Long,back: ()->Unit) {
    val data by model.state.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val error by model.error.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val syncFailure by model.syncFailure.collectAsStateWithLifecycle()
    val syncMessage=when(syncFailure) {
            "ACCESS","SCOPE" -> R.string.field_sync_scope
            "MANIFEST" -> R.string.field_sync_manifest
            "CAPACITY" -> R.string.field_sync_capacity
            "PROTOCOL" -> R.string.field_sync_protocol
            "BUSY" -> R.string.field_sync_busy
            "NETWORK" -> R.string.field_sync_network
            "SERVER" -> R.string.field_sync_server
            else -> R.string.field_stale
        }
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(model,lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.foreground() } }
    var incidentId by remember(model,navigationEvent) { mutableStateOf(initialIncident) }
    var assignmentId by remember(model,navigationEvent) { mutableStateOf<String?>(null) }
    var filter by remember(model,navigationEvent) { mutableIntStateOf(0) }
    var unitTab by remember(model,navigationEvent,incidentId) { mutableStateOf(false) }
    var issue by remember(model,navigationEvent,incidentId) { mutableStateOf(false) }
    var commandUnit by remember(model,navigationEvent,incidentId) { mutableStateOf<String?>(null) }
    var messages by remember(model,navigationEvent,incidentId) { mutableStateOf(false) }
    var evidence by remember(model,navigationEvent,incidentId) { mutableStateOf<EvidenceTarget?>(null) }
    var incidentMap by remember(model,navigationEvent,incidentId) { mutableStateOf(false) }
    var mapAssignment by remember(model,navigationEvent,incidentId) { mutableStateOf<String?>(null) }
    val mapStates=rememberSaveableStateHolder()
    val assignmentScroll=rememberSaveable(model,incidentId,assignmentId,saver=LazyListState.Saver){LazyListState()}
    val incident=data.incidents.find { it.text("id")==incidentId }
    val assignment=incident?.rows("assignments")?.find { it.text("id")==assignmentId }
    fun close() { when { evidence!=null->evidence=null;messages->messages=false;incidentMap->incidentMap=false;issue->issue=false;assignmentId!=null->assignmentId=null;commandUnit!=null->commandUnit=null;incidentId!=null->incidentId=null;else->back() } }
    BackHandler(onBack=::close)
    if(data.locked) {
        Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            ScreenHeading(stringResource(R.string.field_title))
            FieldBanner(stringResource(R.string.field_locked),FieldTone.WARNING)
            if(syncFailure!=null)FieldBanner(stringResource(syncMessage),FieldTone.WARNING)
            TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
            TextButton(onClick=model::sync) { Text(stringResource(R.string.h_sync_now)) }
        }
        return
    }
    if(evidence!=null && incident!=null) {
        key(model,incidentId,evidence) { IncidentEvidenceScreen(model,incident.text("id"),evidence!!) { evidence=null } }
        return
    }
    if(messages && incident!=null) {
        key(model,incident.text("id"),incident.text("message_access"),incident.obj("message_page").text("_cache_generation")) {
            IncidentMessagesScreen(model,incident) { messages=false }
        }
        return
    }
    if(incidentMap && incident!=null) {
        key(model,incidentId) { mapStates.SaveableStateProvider("map/"+model.repository.account+"/"+model.organization+"/"+incident.text("id")) {
            IncidentMapScreen(model,registry,incident.text("id"),mapAssignment,
                {id->assignmentId=id;incidentMap=false},{incidentMap=false})
        } }
        return
    }
    val selectedUnit=incident?.rows("units")?.find { it.text("id")==commandUnit }
    if(issue && incident!=null && selectedUnit!=null && isCurrentLeader(incident,selectedUnit)) {
        key(model,navigationEvent,incidentId,commandUnit,leaderStamp(selectedUnit)) {
            IssueTask(model,registry,incident,selectedUnit,busy) { issue=false }
        }
        return
    }
    if(commandUnit!=null && incident!=null && assignment==null) {
        mapStates.SaveableStateProvider("unit/"+model.repository.account+"/"+model.organization+"/"+incident.text("id")+"/"+commandUnit) {
            UnitLeadershipScreen(model,incident.text("id"),commandUnit!!,{assignmentId=it},
                {issue=true;model.loadCatalog()},{id->mapAssignment=id;incidentMap=true},
                {commandUnit=null;assignmentId=null;issue=false})
        }
        return
    }
    Column(Modifier.fillMaxSize().padding(horizontal=16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(onClick=::close) { Text(stringResource(R.string.h_back)) }
            TextButton(onClick=model::sync,enabled=!busy) { Text(stringResource(R.string.h_sync_now)) }
        }
        ScreenHeading(stringResource(R.string.field_title))
        Text(organizationName)
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        if(error)FieldBanner(stringResource(R.string.field_error),FieldTone.WARNING)
        if(stale || syncFailure!=null)FieldBanner(stringResource(syncMessage),FieldTone.WARNING)
        if(data.warning)FieldBanner(stringResource(R.string.field_lease_warning),FieldTone.WARNING)
        data.verifiedAt?.let { Text(stringResource(R.string.field_verified,DateFormat.getDateTimeInstance().format(Date(it))),style=MaterialTheme.typography.bodySmall) }
        if(incidentId!=null && incident==null)FieldBanner(stringResource(R.string.field_unavailable),FieldTone.WARNING)
        if(incident==null) {
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                listOf(R.string.field_active,R.string.field_mine,R.string.field_unit,R.string.field_history,R.string.field_training).forEachIndexed { index,id ->
                    FilterChip(selected=filter==index,onClick={filter=index},label={Text(stringResource(id))})
                }
            }
            val rows=data.incidents.filter { i->when(filter) {
                0->i.text("status") in listOf("ACTIVE","STABILIZED")
                1->i.rows("assignments").any { it.flag("mine") }
                2->i.rows("units").isNotEmpty()
                3->i.text("status") in listOf("CLOSED","CANCELLED") || i.rows("assignments").any { it.text("status") in terminal }
                else->i.text("mode")=="TRAINING"
            } }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                if(rows.isEmpty())item { Text(stringResource(R.string.field_empty)) }
                items(rows,key={it.text("id")}) { i ->
                    OutlinedCard(onClick={incidentId=i.text("id")},modifier=Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                            Text(i.text("reference"),style=MaterialTheme.typography.titleLarge)
                            Text(i.text("title"))
                            StatusBadge(i.text("mode"),if(i.text("mode")=="TRAINING")FieldTone.WARNING else FieldTone.INFO)
                            Text(i.text("status"))
                            Text(stringResource(R.string.field_outstanding,i.rows("assignments").count { it.text("status") !in terminal }))
                        }
                    }
                }
            }
        } else if(assignment!=null) {
            val task=assignment.obj("task")
            val config=task.obj("configuration")
            val operations=data.operations.filter { it.operation.entityId==assignment.text("id") }
            val last=operations.lastOrNull()
            val pending=last?.takeIf { it.operation.state!="SERVER_CONFIRMED" || unreconciledReceipt(assignment,it) }
            val effective=pending?.let { parse(it.operation.payload).obj("payload").text("status") } ?: assignment.text("status")
            var desired by remember(model,navigationEvent,incidentId,assignmentId) { mutableStateOf<String?>(null) }
            var reason by remember(desired) { mutableStateOf("") }
            LazyColumn(Modifier.weight(1f),state=assignmentScroll,verticalArrangement=Arrangement.spacedBy(12.dp)) {
                item { Text(incident.text("title"));Text(label(config),style=MaterialTheme.typography.headlineSmall)
                    Text(task.text("title"));Text(task.text("notes"))
                    TextButton(onClick={evidence=EvidenceTarget("TASK",task.text("id"))}) { Text(stringResource(R.string.ev_title)) }
                    Text(config.text(if(LocalConfiguration.current.locales[0].language=="de")"description_de" else "description_sl"))
                    Text(assignment.text("id"),style=MaterialTheme.typography.bodySmall)
                    Text(assignment.text("recipient_name"));Text(task.text("issuer_name"));Text(task.text("issued_at"))
                    Text(task.text("priority"));StatusBadge(stateName(assignment.text("status")),FieldTone.INFO)
                    if(config.flag("requires_acknowledgement"))Text(stringResource(R.string.field_ack_required))
                    config.rows("parameter_definitions").forEach { d ->
                        Text(label(d)+": "+(task.obj("parameters")[d.text("code")]?.toString().orEmpty()))
                    }
                    Text(task.text("target_label_snapshot"))
                    OutlinedButton(onClick={mapAssignment=assignment.text("id");incidentMap=true}) { Text(stringResource(R.string.im_show_target)) }
                }
                items(operations,key={it.operation.operationId}) { op ->
                    Text(stringResource(R.string.field_recorded_action,stateName(parse(op.operation.payload).obj("payload").text("status"))))
                    FieldBanner(stateName(op.operation.state),if(op.operation.state=="SERVER_CONFIRMED")FieldTone.SUCCESS else FieldTone.WARNING)
                    if(op.error=="DEPENDENCY_CHANGED")Text(stringResource(R.string.field_dependency_changed))
                    if(op.error=="RECOVERY_REJECTED")Text(stringResource(R.string.field_recovery_denied))
                }
                if(assignment.flag("can_execute") && pending?.operation?.state!="NEEDS_ATTENTION")item {
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        transitions(effective,config.flag("requires_acknowledgement")).forEach { status ->
                            Button(onClick={desired=status},enabled=!busy,modifier=Modifier.heightIn(min=56.dp)) { Text(actionName(status)) }
                        }
                    }
                }
                item { SectionHeading(stringResource(R.string.field_history)) }
                items(incident.rows("history").filter { h ->
                    h.obj("data").text("task_assignment_id")==assignmentId ||
                        (h.obj("data").text("task_assignment_id").isEmpty() && h.obj("data").text("task_id")==task.text("id"))
                },key={it.text("sequence")}) { h ->
                    Text(h.text("code"));Text(h.text("recorded_at"));Text(h.obj("data").text("reason"))
                }
            }
            desired?.let { status ->
                AlertDialog(onDismissRequest={if(!busy)desired=null},title={Text(actionName(status))},
                    text={Column {
                        Text(stringResource(R.string.field_explicit))
                        OutlinedTextField(reason,{reason=it.take(2000)},label={Text(stringResource(R.string.field_reason))},modifier=Modifier.fillMaxWidth())
                    }},confirmButton={TextButton(enabled=!busy && (status !in listOf("BLOCKED","UNABLE") || reason.isNotBlank()),onClick={
                        model.transition(incident.text("id"),assignment.text("id"),status,reason);desired=null
                    }) { Text(stringResource(R.string.field_confirm)) }},
                    dismissButton={TextButton(onClick={desired=null}) { Text(stringResource(R.string.h_back)) }})
            }
        } else {
            Text(incident.text("reference")+" · "+incident.text("title"),style=MaterialTheme.typography.titleLarge)
            TextButton(onClick={messages=true}) { Text(stringResource(R.string.mc_title)) }
            TextButton(onClick={evidence=EvidenceTarget("INCIDENT",null)}) { Text(stringResource(R.string.ev_title)) }
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                FilterChip(selected=!unitTab,onClick={unitTab=false},label={Text(stringResource(R.string.field_orders))})
                FilterChip(selected=unitTab,onClick={unitTab=true},label={Text(stringResource(R.string.field_unit))})
                TextButton(onClick={mapAssignment=null;incidentMap=true}) { Text(stringResource(R.string.field_map)) }
            }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp),contentPadding=PaddingValues(bottom=24.dp)) {
                if(unitTab) {
                    items(incident.rows("units"),key={it.text("id")}) { unit ->
                        OperationalCard {
                            SectionHeading(unit.text("name"));Text(unit.text("status"));Text(unit.text("leader_name"))
                            unit.rows("crew").forEach { c->Text(c.text("name")+" · "+c.text("role")) }
                            OutlinedButton(onClick={commandUnit=unit.text("id")}) { Text(stringResource(R.string.ul_title)) }
                            val tasks=incident.rows("assignments").filter { it.text("unit_id")==unit.text("id") }
                            Text(stringResource(R.string.field_outstanding,tasks.count { it.text("status") !in terminal }))
                            if(unit.flag("leader") && unit.rows("crew").any { it.flag("can_issue") })
                                Button(onClick={commandUnit=unit.text("id");issue=true;model.loadCatalog()},enabled=!busy) { Text(stringResource(R.string.field_issue)) }
                        }
                    }
                }
                val rows=incident.rows("assignments").filter { unitTab || it.flag("mine") || it.flag("can_execute") }
                    .sortedWith(compareBy<JsonObject> {
                        when {
                            it.text("status")=="ISSUED"->0
                            data.operations.any { op->op.operation.entityId==it.text("id") && op.operation.state=="NEEDS_ATTENTION" }->1
                            else->when(it.text("status")) {"BLOCKED"->1;"IN_PROGRESS"->2;"ACKNOWLEDGED"->3;else->4 } }
                    }.thenBy { it.text("id") })
                if(rows.isEmpty())item { Text(stringResource(R.string.field_no_orders)) }
                items(rows,key={it.text("id")}) { a ->
                    OutlinedCard(onClick={assignmentId=a.text("id")},modifier=Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                            Text(label(a.obj("task").obj("configuration")),style=MaterialTheme.typography.titleLarge)
                            Text(a.obj("task").text("title"));Text(a.text("recipient_name"))
                            Text(a.obj("task").text("issuer_name"));Text(a.obj("task").text("priority"))
                            Text(a.obj("task").text("issued_at"));Text(a.obj("task").text("target_label_snapshot"))
                            StatusBadge(stateName(a.text("status")),FieldTone.INFO)
                            if(a.obj("task").obj("configuration").flag("requires_acknowledgement"))Text(stringResource(R.string.field_ack_required))
                            data.operations.lastOrNull { it.operation.entityId==a.text("id") }?.let { op->Text(stateName(op.operation.state)) }
                        }
                    }
                }
                // Scoped manual proposals/receipts and same-ID retries are shown in My unit.

            }
        }
    }
}

@Composable internal fun Selector(title: String,value: String,options: List<Pair<String,String>>,enabled: Boolean=true,select: (String)->Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick={expanded=true},enabled=enabled,modifier=Modifier.fillMaxWidth()) { Text(title+": "+(options.find { it.first==value }?.second.orEmpty())) }
        DropdownMenu(expanded=expanded && enabled,onDismissRequest={expanded=false}) {
            options.forEach { (id,name)->DropdownMenuItem(text={Text(name)},onClick={expanded=false;select(id)}) }
        }
    }
}

@Composable private fun IssueTask(model: IncidentViewModel,registry: HydrantViewModel,incident: JsonObject,unit: JsonObject,busy: Boolean,back: ()->Unit) {
    val catalog by model.catalog.collectAsStateWithLifecycle()
    val fieldState by model.state.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val commandError by model.commandError.collectAsStateWithLifecycle()
    var reviewOperation by remember { mutableStateOf<String?>(null) }
    val alive=remember { booleanArrayOf(true) }
    DisposableEffect(Unit) { onDispose {alive[0]=false} }
    val error by model.error.collectAsStateWithLifecycle()
    val pendingProposal=fieldState.operations.lastOrNull { op->
        val body=parse(op.operation.payload)
        body.text("rpc")=="incident_issue_task" && body.text("incident")==incident.text("id") &&
            body.text("unit")==unit.text("id") && body.text("leader")==leaderStamp(unit) &&
            op.operation.state in listOf("DRAFT","LOCAL_PENDING","SENDING","OUTCOME_UNKNOWN")
    }
    var resumedOperation by remember { mutableStateOf(pendingProposal?.operation?.operationId) }
    val durableReview=fieldState.operations.find { it.operation.operationId==resumedOperation } ?: pendingProposal
    if(durableReview!=null) {
        SideEffect {resumedOperation=durableReview.operation.operationId}
        Column(Modifier.padding(16.dp)) {
            TextButton(onClick=back,enabled=!busy){Text(stringResource(R.string.h_back))}
            FieldBanner(stringResource(R.string.field_review_frozen))
        }
        LeaderReview(model,incident,unit,durableReview,busy,stale,back)
        return // Never allocate replacement task/operation UUIDs on resumed submission.
    }
    var crew by remember { mutableStateOf("") }
    var definition by remember { mutableStateOf("") }
    var title by remember { mutableStateOf("") }
    var notes by remember { mutableStateOf("") }
    var targetKind by remember(definition) { mutableStateOf("") }
    var latitude by remember { mutableStateOf("") }
    var longitude by remember { mutableStateOf("") }
    var targetId by remember(definition,targetKind) { mutableStateOf("") }
    val hydrantQuery=remember(model.organization) { si.gasilko.app.feature.hydrants.domain.HydrantQuery(organization=model.organization) }
    val hydrantFlow=remember(registry,hydrantQuery) { registry.mapHydrants(hydrantQuery) }
    val hydrantData by hydrantFlow.collectAsStateWithLifecycle(initialValue=si.gasilko.app.feature.hydrants.presentation.MapHydrantsState())
    var values by remember(definition) { mutableStateOf<Map<String,String>>(emptyMap()) }
    var review by remember { mutableStateOf<JsonObject?>(null) }
    var reviewedRow by remember { mutableStateOf<JsonObject?>(null) }
    var reviewedRecipients by remember { mutableStateOf<List<Pair<String,String>>?>(null) }
    var reviewedTargets by remember { mutableStateOf<List<Pair<String,String>>?>(null) }
    val operation=remember { UUID.randomUUID().toString() }
    val taskId=remember { UUID.randomUUID().toString() }
    val assignmentId=remember { UUID.randomUUID().toString() }
    val selectedRow=reviewedRow ?: catalog.find { it.text("id")==definition }
    val actionVersionId=catalogVersion(selectedRow)
    val selected=selectedRow?.obj("configuration")
    val recipientOptions=reviewedRecipients ?: listOf(unit).flatMap { u ->
        u.rows("crew").filter { it.flag("can_issue") && it.text("status")=="ACTIVE" }
            .map { it.text("id") to (u.text("name")+" · "+it.text("name")) }
    }
    val targets=selected?.get("target_types")?.jsonArray.orEmpty().map { it.jsonPrimitive.content }
    val referencedTargets=incident.rows("assignments").map { it.obj("task") }
        .filter { it.text("target_type")==targetKind && it.text("target_entity_id").isNotEmpty() }
        .distinctBy { it.text("target_entity_id") }
    val liveTargetOptions=if(targetKind=="HYDRANT")hydrantData.rows.filter { it.active }.map {
        it.id to (it.code ?: it.id.take(8))
    } else referencedTargets.map { it.text("target_entity_id") to it.text("target_label_snapshot") }
    val targetOptions=reviewedTargets ?: liveTargetOptions
    val parameters=selected?.rows("parameter_definitions").orEmpty()
    val params=runCatching { buildJsonObject {
        parameters.forEach { d ->
            val raw=values[d.text("code")].orEmpty()
            if(raw.isNotEmpty())put(d.text("code"),when(d.text("type")) {
                "INTEGER","DECIMAL"->JsonPrimitive(raw.toBigDecimal())
                "BOOLEAN"->JsonPrimitive(raw.toBooleanStrict())
                else->JsonPrimitive(raw)
            })
        }
    } }.getOrNull()
    val p=GeoPoint(latitude.toDoubleOrNull() ?: Double.NaN,longitude.toDoubleOrNull() ?: Double.NaN)
    val draft=buildJsonObject {
        put("id",taskId);put("action_version_id",actionVersionId.orEmpty());put("title",title);put("notes",notes)
        put("parameters",params ?: JsonObject(emptyMap()))
        put("target",buildJsonObject {
            put("kind",targetKind)
            if(targetKind=="COORDINATE" && p.valid)put("coordinate",JsonArray(listOf(JsonPrimitive(p.longitude),JsonPrimitive(p.latitude))))
            if(targetKind in listOf("HYDRANT","INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"))put("entityId",targetId)
            if(targetKind in listOf("INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"))put("incidentId",incident.text("id"))
        })
        put("recipients",JsonArray(listOf(buildJsonObject {
            put("id",assignmentId);put("type","INCIDENT_CREW_MEMBER");put("recipient_id",crew)
        })))
    }
    val movement=selected?.text("native_behavior") in listOf("MOVE_TO","WITHDRAW_TO")
    val targetValid=when(targetKind) {
        "NONE"->!movement
        "COORDINATE"->p.valid
        "HYDRANT"->hydrantData.rows.any { h->h.id==targetId && h.active &&
            (!movement || si.gasilko.app.feature.map.HydrantMapLayers.valid(h)) }
        "INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"->referencedTargets.any { t->t.text("target_entity_id")==targetId &&
            (!movement || point(t.obj("target_geometry_snapshot"))!=null) }
        else->false
    }
    val ownIncident=JsonObject(incident+("units" to JsonArray(listOf(unit))))
    val valid=params!=null && targetValid && validIssueDraft(selectedRow,draft,ownIncident)
    BackHandler(onBack=back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        TextButton(onClick=back,enabled=!busy) { Text(stringResource(R.string.h_back)) }
        ScreenHeading(stringResource(R.string.field_issue));Text(unit.text("name"));FieldBanner(stringResource(R.string.field_online_issue))
        commandError?.let {FieldBanner(leaderErrorText(it),FieldTone.WARNING)}
        if(stale)FieldBanner(stringResource(R.string.field_stale),FieldTone.WARNING)
        if(error)FieldBanner(stringResource(R.string.field_error),FieldTone.WARNING)
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        Selector(stringResource(R.string.field_recipient),crew,recipientOptions,!busy && review==null) { crew=it }
        Selector(stringResource(R.string.field_action),definition,(reviewedRow?.let { listOf(it) } ?: catalog).map { it.text("id") to label(it.obj("configuration")) },!busy && review==null) { definition=it }
        actionVersionId?.let { Text(stringResource(R.string.field_definition_version,selected!!.text("version_number"),it),style=MaterialTheme.typography.bodySmall) }
        OutlinedTextField(title,{title=it.take(200)},enabled=review==null && !busy,label={Text(stringResource(R.string.field_subject))},modifier=Modifier.fillMaxWidth())
        OutlinedTextField(notes,{notes=it.take(4000)},enabled=review==null,label={Text(stringResource(R.string.field_instructions))},modifier=Modifier.fillMaxWidth())
        Selector(stringResource(R.string.field_target),targetKind,targets.map { it to stringResource(when(it) {
            "NONE"->R.string.field_no_target;"COORDINATE"->R.string.field_coordinate
            "HYDRANT"->R.string.field_target_hydrant;else->R.string.field_target_reference
        }) },!busy && review==null) { targetKind=it }
        if(targetKind=="COORDINATE") {
            OutlinedTextField(latitude,{latitude=it},enabled=review==null,label={Text(stringResource(R.string.field_latitude))})
            OutlinedTextField(longitude,{longitude=it},enabled=review==null,label={Text(stringResource(R.string.field_longitude))})
        }
        if(targetKind !in listOf("NONE","COORDINATE","")) {
            Selector(stringResource(R.string.field_target),targetId,targetOptions,!busy && review==null) { targetId=it }
            if(targetOptions.isEmpty())Text(stringResource(R.string.field_unsupported))
        }
        parameters.forEach { d->
            val code=d.text("code")
            if(d.text("type") in listOf("BOOLEAN","CHOICE")) {
                val options=if(d.text("type")=="BOOLEAN")listOf("true" to stringResource(R.string.field_yes),"false" to stringResource(R.string.field_no))
                    else d.rows("options").map { it.text("code") to label(it) }
                Selector(label(d),values[code].orEmpty(),options,!busy && review==null) { values=values+(code to it) }
            } else OutlinedTextField(values[code].orEmpty(),{values=values+(code to it.take(2000))},enabled=review==null && !busy,
                label={Text(label(d))},modifier=Modifier.fillMaxWidth())
        }
        if(selectedRow!=null && !valid)Text(stringResource(R.string.field_draft_invalid))
        if(review==null)Button(enabled=valid && !busy && !stale,onClick={
            val original=draft
            model.prepareLeader(incident.text("id"),unit.text("id"),"incident_issue_task",operation,original) { id->
                if(alive[0]) {
                    reviewedRow=selectedRow;reviewedRecipients=recipientOptions.toList();reviewedTargets=targetOptions.toList()
                    review=original;reviewOperation=id
                }
            }
        }) { Text(stringResource(R.string.field_review)) }
        review?.let {
            FieldBanner(stringResource(R.string.field_review_frozen))
            TextButton(enabled=!busy,onClick={reviewOperation=operation}){Text(stringResource(R.string.ul_review))}
        }
    }
    reviewOperation?.let { id->fieldState.operations.find { it.operation.operationId==id }?.let { op->
        LeaderReview(model,incident,unit,op,busy,stale) {reviewOperation=null;if(op.operation.state=="SERVER_CONFIRMED")back()}
    } }
}
