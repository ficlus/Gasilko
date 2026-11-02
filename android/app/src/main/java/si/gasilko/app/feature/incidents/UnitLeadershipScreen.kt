package si.gasilko.app.feature.incidents

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.serialization.json.*
import si.gasilko.app.R
import si.gasilko.app.core.database.FieldOperation
import si.gasilko.app.core.ui.*
import java.util.UUID

@Composable internal fun leaderStatus(code: String): String=when(code) {
    "DRAFT"->stringResource(R.string.ul_not_sent)
    "ON_SCENE"->stringResource(R.string.ul_on_scene)
    "RETURNING"->stringResource(R.string.ul_returning)
    "RELEASED"->stringResource(R.string.ul_released)
    "UNAVAILABLE"->stringResource(R.string.ul_unavailable)
    "RESERVED"->stringResource(R.string.ul_reserved)
    "DEPLOYED"->stringResource(R.string.ul_deployed)
    "RETURNED"->stringResource(R.string.ul_returned)
    "CONSUMED"->stringResource(R.string.ul_consumed)
    "TASK_CLOSED"->stringResource(R.string.ul_task_closed)
    "LEFT"->stringResource(R.string.ul_left)
    "ACTIVE"->stringResource(R.string.ul_active)
    else->stateName(code)
}
@Composable internal fun leaderErrorText(code: String)=stringResource(when(code) {
    "NOT_AUTHORIZED","SCOPE_CHANGED","MANIFEST_SCOPE_CHANGED"->R.string.ul_scope_lost
    "STALE_VERSION","OPERATION_REUSED"->R.string.ul_stale_request
    "CATALOG_LIMIT"->R.string.ul_catalog_limit
    "INVALID_UNIT_STATUS","INVALID_RESOURCE_STATUS"->R.string.ul_transition
    "RESOURCE_LIMIT_REACHED","INSUFFICIENT_RESOURCE_QUANTITY"->R.string.ul_resource_limit
    "UNIT_HAS_ACTIVE_COMMAND","UNIT_HAS_ACTIVE_CREW","RESOURCE_IN_USE","UNRESOLVED_TASKS"->R.string.ul_blocked
    "SIMULATION_RESOURCE_DISABLED"->R.string.ul_training_resource
    "INVALID_CREW_MEMBER","INVALID_TASK_RECIPIENT","INVALID_ACTION_DEFINITION"->R.string.ul_eligibility
    "OUTCOME_UNKNOWN","TRANSPORT_UNCERTAIN","RECEIPT_UNCERTAIN"->R.string.ul_unknown
    else->R.string.ul_failed
})
@Composable
internal fun LeaderReview(model: IncidentViewModel,incident: JsonObject,unit: JsonObject,op: FieldOperation,busy: Boolean,stale: Boolean,close: ()->Unit) {
    val body=parse(op.operation.payload);val review=body.obj("review");val payload=body.obj("payload")
    val permitted=isCurrentLeader(incident,unit) && body.text("leader")==leaderStamp(unit) &&
        body.text("unit")==unit.text("id") && body.text("incident")==incident.text("id")
    AlertDialog(onDismissRequest={if(!busy)close()},title={Text(stringResource(R.string.ul_review))},
        text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text(review.text("reference"));StatusBadge(stringResource(if(review.text("mode")=="TRAINING")R.string.field_training else R.string.ul_real),FieldTone.WARNING)
            Text(review.text("unit"));Text(leaderStatus(review.text("source_status")))
            Text(review.text("subject"));Text(review.text("quantity")+" "+(if(review.obj("measure_label").isNotEmpty())label(review.obj("measure_label")) else review.text("measure")))
            if(review.obj("action").isNotEmpty())Text(label(review.obj("action")))
            Text(payload.text("title"));Text(payload.text("notes"))
            Text(stringResource(R.string.ul_entity)+": "+payload.text("id"))
            if(payload.text("user_id").isNotEmpty())Text(payload.text("user_id"))
            if(payload.text("status")=="CONSUMED")FieldBanner(stringResource(R.string.ul_consumption_warning),FieldTone.WARNING)
            if(payload.text("status").isNotEmpty())Text(leaderStatus(payload.text("status")))
            val target=payload.obj("target")
            if(target.isNotEmpty())Text(stringResource(R.string.ul_target)+": "+when(target.text("kind")) {
                "NONE"->stringResource(R.string.field_no_target)
                "COORDINATE"->target["coordinate"].toString()
                else->target.text("entityId")
            })
            payload.obj("parameters").forEach { (code,value)->
                val definition=review.obj("action").rows("parameter_definitions").find { it.text("code")==code }
                val raw=(value as? JsonPrimitive)?.content.orEmpty()
                val displayed=when(definition?.text("type")) {
                    "BOOLEAN"->stringResource(if(raw=="true")R.string.field_yes else R.string.field_no)
                    "CHOICE"->definition?.rows("options").orEmpty().find { it.text("code")==raw }?.let { label(it) } ?: raw
                    else->raw
                }
                Text((definition?.let { label(it) } ?: code)+": "+displayed)
            }
            Text(stringResource(R.string.ul_versions,body.text("expected"),body.text("unit_version"),payload.text("version")))
            Text(op.operation.operationId,style=MaterialTheme.typography.bodySmall)
            Text(payload.text("action_version_id"));Text(payload.rows("recipients").firstOrNull()?.text("recipient_id").orEmpty())
            FieldBanner(stringResource(R.string.ul_online))
            StatusBadge(leaderStatus(op.operation.state),FieldTone.INFO)
            op.error?.let { FieldBanner(leaderErrorText(it),FieldTone.WARNING) }
            if(op.operation.state=="SERVER_CONFIRMED")Text(stringResource(R.string.ul_receipt_stale))
            if(!permitted)FieldBanner(stringResource(R.string.ul_scope_lost),FieldTone.WARNING)
        }},confirmButton={
            if(op.operation.state in listOf("DRAFT","LOCAL_PENDING","SENDING","OUTCOME_UNKNOWN"))TextButton(
                enabled=permitted && !busy && !stale,onClick={model.confirmLeader(incident.text("id"),unit.text("id"),op.operation.operationId,close)}) {
                Text(stringResource(if(op.operation.state=="DRAFT")R.string.ul_confirm else R.string.ul_retry))
            }
        },dismissButton={TextButton(enabled=!busy,onClick=close){Text(stringResource(R.string.h_back))}})
}
@Composable
internal fun UnitLeadershipScreen(model: IncidentViewModel,incidentId: String,unitId: String,
    openAssignment: (String)->Unit,issue: ()->Unit,openMap: (String?)->Unit,back: ()->Unit) {
    val data by model.state.collectAsStateWithLifecycle()
    val i=data.incidents.find { it.text("id")==incidentId }
    val unit=i?.rows("units")?.find { it.text("id")==unitId }
    if(data.locked || i==null || unit==null) {
        Column(Modifier.padding(16.dp)) { TextButton(onClick=back){Text(stringResource(R.string.h_back))};FieldBanner(stringResource(R.string.field_locked),FieldTone.WARNING) }
        return
    }
    key(model,incidentId,unitId,leaderStamp(unit)) { UnitLeadershipContent(model,data,i,unit,openAssignment,issue,openMap,back) }
}
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun UnitLeadershipContent(model: IncidentViewModel,data: IncidentFieldState,incident: JsonObject,unit: JsonObject,
    openAssignment: (String)->Unit,issue: ()->Unit,openMap: (String?)->Unit,back: ()->Unit) {
    val busy by model.busy.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val syncFailure by model.syncFailure.collectAsStateWithLifecycle()
    val error by model.commandError.collectAsStateWithLifecycle()
    val leader=isCurrentLeader(incident,unit)
    var filter by remember { mutableIntStateOf(0) }
    var member by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var candidates by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var chosen by remember { mutableStateOf<JsonObject?>(null) }
    var crewRole by remember { mutableStateOf("RESPONDER") }
    var join by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf<String?>(null) }
    val alive=remember { booleanArrayOf(true) }
    DisposableEffect(Unit) { onDispose { alive[0]=false } }
    val listState=rememberLazyListState()
    val tasks=unitAssignments(incident,unit.text("id"))
    val ops=data.operations.filter { op->val body=parse(op.operation.payload)
        body.text("incident")==incident.text("id") && body.text("rpc") in leaderRpcs &&
        ((body.text("unit")==unit.text("id") && body.text("leader")==leaderStamp(unit)) ||
        (body.text("unit").isEmpty() && ((body.text("rpc")=="incident_issue_task" &&
         unit.rows("crew").any { it.flag("can_issue") && it.text("id")==body.obj("payload").rows("recipients").firstOrNull()?.text("recipient_id") }) ||
         (body.text("rpc")=="incident_update_unit_status" && body.obj("payload").text("id")==unit.text("id")))))
    }
    fun propose(rpc: String,payload: JsonObject,candidateQuery: String="") {
        model.prepareLeader(incident.text("id"),unit.text("id"),rpc,UUID.randomUUID().toString(),payload,candidateQuery) {
            if(alive[0])review=it
        }
    }
    BackHandler(onBack=back)
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        TextButton(onClick=back,enabled=!busy){Text(stringResource(R.string.h_back))}
        ScreenHeading(stringResource(R.string.ul_title))
        Text(incident.text("reference")+" · "+incident.text("title"));Text(unit.text("name"))
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            StatusBadge(stringResource(if(incident.text("mode")=="TRAINING")R.string.field_training else R.string.ul_real),FieldTone.WARNING);StatusBadge(leaderStatus(unit.text("status")),FieldTone.INFO)
        }
        Text(unit.text("leader_name"));Text(unit.obj("leader_assignment").text("id"),style=MaterialTheme.typography.bodySmall)
        if(unit.obj("leader_assignment").text("parent_assignment_id").isNotEmpty())
            Text(stringResource(R.string.ul_parent)+": "+unit.obj("leader_assignment").text("parent_assignment_id"))
        Text(stringResource(R.string.ul_verified,data.verifiedAt?.let { java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)) }.orEmpty()))
        if(stale || syncFailure!=null || incident.flag("leader_reset"))FieldBanner(stringResource(R.string.field_stale),FieldTone.WARNING)
        if(data.warning)FieldBanner(stringResource(R.string.field_lease_warning),FieldTone.WARNING)
        if(!leader)FieldBanner(stringResource(R.string.ul_read_only))
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        error?.let { FieldBanner(leaderErrorText(it),FieldTone.WARNING) }
        TextButton(onClick=model::sync,enabled=!busy){Text(stringResource(R.string.h_sync_now))}
        TextButton(onClick={openMap(null)}){Text(stringResource(R.string.field_map))}
        LazyColumn(Modifier.weight(1f),state=listState,verticalArrangement=Arrangement.spacedBy(12.dp)) {
            item { OperationalCard {
                SectionHeading(stringResource(R.string.ul_status))
                Text(leaderStatus(unit.text("status")));Text(unit.text("status_changed_at"))
                Text(stringResource(R.string.ul_versions,incident.text("version"),unit.text("version"),""))
                if(leader)unit["status_actions"]?.jsonArray?.forEach { action->
                    Button(enabled=!busy && !stale,onClick={propose("incident_update_unit_status",buildJsonObject {
                        put("id",unit.text("id"));put("version",unit.text("version"));put("status",action.jsonPrimitive.content)
                    })}){Text(leaderStatus(action.jsonPrimitive.content))}
                }
                Text(stringResource(R.string.ul_status_boundary))
            } }
            if(leader)item { Button(onClick=issue,enabled=!busy && !stale,modifier=Modifier.heightIn(min=56.dp)) {Text(stringResource(R.string.field_issue))} }
            item { SectionHeading(stringResource(R.string.ul_crew)) }
            if(unit.rows("crew").isEmpty())item { Text(stringResource(R.string.ul_empty_crew)) }
            items(unit.rows("crew"),key={"crew/"+it.text("id")}) { c->OperationalCard {
                Text(c.text("name"),style=MaterialTheme.typography.titleMedium)
                Text(stringResource(when(c.text("role")) { "LEADER"->R.string.ul_crew_leader;"DRIVER"->R.string.ul_driver;"SPECIALIST"->R.string.ul_specialist;else->R.string.ul_responder }))
                Text(c.text("id"),style=MaterialTheme.typography.bodySmall);Text(c.text("joined_at"))
                val personal=tasks.filter { it.text("recipient_type")=="INCIDENT_CREW_MEMBER" && it.text("recipient_id")==c.text("id") }
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { personal.groupBy { it.text("status") }.toSortedMap().forEach { (state,rows)->
                    StatusBadge(leaderStatus(state)+": "+rows.size,FieldTone.INFO)
                } }
                TextButton(onClick={member=c.text("id");filter=0}){Text(stringResource(R.string.ul_member_tasks))}
                if(leader && c.flag("can_leave"))TextButton(enabled=!busy && !stale,onClick={propose("incident_remove_crew_member",buildJsonObject {
                    put("id",c.text("id"));put("version",c.text("version"))
                })}){Text(stringResource(R.string.ul_remove))}
            } }
            if(leader && unit.flag("can_manage_crew"))item {
                OutlinedButton(enabled=!busy && !stale,onClick={join=!join;candidates=emptyList();chosen=null}){Text(stringResource(R.string.ul_add))}
                if(join) {
                    OutlinedTextField(query,{query=it.take(100)},label={Text(stringResource(R.string.ul_search))},modifier=Modifier.fillMaxWidth())
                    TextButton(enabled=!busy && !stale && query.isNotBlank(),onClick={chosen=null;candidates=emptyList();model.searchCrew(
                        incident.text("id"),unit.text("id"),query) { if(alive[0])candidates=it }
                    }){Text(stringResource(R.string.ul_search))}
                    if(candidates.size>=30)Text(stringResource(R.string.ul_narrow_search))
                    candidates.forEach { c->FilterChip(selected=chosen==c,onClick={chosen=c},label={Text(c.text("name"))}) }
                    Selector(stringResource(R.string.ul_crew_role),crewRole,listOf(
                        "LEADER" to stringResource(R.string.ul_crew_leader),"DRIVER" to stringResource(R.string.ul_driver),
                        "RESPONDER" to stringResource(R.string.ul_responder),"SPECIALIST" to stringResource(R.string.ul_specialist)),!busy) {crewRole=it}
                    Button(enabled=chosen!=null && !busy && !stale,onClick={chosen?.let { c->propose("incident_add_crew_member",buildJsonObject {
                        put("id",UUID.randomUUID().toString());put("unit_assignment_id",unit.text("id"));put("user_id",c.text("id"));put("crew_role",crewRole)
                    },c.text("name").take(100)) }}){Text(stringResource(R.string.ul_review))}
                }
            }
            if(leader && unit.rows("crew_history").isNotEmpty())item { OperationalCard {
                SectionHeading(stringResource(R.string.ul_history_crew))
                unit.rows("crew_history").forEach { c->Text(c.text("name")+" · "+leaderStatus(c.text("status"))+" · "+c.text("left_at")) }
                if(unit.flag("crew_history_more"))Text(stringResource(R.string.ul_history_limit))
            } }
            item {
                SectionHeading(stringResource(R.string.ul_tasks))
                Selector(stringResource(R.string.ul_filter),filter.toString(),listOf(R.string.ul_all,R.string.ul_attention,
                    R.string.field_in_progress,R.string.field_blocked,R.string.ul_terminal).mapIndexed { n,id->n.toString() to stringResource(id) }) {filter=it.toInt()}
                if(member.isNotEmpty())TextButton(onClick={member=""}){Text(stringResource(R.string.ul_all_members))}
            }
            val filtered=tasks.filter { a->
                (member.isEmpty() || (a.text("recipient_type")=="INCIDENT_CREW_MEMBER" && a.text("recipient_id")==member)) &&
                when(filter) {1->a.text("status") in listOf("BLOCKED","UNABLE") || data.operations.any { it.operation.entityId==a.text("id") && it.operation.state in listOf("NEEDS_ATTENTION","OUTCOME_UNKNOWN") };
                    2->a.text("status") in listOf("ACKNOWLEDGED","IN_PROGRESS");3->a.text("status")=="BLOCKED";4->a.text("status") in terminal;else->true}
            }
            if(filtered.isEmpty())item {Text(stringResource(R.string.field_no_orders))}
            items(filtered,key={"task/"+it.text("id")}) { a->OutlinedCard(onClick={openAssignment(a.text("id"))}) {
                Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text(label(a.obj("task").obj("configuration")));Text(a.obj("task").text("title"));Text(a.text("recipient_name"))
                    Text(a.obj("task").text("target_label_snapshot"));Text(a.obj("task").text("issuer_name"))
                    TextButton(onClick={openMap(a.text("id"))}){Text(stringResource(R.string.im_show_target))}
                    StatusBadge(leaderStatus(a.text("status")),FieldTone.INFO)
                    if(a.text("status")=="BLOCKED")Text(a.text("blocked_reason"))
                    if(a.text("status")=="UNABLE")Text(a.text("unable_reason"))
                    data.operations.lastOrNull { it.operation.entityId==a.text("id") }?.let { Text(leaderStatus(it.operation.state)) }
                }
            } }
            item { SectionHeading(stringResource(R.string.ul_resources))
                if(incident.text("mode")=="TRAINING")FieldBanner(stringResource(R.string.ul_training_resource)) }
            if(unit.rows("resources").isEmpty())item {Text(stringResource(R.string.ul_no_resources))}
            items(unit.rows("resources"),key={"resource/"+it.text("id")}) { r->OperationalCard {
                Text(r.text("name"));Text(r.text("quantity")+" "+(if(r.obj("measure").isNotEmpty())label(r.obj("measure")) else r.text("unit_of_measure_code")));Text(r.text("organization_name"))
                Text(r.text("id"),style=MaterialTheme.typography.bodySmall);StatusBadge(leaderStatus(r.text("status")),FieldTone.INFO)
                if(leader)FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) { resourceTransitions(r).forEach { status->
                    OutlinedButton(enabled=!busy && !stale,onClick={propose("incident_transition_resource_allocation",buildJsonObject {
                        put("id",r.text("id"));put("version",r.text("version"));put("status",status)
                    })}){Text(leaderStatus(status))}
                } }
                if(r.text("status")=="DEPLOYED")Text(stringResource(R.string.ul_consumption_warning))
            } }
            if(unit.flag("resource_history_more"))item {Text(stringResource(R.string.ul_history_limit))}
            if(leader) {
                item {SectionHeading(stringResource(R.string.ul_operations))}
                items(ops.takeLast(30).asReversed(),key={"op/"+it.operation.operationId}) { op->
                    val body=parse(op.operation.payload)
                    OperationalCard {
                        StatusBadge(leaderStatus(op.operation.state),FieldTone.INFO)
                        Text(body.obj("payload").text("title"));Text(op.operation.operationId,style=MaterialTheme.typography.bodySmall)
                        op.error?.let {Text(leaderErrorText(it))}
                        if(op.operation.state=="SERVER_CONFIRMED")Text(stringResource(R.string.ul_receipt_stale))
                        if(body.text("unit").isNotEmpty())TextButton(enabled=!busy,onClick={review=op.operation.operationId}){Text(stringResource(R.string.ul_review))}
                        else if(op.operation.state in listOf("LOCAL_PENDING","SENDING","OUTCOME_UNKNOWN"))TextButton(enabled=!busy && !stale,onClick={
                            if(body.text("rpc")=="incident_issue_task")model.issue(incident.text("id"),op.operation.operationId,body.obj("payload")) {}
                            else model.returnUnit(incident.text("id"),unit.text("id"),op.operation.operationId)
                        }){Text(stringResource(R.string.ul_retry))}
                    }
                }
                if(ops.size>30)item {Text(stringResource(R.string.ul_history_limit))}
            }
            item {SectionHeading(stringResource(R.string.field_history))}
            items(incident.rows("history").filter { h->tasks.any { a->
                h.obj("data").text("task_assignment_id")==a.text("id") ||
                (h.obj("data").text("task_assignment_id").isEmpty() && h.obj("data").text("task_id")==a.obj("task").text("id"))
            } },key={"history/"+it.text("sequence")}) { h->Text(leaderStatus(when(h.text("code")) {
                "TASK_ISSUED"->"ISSUED";"TASK_CLOSED"->"TASK_CLOSED";"TASK_CANCELLED"->"CANCELLED";
                "TASK_ASSIGNMENT_ACKNOWLEDGED"->"ACKNOWLEDGED";"TASK_ASSIGNMENT_STARTED"->"IN_PROGRESS";"TASK_ASSIGNMENT_BLOCKED"->"BLOCKED";
                "TASK_ASSIGNMENT_COMPLETED"->"COMPLETED";"TASK_ASSIGNMENT_UNABLE"->"UNABLE";else->"CANCELLED"
            }));Text(h.text("recorded_at"));Text(h.obj("data").text("reason")) }
        }
    }
    if(leader)review?.let { id->ops.find { it.operation.operationId==id }?.let {
        LeaderReview(model,incident,unit,it,busy,stale) {review=null}
    } }
}
