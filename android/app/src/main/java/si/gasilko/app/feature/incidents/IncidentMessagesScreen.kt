package si.gasilko.app.feature.incidents

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
import kotlinx.serialization.json.*
import si.gasilko.app.R
import si.gasilko.app.core.ui.*
import java.util.UUID

@Composable
@OptIn(ExperimentalLayoutApi::class)
internal fun IncidentMessagesScreen(model: IncidentViewModel,incident: JsonObject,back: ()->Unit) {
    val data by model.state.collectAsStateWithLifecycle()
    val scope=rememberCoroutineScope()
    val id=incident.text("id")
    val page=incident.obj("message_page");val targets=page.rows("targets")
    val operations=data.operations.filter { parse(it.operation.payload).text("incident")==id &&
        parse(it.operation.payload).text("rpc") in listOf("incident_message_draft","incident_message_send") }
    val saved=operations.lastOrNull { it.operation.state=="DRAFT" }
    val savedPayload=saved?.let { parse(it.operation.payload) }
    var operation by remember(model,id) { mutableStateOf(saved?.operation?.operationId ?: UUID.randomUUID().toString()) }
    var target by remember(model,id) { mutableStateOf(savedPayload?.obj("draft_target") ?: JsonObject(emptyMap())) }
    var body by remember(model,id) { mutableStateOf(savedPayload?.obj("payload")?.text("body").orEmpty()) }
    var parent by remember(model,id) { mutableStateOf(savedPayload?.get("draft_parent") as? JsonObject) }
    var confirm by remember(model,id) { mutableStateOf(false) }
    var busy by remember(model,id) { mutableStateOf(false) }
    var error by remember(model,id) { mutableStateOf(false) }
    var history by remember(model,id) { mutableStateOf<List<JsonObject>?>(null) }
    val available=targets.any { it==target }
    val frozen=operations.any { it.operation.operationId==operation && it.operation.state!="DRAFT" }
    val live=incident.text("status") in listOf("ACTIVE","STABILIZED")
    // Editable pre-send drafts only. A submitted operation is never edited or rebased.
    LaunchedEffect(model,id,operation,target,body,parent) {
        if((body.isNotEmpty() || operations.any { it.operation.operationId==operation && it.operation.state=="DRAFT" }) && available && !frozen) {
            try { model.repository.saveMessageDraft(model.organization,id,operation,target,body,parent) }
            catch(e: CancellationException) { throw e }
            catch(_: Exception) { error=true }
        }
    }
    fun perform(block: suspend ()->Unit) {
        if(busy)return
        busy=true;error=false
        scope.launch { try { block() } catch(e: CancellationException) { throw e }
            catch(_: Exception) { error=true } finally { busy=false } }
    }
    BackHandler(onBack=back)
    if(incident["message_page"] !is JsonObject || (target.isNotEmpty() && !available && body.isNotEmpty())) {
        Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
            ScreenHeading(stringResource(R.string.mc_title))
            FieldBanner(stringResource(R.string.mc_message_hidden),FieldTone.WARNING)
            if(incident["message_page"] is JsonObject)TextButton(onClick={
                operation=UUID.randomUUID().toString();target=JsonObject(emptyMap());body="";parent=null;history=null;confirm=false
            }) { Text(stringResource(R.string.mc_new_draft)) }
            TextButton(onClick=model::sync) { Text(stringResource(R.string.h_sync_now)) }
        }
        return
    }
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        TextButton(onClick=back) { Text(stringResource(R.string.h_back)) }
        ScreenHeading(stringResource(R.string.mc_title));Text(incident.text("reference")+" · "+incident.text("title"))
        if(incident.text("mode")=="TRAINING")FieldBanner(stringResource(R.string.field_training))
        FieldBanner(stringResource(R.string.mc_warning))
        if(error)FieldBanner(stringResource(R.string.mc_error),FieldTone.WARNING)
        if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(12.dp)) {
            item {
                Text(stringResource(R.string.mc_scope))
                FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    targets.forEach { option ->
                        FilterChip(selected=target==option,enabled=!busy && !frozen && parent==null,
                            onClick={target=option;confirm=false},label={Text(audienceName(option.text("kind"))+" · "+option.text("label"))})
                    }
                }
                if(!live || targets.isEmpty())Text(stringResource(R.string.mc_disabled))
                OutlinedTextField(body,{ if(it.codePointCount(0,it.length)<=4000)body=it },label={Text(stringResource(R.string.mc_body))},
                    modifier=Modifier.fillMaxWidth(),enabled=live && !busy && !frozen)
                Text(stringResource(R.string.mc_remaining,4000-body.codePointCount(0,body.length)))
                if(available)Text(audienceName(target.text("kind"))+" · "+target.text("label"))
                Row {
                    Checkbox(checked=confirm,onCheckedChange={confirm=it},enabled=!busy && !frozen)
                    Text(stringResource(R.string.mc_confirm))
                }
                Button(enabled=live && available && confirm && body.isNotBlank() && !busy && !frozen,onClick={
                    perform {
                        model.repository.queueMessage(model.organization,id,target,body,parent,operation)
                        body="";parent=null;confirm=false;operation=UUID.randomUUID().toString()
                    }
                }) { Text(stringResource(R.string.mc_send)) }
            }
            items(operations.filter { it.operation.state!="SERVER_CONFIRMED" },key={it.operation.operationId}) { op ->
                val value=parse(op.operation.payload)
                val request=value.obj("payload")
                val allowed=if(op.operation.state=="DRAFT")targets.any { it==value.obj("draft_target") } else targets.any {
                    it.text("kind")==request.text("audience_kind") && when(it.text("kind")) {
                        "UNIT" -> it.text("id")==request.text("audience_unit_assignment_id")
                        "ORGANIZATION" -> it.text("id")==request.text("audience_org_id")
                        else -> true
                    }
                }
                OperationalCard {
                    Text(stringResource(when(op.operation.state) {
                        "DRAFT" -> R.string.mc_draft
                        "SERVER_CONFIRMED" -> R.string.mc_sent
                        "NEEDS_ATTENTION" -> R.string.mc_attention
                        else -> R.string.mc_pending
                    }))
                    if(allowed && page.rows("messages").none { it.text("id")==op.operation.entityId })Text(request.text("body"))
                    if(allowed && op.operation.state=="DRAFT")TextButton(enabled=!busy,onClick={
                        operation=op.operation.operationId;target=value.obj("draft_target");body=request.text("body")
                        parent=value["draft_parent"] as? JsonObject;confirm=false
                    }) { Text(stringResource(R.string.mc_resume)) }
                }
            }
            if(page.rows("messages").isEmpty())item { Text(stringResource(R.string.mc_empty)) }
            items(page.rows("messages"),key={it.text("id")}) { message ->
                OperationalCard {
                    Text(message.text("sender_name")+" · "+message.text("sent_at"))
                    Text(audienceName(message.text("audience_kind")));Text(message.text("body"))
                    if(message.text("supersedes_id").isNotEmpty())Text(stringResource(R.string.mc_corrected))
                    TextButton(enabled=!busy,onClick={perform {
                        history=model.repository.messageHistory(model.organization,id,message.text("id")).rows("messages")
                    }}) { Text(stringResource(R.string.mc_history)) }
                    if(message.flag("can_correct") && message.text("sender_user_id")==model.repository.account)
                        TextButton(enabled=!busy,onClick={
                            val option=targets.find { it.text("kind")==message.text("audience_kind") && when(it.text("kind")) {
                                "UNIT" -> it.text("id")==message.text("audience_unit_assignment_id")
                                "ORGANIZATION" -> it.text("id")==message.text("audience_org_id")
                                else -> true
                            } }
                            if(option!=null) {
                                operation=UUID.randomUUID().toString();target=option;parent=message;body=message.text("body");confirm=false
                            }
                        }) { Text(stringResource(R.string.mc_correct)) }
                }
            }
            if(page.flag("has_more"))item {
                TextButton(enabled=!busy,onClick={perform { model.repository.olderMessages(model.organization,id) }}) {
                    Text(stringResource(R.string.mc_older))
                }
            }
        }
        history?.let { rows ->
            AlertDialog(onDismissRequest={history=null},title={Text(stringResource(R.string.mc_history))},
                text={LazyColumn { items(rows,key={it.text("id")}) { old ->
                    Text(old.text("sent_at"));Text(old.text("body"))
                    if(old.text("supersedes_id").isNotEmpty())TextButton(enabled=!busy,onClick={perform {
                        history=model.repository.messageHistory(model.organization,id,old.text("supersedes_id")).rows("messages")
                    }}) { Text(stringResource(R.string.mc_older)) }
                } }},confirmButton={TextButton(onClick={history=null}) { Text(stringResource(R.string.h_back)) }})
        }
    }
}
@Composable private fun audienceName(kind: String)=stringResource(when(kind) {
    "ORGANIZATION" -> R.string.mc_organization
    "UNIT" -> R.string.mc_unit
    else -> R.string.mc_incident
})
