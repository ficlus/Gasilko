package si.gasilko.app.feature.incidents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
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
import si.gasilko.app.feature.map.MapScreen
import si.gasilko.app.feature.map.domain.GeoPoint
import java.util.UUID
import java.text.DateFormat
import java.util.Date

@Composable private fun label(row: JsonObject): String {
    val de=LocalConfiguration.current.locales[0].language=="de"
    return row.text(if(de)"label_de" else "label_sl")
}
@Composable private fun stateName(value: String)=stringResource(when(value) {
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
fun IncidentScreen(model: IncidentViewModel,registry: HydrantViewModel,organizationName: String,initialIncident: String?,back: ()->Unit) {
    val data by model.state.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val error by model.error.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(model,lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { model.foreground() } }
    var incidentId by remember(model) { mutableStateOf(initialIncident) }
    var assignmentId by remember(model) { mutableStateOf<String?>(null) }
    var filter by remember(model) { mutableIntStateOf(0) }
    var unitTab by remember(model,incidentId) { mutableStateOf(false) }
    var issue by remember(model,incidentId) { mutableStateOf(false) }
    var target by remember(model,incidentId,assignmentId) { mutableStateOf<GeoPoint?>(null) }
    val incident=data.incidents.find { it.text("id")==incidentId }
    val assignment=incident?.rows("assignments")?.find { it.text("id")==assignmentId }
    fun close() { when { target!=null->target=null;issue->issue=false;assignmentId!=null->assignmentId=null;incidentId!=null->incidentId=null;else->back() } }
    BackHandler(onBack=::close)
    if(data.locked) {
        Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            ScreenHeading(stringResource(R.string.field_title))
            FieldBanner(stringResource(R.string.field_locked),FieldTone.WARNING)
            TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
            TextButton(onClick=model::sync) { Text(stringResource(R.string.h_sync_now)) }
        }
        return
    }
    if(target!=null && incident!=null && (assignmentId==null || assignment!=null)) {
        val query=remember(model.organization) { si.gasilko.app.feature.hydrants.domain.HydrantQuery(organization=model.organization) }
        val flow=remember(query,registry) { registry.mapHydrants(query) }
        val hydrants by flow.collectAsStateWithLifecycle(initialValue=si.gasilko.app.feature.hydrants.presentation.MapHydrantsState())
        MapScreen(onBack={target=null},hydrants=hydrants.rows,onOpenHydrant=null,targetPoint=target,
            dataLoading=hydrants.loading,dataError=hydrants.error,creationEnabled=false)
        return
    }
    if(issue && incident!=null && incident.rows("units").any { it.flag("leader") }) {
        IssueTask(model,registry,incident,busy) { issue=false }
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
        if(stale)FieldBanner(stringResource(R.string.field_stale),FieldTone.WARNING)
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
            val pending=last?.takeIf { it.operation.state!="SERVER_CONFIRMED" }
            val effective=pending?.let { parse(it.operation.payload).obj("payload").text("status") } ?: assignment.text("status")
            var desired by remember(assignmentId) { mutableStateOf<String?>(null) }
            var reason by remember(desired) { mutableStateOf("") }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                item { Text(incident.text("title"));Text(label(config),style=MaterialTheme.typography.headlineSmall)
                    Text(task.text("title"));Text(task.text("notes"))
                    Text(config.text(if(LocalConfiguration.current.locales[0].language=="de")"description_de" else "description_sl"))
                    Text(assignment.text("id"),style=MaterialTheme.typography.bodySmall)
                    Text(assignment.text("recipient_name"));Text(task.text("issuer_name"));Text(task.text("issued_at"))
                    Text(task.text("priority"));StatusBadge(stateName(assignment.text("status")),FieldTone.INFO)
                    if(config.flag("requires_acknowledgement"))Text(stringResource(R.string.field_ack_required))
                    config.rows("parameter_definitions").forEach { d ->
                        Text(label(d)+": "+(task.obj("parameters")[d.text("code")]?.toString().orEmpty()))
                    }
                    Text(task.text("target_label_snapshot"))
                    point(task.obj("target_geometry_snapshot"))?.let { p ->
                        OutlinedButton(onClick={target=p}) { Text(stringResource(R.string.field_map)) }
                    }
                }
                items(operations,key={it.operation.operationId}) { op ->
                    FieldBanner(stateName(op.operation.state),if(op.operation.state=="SERVER_CONFIRMED")FieldTone.SUCCESS else FieldTone.WARNING)
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
            FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                FilterChip(selected=!unitTab,onClick={unitTab=false},label={Text(stringResource(R.string.field_orders))})
                FilterChip(selected=unitTab,onClick={unitTab=true},label={Text(stringResource(R.string.field_unit))})
                val lat=incident.text("latitude").toDoubleOrNull();val lon=incident.text("longitude").toDoubleOrNull()
                if(lat!=null && lon!=null)TextButton(onClick={target=GeoPoint(lat,lon)}) { Text(stringResource(R.string.field_map)) }
            }
            LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp),contentPadding=PaddingValues(bottom=24.dp)) {
                if(unitTab) {
                    items(incident.rows("units"),key={it.text("id")}) { unit ->
                        OperationalCard {
                            SectionHeading(unit.text("name"));Text(unit.text("status"));Text(unit.text("leader_name"))
                            unit.rows("crew").forEach { c->Text(c.text("name")+" · "+c.text("role")) }
                            var returnConfirm by remember(unit.text("id")) { mutableStateOf(false) }
                            val pendingReturn=data.operations.lastOrNull { it.operation.entityId==unit.text("id") &&
                                parse(it.operation.payload).text("rpc")=="incident_update_unit_status" }
                            val returnId=remember(unit.text("id"),pendingReturn?.operation?.operationId) {
                                pendingReturn?.operation?.operationId ?: UUID.randomUUID().toString()
                            }
                            if(unit.flag("can_return") || pendingReturn?.operation?.state in listOf("SENDING","OUTCOME_UNKNOWN","LOCAL_PENDING")) {
                                OutlinedButton(onClick={returnConfirm=true},enabled=!busy && pendingReturn?.operation?.state!="NEEDS_ATTENTION") {
                                    Text(stringResource(R.string.field_return_unit))
                                }
                                if(returnConfirm)AlertDialog(onDismissRequest={returnConfirm=false},
                                    title={Text(stringResource(R.string.field_return_unit))},
                                    text={Text(stringResource(R.string.field_online_return))},
                                    confirmButton={TextButton(onClick={
                                        model.returnUnit(incident.text("id"),unit.text("id"),returnId);returnConfirm=false
                                    }) { Text(stringResource(R.string.field_confirm)) }},
                                    dismissButton={TextButton(onClick={returnConfirm=false}) { Text(stringResource(R.string.h_back)) }})
                            }
                            pendingReturn?.let { Text(stateName(it.operation.state)) }
                            val tasks=incident.rows("assignments").filter { it.text("unit_id")==unit.text("id") }
                            Text(stringResource(R.string.field_outstanding,tasks.count { it.text("status") !in terminal }))
                            if(unit.flag("leader") && unit.rows("crew").any { it.flag("can_issue") })
                                Button(onClick={issue=true;model.loadCatalog()},enabled=!busy) { Text(stringResource(R.string.field_issue)) }
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
                // An uncertain online issue is never automatically resent in background.
                items(data.operations.filter { op->parse(op.operation.payload).text("incident")==incident.text("id") &&
                    parse(op.operation.payload).text("rpc")=="incident_issue_task" && op.operation.state!="SERVER_CONFIRMED"
                },key={it.operation.operationId}) { op ->
                    FieldBanner(stateName(op.operation.state),FieldTone.WARNING)
                    Text(parse(op.operation.payload).obj("payload").text("title"))
                    Text(parse(op.operation.payload).obj("payload").text("notes"))
                    Text(op.operation.operationId,style=MaterialTheme.typography.bodySmall)
                    if(op.operation.state!="NEEDS_ATTENTION")TextButton(enabled=!busy,onClick={
                        model.issue(incident.text("id"),op.operation.operationId,parse(op.operation.payload).obj("payload")) {}
                    }) { Text(stringResource(R.string.field_retry_issue)) }
                }
            }
        }
    }
}

@Composable private fun Selector(title: String,value: String,options: List<Pair<String,String>>,enabled: Boolean=true,select: (String)->Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick={expanded=true},enabled=enabled,modifier=Modifier.fillMaxWidth()) { Text(title+": "+(options.find { it.first==value }?.second.orEmpty())) }
        DropdownMenu(expanded=expanded && enabled,onDismissRequest={expanded=false}) {
            options.forEach { (id,name)->DropdownMenuItem(text={Text(name)},onClick={expanded=false;select(id)}) }
        }
    }
}

@Composable private fun IssueTask(model: IncidentViewModel,registry: HydrantViewModel,incident: JsonObject,busy: Boolean,back: ()->Unit) {
    val catalog by model.catalog.collectAsStateWithLifecycle()
    val error by model.error.collectAsStateWithLifecycle()
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
    val operation=remember { UUID.randomUUID().toString() }
    val taskId=remember { UUID.randomUUID().toString() }
    val assignmentId=remember { UUID.randomUUID().toString() }
    val selected=catalog.find { it.text("id")==definition }?.obj("configuration")
    val targets=selected?.get("target_types")?.jsonArray.orEmpty().map { it.jsonPrimitive.content }
    val referencedTargets=incident.rows("assignments").map { it.obj("task") }
        .filter { it.text("target_type")==targetKind && it.text("target_entity_id").isNotEmpty() }
        .distinctBy { it.text("target_entity_id") }
    val targetOptions=if(targetKind=="HYDRANT")hydrantData.rows.filter { it.active }.map {
        it.id to (it.code ?: it.id.take(8))
    } else referencedTargets.map { it.text("target_entity_id") to it.text("target_label_snapshot") }
    val parameters=selected?.rows("parameter_definitions").orEmpty()
    val params=runCatching { buildJsonObject {
        parameters.forEach { d ->
            val raw=values[d.text("code")].orEmpty()
            if(raw.isNotEmpty())put(d.text("code"),when(d.text("type")) {
                "INTEGER"->JsonPrimitive(raw.toLong())
                "DECIMAL"->JsonPrimitive(raw.toDouble().also { require(it.isFinite()) })
                "BOOLEAN"->JsonPrimitive(raw.toBooleanStrict())
                else->JsonPrimitive(raw)
            })
        }
    } }.getOrNull()
    val p=GeoPoint(latitude.toDoubleOrNull() ?: Double.NaN,longitude.toDoubleOrNull() ?: Double.NaN)
    val valid=crew.isNotEmpty() && selected!=null && targetKind in targets && (targetKind!="COORDINATE" || p.valid) &&
        (targetKind in listOf("NONE","COORDINATE") || targetOptions.any { it.first==targetId }) &&
        params!=null && parameters.none { it.flag("required") && values[it.text("code")].isNullOrBlank() }
    BackHandler(onBack=back)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        TextButton(onClick=back,enabled=!busy) { Text(stringResource(R.string.h_back)) }
        ScreenHeading(stringResource(R.string.field_issue));FieldBanner(stringResource(R.string.field_online_issue))
        if(error)FieldBanner(stringResource(R.string.field_error),FieldTone.WARNING)
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        Selector(stringResource(R.string.field_recipient),crew,incident.rows("units").filter { it.flag("leader") }.flatMap { u->
            u.rows("crew").filter { it.flag("can_issue") }.map { it.text("id") to (u.text("name")+" · "+it.text("name")) }
        },!busy && review==null) { crew=it }
        Selector(stringResource(R.string.field_action),definition,catalog.map { it.text("id") to label(it.obj("configuration")) },!busy && review==null) { definition=it }
        OutlinedTextField(title,{title=it.take(200)},enabled=review==null,label={Text(stringResource(R.string.field_subject))},modifier=Modifier.fillMaxWidth())
        OutlinedTextField(notes,{notes=it.take(2000)},enabled=review==null,label={Text(stringResource(R.string.field_instructions))},modifier=Modifier.fillMaxWidth())
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
            } else OutlinedTextField(values[code].orEmpty(),{values=values+(code to it.take(2000))},enabled=review==null,
                label={Text(label(d))},modifier=Modifier.fillMaxWidth())
        }
        if(review==null)Button(enabled=valid && !busy,onClick={
            review=buildJsonObject {
                put("id",taskId);put("action_version_id",selected!!.text("id"));put("title",title);put("notes",notes)
                put("parameters",params!!)
                put("target",buildJsonObject { put("kind",targetKind)
                    if(targetKind=="COORDINATE")put("coordinate",JsonArray(listOf(JsonPrimitive(p.longitude),JsonPrimitive(p.latitude))))
                    if(targetKind in listOf("HYDRANT","INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"))put("entityId",targetId)
                    if(targetKind in listOf("INCIDENT_MAP_OBJECT","INCIDENT_SECTOR"))put("incidentId",incident.text("id"))
                })
                put("recipients",JsonArray(listOf(buildJsonObject {
                    put("id",assignmentId);put("type","INCIDENT_CREW_MEMBER");put("recipient_id",crew)
                })))
            }
        }) { Text(stringResource(R.string.field_review)) }
        review?.let { payload ->
            FieldBanner(stringResource(R.string.field_review_frozen))
            Button(enabled=!busy,onClick={model.issue(incident.text("id"),operation,payload,back)}) { Text(stringResource(R.string.field_confirm_issue)) }
        }
    }
}
