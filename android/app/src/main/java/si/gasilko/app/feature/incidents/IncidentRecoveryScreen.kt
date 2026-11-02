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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import si.gasilko.app.R
import si.gasilko.app.core.database.FieldOperation
import si.gasilko.app.core.ui.*
import java.text.DateFormat
import java.util.Date

@Composable private fun recoveryLabel(phase: RecoveryPhase)=stringResource(when(phase) {
    RecoveryPhase.LOCAL_INTENT->R.string.ir_local
    RecoveryPhase.READY_TO_SEND->R.string.ir_ready
    RecoveryPhase.SENDING->R.string.ir_sending
    RecoveryPhase.OUTCOME_UNKNOWN->R.string.ir_unknown
    RecoveryPhase.SERVER_CONFIRMED->R.string.ir_confirmed
    RecoveryPhase.DEFINITIVELY_REJECTED->R.string.ir_rejected
    RecoveryPhase.NEEDS_ATTENTION->R.string.ir_attention
    RecoveryPhase.BLOCKED_DEPENDENCY->R.string.ir_dependency
    RecoveryPhase.SCOPE_UNAVAILABLE->R.string.ir_scope
})
@Composable internal fun recoveryErrorText(original: String): String {
 val code=original.removePrefix("REJECTED:")
 return stringResource(when {
    code=="COMPATIBILITY"->R.string.ir_compatibility
    code=="LOCAL_STORAGE"->R.string.ir_storage
    code=="SECURE_STORAGE"->R.string.ir_secure_storage
    code in setOf("NOT_AUTHORIZED","SCOPE_UNAVAILABLE","SCOPE_CHANGED")->R.string.ir_scope
    code in setOf("IDENTITY_MISMATCH","OPERATION_REUSED")->R.string.ir_identity
    code.startsWith("UNKNOWN_REJECTED:")->R.string.ir_unknown_rejection
    code in setOf("STALE_VERSION","LOCAL_STALE","DEPENDENCY_CHANGED","INVALID_TASK_TRANSITION","TASK_NOT_FOUND","INCIDENT_TERMINAL")->R.string.ir_stale
    code in setOf("DEPENDENCY_REJECTED","DEPENDENCY_MISSING")->R.string.ir_dependency
    code=="TEMPORARY_BUSY"->R.string.ir_busy
    code=="RECEIPT_ABSENT"->R.string.ir_absent
    original.startsWith("REJECTED:")->R.string.ir_rejected
    else->R.string.ir_transport
})
}
private fun localDate(time: Long)=DateFormat.getDateTimeInstance().format(Date(time))

@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun IncidentRecoveryScreen(model: IncidentViewModel,incidentFilter: String?,
    openTask: (String,String)->Unit,openUnit: (String,String)->Unit,back: ()->Unit) {
    val data by model.state.collectAsStateWithLifecycle()
    val busy by model.busy.collectAsStateWithLifecycle()
    val stale by model.stale.collectAsStateWithLifecycle()
    val failure by model.commandError.collectAsStateWithLifecycle()
    val syncFailure by model.syncFailure.collectAsStateWithLifecycle()
    var phase by remember {mutableStateOf("")}
    var page by remember {mutableIntStateOf(0)}
    var selected by remember {mutableStateOf<String?>(null)}
    var correction by remember {mutableStateOf<String?>(null)}
    BackHandler(onBack=back)
    val all=data.operations
    val scoped=all.filter {data.locked || incidentFilter==null || runCatching {parse(it.operation.payload).text("incident")==incidentFilter}.getOrDefault(false)}
    val rows=scoped.filter {phase.isEmpty() || recoveryPhase(it,all,recoveryVisible(it,data)).name==phase}.asReversed()
    val receiptTime=scoped.filter {recoveryVisible(it,data)}.mapNotNull {
        runCatching {java.time.Instant.parse(it.result?.let(::parse)?.text("_d1_confirmed_at")).toEpochMilli()}.getOrNull()
    }.maxOrNull()
    BoxWithConstraints(Modifier.fillMaxSize()) {
    val headerHeight=maxHeight*0.55f
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Column(Modifier.heightIn(max=headerHeight).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        TextButton(onClick=back){Text(stringResource(R.string.h_back))}
        ScreenHeading(stringResource(R.string.ir_title))
        FieldBanner(stringResource(R.string.ir_no_success))
        if(data.locked)FieldBanner(stringResource(R.string.ir_scope),FieldTone.WARNING)
        if(stale || syncFailure!=null)FieldBanner(stringResource(R.string.field_stale),FieldTone.WARNING)
        if(data.warning)FieldBanner(stringResource(R.string.field_lease_warning),FieldTone.WARNING)
        Text(stringResource(R.string.ir_last_read,data.verifiedAt?.let(::localDate) ?: stringResource(R.string.ir_unavailable)))
        Text(stringResource(R.string.ir_last_receipt,receiptTime?.let(::localDate) ?: stringResource(R.string.ir_unavailable)))
        if(!data.locked)Text(stringResource(R.string.ir_lease_minutes,(data.leaseRemaining/60_000).toString()))
        Text(stringResource(R.string.ir_radio),style=MaterialTheme.typography.bodySmall)
        FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            listOf(RecoveryPhase.READY_TO_SEND,RecoveryPhase.OUTCOME_UNKNOWN,RecoveryPhase.NEEDS_ATTENTION,
                RecoveryPhase.DEFINITIVELY_REJECTED,RecoveryPhase.BLOCKED_DEPENDENCY,RecoveryPhase.SERVER_CONFIRMED,
                RecoveryPhase.LOCAL_INTENT,RecoveryPhase.SENDING,RecoveryPhase.SCOPE_UNAVAILABLE).forEach {kind->
                Text(recoveryLabel(kind)+": "+scoped.count {recoveryPhase(it,all,recoveryVisible(it,data))==kind})
            }
        }
        Selector(stringResource(R.string.ir_filter),phase,listOf("" to stringResource(R.string.ir_all))+
            RecoveryPhase.entries.map {it.name to recoveryLabel(it)},!busy){phase=it;page=0}
        FlowRow {
            TextButton(enabled=!busy && !data.locked,onClick={model.inspectRecovery(incident=incidentFilter)}){Text(stringResource(R.string.ir_check))}
            TextButton(enabled=!busy && !data.locked,onClick=model::sync){Text(stringResource(R.string.h_sync_now))}
        }
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        failure?.let {FieldBanner(recoveryErrorText(it),FieldTone.WARNING)}
        if(rows.isEmpty())Text(stringResource(R.string.ir_empty))
        }
        LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            items(rows.drop(page*50).take(50),key={it.operation.operationId}) {op->
                val visible=recoveryVisible(op,data)
                val body=runCatching {parse(op.operation.payload)}.getOrDefault(kotlinx.serialization.json.JsonObject(emptyMap()))
                val incident=data.incidents.find {it.text("id")==body.text("incident")}
                val a=incident?.rows("assignments")?.find {it.text("id")==op.operation.entityId}
                OperationalCard {
                    Text(op.operation.operationId,style=MaterialTheme.typography.bodySmall)
                    StatusBadge(recoveryLabel(recoveryPhase(op,all,visible)),FieldTone.INFO)
                    Text(stringResource(R.string.ir_created,localDate(op.operation.createdAt)))
                    if(visible && incident!=null) {
                        Text(incident.text("reference"));StatusBadge(stringResource(if(incident.text("mode")=="TRAINING")R.string.field_training else R.string.ul_real),FieldTone.WARNING)
                    }
                    if(visible && body.text("rpc")=="incident_transition_task_assignment") {
                        Text(a?.obj("task")?.text("title").orEmpty());Text(a?.text("recipient_name").orEmpty())
                        Text(stringResource(R.string.ir_local_action,stateName(body.obj("payload").text("status"))))
                        Text(stringResource(R.string.ir_assignment,op.operation.entityId))
                    } else Text(stringResource(if(visible)R.string.ir_existing_flow else R.string.ir_scope))
                    op.parent?.let {parent->Text(stringResource(R.string.ir_parent,all.find {it.operation.sequence==parent}?.operation?.operationId ?: stringResource(R.string.ir_unavailable)))}
                    if(visible)op.error?.let {Text(recoveryErrorText(it))}
                    if(visible)TextButton(onClick={selected=op.operation.operationId}){Text(stringResource(R.string.ir_details))}
                }
            }
        }
        FlowRow {
            TextButton(enabled=page>0,onClick={page--}){Text(stringResource(R.string.im_previous))}
            TextButton(enabled=(page+1)*50<rows.size,onClick={page++}){Text(stringResource(R.string.im_next))}
        }
    }
    }
    selected?.let {id->all.find {it.operation.operationId==id && recoveryVisible(it,data)}?.let {op->
        val body=parse(op.operation.payload)
        val incident=data.incidents.find {it.text("id")==body.text("incident")}
        val assignment=incident?.rows("assignments")?.find {it.text("id")==op.operation.entityId}
        val isTask=body.text("rpc")=="incident_transition_task_assignment" && assignment!=null
        val uncertain=op.uncertain()
        AlertDialog(onDismissRequest={selected=null},title={Text(stringResource(R.string.ir_details))},text={
            Column(Modifier.heightIn(max=400.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text(op.operation.operationId);Text(recoveryLabel(recoveryPhase(op,all,true)))
                Text(stringResource(R.string.ir_created,localDate(op.operation.createdAt)))
                if(isTask) {
                    Text(assignment!!.obj("task").text("target_label_snapshot"));Text(assignment.text("recipient_name"))
                    Text(stringResource(R.string.ir_last_read,data.verifiedAt?.let(::localDate) ?: stringResource(R.string.ir_unavailable)))
                    Text(stringResource(R.string.ir_local_action,stateName(body.obj("payload").text("status"))))
                    Text(stringResource(R.string.ir_expected,op.request?.let(::parse)?.text("p_expected_version") ?: body.text("expected")))
                    Text(stringResource(R.string.ir_server_state,stateName(assignment!!.text("status")),assignment.text("version")))
                    Text(stringResource(R.string.ir_assignment,op.operation.entityId))
                }
                Text(stringResource(R.string.ir_no_delete))
                op.error?.let {Text(recoveryErrorText(it))}
                if(op.request!=null && body.text("rpc") in recoverableFieldRpcs)
                    TextButton(enabled=!busy,onClick={model.inspectRecovery(id)}){Text(stringResource(R.string.ir_check))}
                if(uncertain && op.error=="RECEIPT_ABSENT" && body.text("rpc") in listOf("incident_transition_task_assignment","incident_message_send"))
                    OutlinedButton(enabled=!busy,onClick={model.retryRecovery(id)}){Text(stringResource(R.string.ir_retry_exact))}
                if(isTask) {
                    TextButton(onClick={selected=null;openTask(body.text("incident"),op.operation.entityId)}){Text(stringResource(R.string.ir_open_task))}
                    TextButton(enabled=!busy,onClick={model.inspectRecovery(id);selected=null;correction=id}){Text(stringResource(R.string.ir_review))}
                }
                if(body.text("unit").isNotEmpty())TextButton(onClick={selected=null;openUnit(body.text("incident"),body.text("unit"))}){Text(stringResource(R.string.ul_title))}
            }
        },confirmButton={TextButton(onClick={selected=null}){Text(stringResource(R.string.h_back))}})
    } }
    correction?.let {id->all.find {it.operation.operationId==id && recoveryVisible(it,data)}?.let {op->
        val body=parse(op.operation.payload)
        val i=data.incidents.find {it.text("id")==body.text("incident")}
        val a=i?.rows("assignments")?.find {it.text("id")==op.operation.entityId}
        if(a!=null) {
            var choice by remember(id,a.text("version")) {mutableStateOf("")}
            var reason by remember(id) {mutableStateOf("")}
            val options=transitions(a.text("status"),a.obj("task").obj("configuration").flag("requires_acknowledgement"))
            AlertDialog(onDismissRequest={correction=null},title={Text(stringResource(R.string.ir_review))},text={
                Column(Modifier.heightIn(max=400.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    StatusBadge(recoveryLabel(recoveryPhase(op,all,true)),FieldTone.INFO)
                    Text(stringResource(R.string.ir_expected,op.request?.let(::parse)?.text("p_expected_version") ?: body.text("expected")))
                    Text(stringResource(R.string.ir_local_action,stateName(body.obj("payload").text("status"))))
                    Text(stringResource(R.string.ir_server_state,stateName(a.text("status")),a.text("version")))
                    FieldBanner(stringResource(R.string.ir_new_explanation),FieldTone.WARNING)
                    if(stale || syncFailure!=null)FieldBanner(stringResource(R.string.field_stale),FieldTone.WARNING)
                    failure?.let {FieldBanner(recoveryErrorText(it),FieldTone.WARNING)}
                    Selector(stringResource(R.string.ir_new_action),choice,options.map {it to stateName(it)},!busy){choice=it}
                    OutlinedTextField(reason,{reason=it.take(2000)},label={Text(stringResource(R.string.field_reason))})
                }
            },confirmButton={
                TextButton(enabled=!busy && !stale && syncFailure==null && failure==null && op.correctable() && a.flag("can_execute") && choice in options &&
                    (choice !in listOf("BLOCKED","UNABLE") || reason.isNotBlank()),onClick={
                    model.correctRecovery(body.text("incident"),op.operation.entityId,choice,reason,id,a.text("version")){correction=null;selected=null}
                }){Text(stringResource(R.string.ir_new_action))}
            },dismissButton={TextButton(onClick={correction=null}){Text(stringResource(R.string.h_back))}})
        }
    } }
}
