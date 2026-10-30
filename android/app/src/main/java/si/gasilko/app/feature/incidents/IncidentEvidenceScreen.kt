package si.gasilko.app.feature.incidents

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonObject
import si.gasilko.app.R
import si.gasilko.app.core.ui.*

internal data class EvidenceTarget(val kind: String,val id: String?)
@Composable
internal fun IncidentEvidenceScreen(model: IncidentViewModel,incidentId: String,target: EvidenceTarget,back: ()->Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val incident=state.incidents.find { it.text("id")==incidentId }
    val page=incident?.obj("attachment_pages")?.obj(target.kind+":"+target.id.orEmpty())
    val localParent=target.kind=="MESSAGE" && state.operations.any { it.operation.entityId==target.id &&
        it.operation.state!="SERVER_CONFIRMED" && parse(it.operation.payload).text("rpc") in listOf("incident_message_draft","incident_message_send") }
    val fieldTargetLost=target.kind=="TASK" && incident?.rows("assignments")?.none {
        it.obj("task").text("id")==target.id && it.text("status")!="CANCELLED" && it.obj("task").text("status")!="CANCELLED"
    }!=false
    val denied=fieldTargetLost || (!localParent && page?.flag("denied")==true) || (target.kind=="MESSAGE" && incident?.get("message_page") !is JsonObject)
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }
    var busy by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    var shown by remember { mutableStateOf(false) }
    var confirmAdd by remember { mutableStateOf(false) }
    var cameraId by remember { mutableStateOf<String?>(null) }
    val acquisitionScope=model.repository.account+"/"+model.organization+"/"+incidentId+"/"+target.kind+"/"+target.id.orEmpty()
    var acquisition by remember { mutableStateOf<String?>(null) }
    val pending=state.operations.filter { val body=parse(it.operation.payload)
        body.text("rpc")=="incident_attachment_prepare" && body.text("incident")==incidentId &&
        body.text("kind")==target.kind && body.text("target")==target.id.orEmpty() }
    fun action(block: suspend ()->Unit) {
        if(busy)return
        busy=true;failure=null
        job=scope.launch { try { block() } catch(e: CancellationException){throw e}
            catch(e: Exception){failure=(e as? EvidenceFailure)?.code ?: e.message}
            finally {busy=false} }
    }
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri->
        if(uri!=null && acquisition==acquisitionScope) { acquisition=null;action { model.repository.stageAttachment(model.organization,incidentId,target.kind,target.id,uri) } }
    }
    val camera=rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { accepted->
        val id=cameraId;cameraId=null
        if(id!=null)action {
            val inputs=si.gasilko.app.feature.photos.data.PhotoInputs(context)
            try { if(accepted)model.repository.stageAttachment(model.organization,incidentId,target.kind,target.id,inputs.cameraUri(id)) }
            finally { withContext(NonCancellable) { inputs.clear(id) } }
        }
    }
    LaunchedEffect(model,incidentId,target,incident?.text("revision"),state.verifiedAt,localParent) {
        if(!state.locked && incident!=null && !localParent)try { model.repository.attachmentPage(model.organization,incidentId,target.kind,target.id) }
        catch(e: CancellationException){throw e}
        catch(_: Exception){failure="STORAGE_TEMPORARILY_UNAVAILABLE"}
    }
    DisposableEffect(model,incidentId,target) { onDispose { job?.cancel();bitmap?.recycle() } }
    LaunchedEffect(state.locked,denied,incident?.text("message_access"),incident?.text("evidence_access_generation")) {
        job?.cancel();shown=false;bitmap?.recycle();bitmap=null
    }
    BackHandler(onBack=back)
    if(state.locked || incident==null || denied) {
        Column(Modifier.fillMaxSize().padding(16.dp)) {
            TextButton(onClick=back){Text(stringResource(R.string.h_back))}
            FieldBanner(stringResource(R.string.ev_denied),FieldTone.WARNING)
        }
        return
    }
    val canAdd=if(!localParent && page?.containsKey("can_add")==true)page.flag("can_add") else when(target.kind) {
        "TASK" -> incident.rows("assignments").any { it.obj("task").text("id")==target.id && it.flag("can_execute") }
        "MESSAGE" -> incident.obj("message_page").rows("messages").any { it.text("id")==target.id && it.text("sender_user_id")==model.repository.account && it.flag("can_correct") } ||
            state.operations.any { it.operation.entityId==target.id && parse(it.operation.payload).text("rpc") in listOf("incident_message_draft","incident_message_send") }
        else -> false
    }
    Column(Modifier.fillMaxSize().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        TextButton(onClick=back){Text(stringResource(R.string.h_back))}
        ScreenHeading(stringResource(R.string.ev_title))
        Text(incident.text("reference"));Text(stringResource(when(target.kind) { "TASK"->R.string.ev_task;"MESSAGE"->R.string.ev_message;else->R.string.ev_incident }))
        page?.obj("audience")?.takeIf { it.isNotEmpty() }?.let { audience->
            Text(stringResource(when(audience.text("kind")) {
                "UNIT"->R.string.mc_unit;"ORGANIZATION"->R.string.mc_organization;"MESSAGE"->R.string.ev_message;"TASK"->R.string.ev_task;else->R.string.mc_incident
            })+" · "+audience.text("id"))
        }
        FieldBanner(stringResource(R.string.ev_limits))
        Text(stringResource(R.string.ev_online_preview),style=MaterialTheme.typography.bodySmall)
        if(failure!=null)FieldBanner(stringResource(when {
            failure?.contains("TOO_LARGE")==true || failure?.contains("LIMIT")==true -> R.string.ev_limit_error
            failure?.contains("MALFORMED")==true || failure?.contains("UNSUPPORTED")==true -> R.string.ev_invalid
            failure?.contains("REVOKED")==true || failure?.contains("AUTHORIZED")==true -> R.string.ev_denied
            else -> R.string.ev_error
        }),FieldTone.WARNING)
        if(busy) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            TextButton(onClick={job?.cancel()}){Text(stringResource(R.string.ev_cancel))}
        }
        if(canAdd && incident.text("status") in listOf("ACTIVE","STABILIZED"))
            Button(enabled=!busy,onClick={confirmAdd=true}) { Text(stringResource(R.string.ev_add)) }
        TextButton(enabled=!busy,onClick={model.sync()}) { Text(stringResource(R.string.h_sync_now)) }
        LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
            items(pending.filter { it.operation.state!="SERVER_CONFIRMED" },key={it.operation.operationId}) { op->
                val metadata=parse(op.operation.payload).obj("metadata")
                OperationalCard {
                    Text(metadata.text("filename"));Text(metadata.text("mime")+" · "+metadata.text("size")+" B")
                    StatusBadge(stringResource(when(op.operation.state) { "NEEDS_ATTENTION"->R.string.ev_attention;"DRAFT"->R.string.ev_paused;"SENDING"->R.string.ev_uploading;else->R.string.ev_pending }),FieldTone.WARNING)
                    if(op.error?.contains("LOCAL")==true)Text(stringResource(R.string.ev_missing))
                    if(op.operation.state in listOf("NEEDS_ATTENTION","DRAFT"))TextButton(enabled=!busy,onClick={action {
                        model.repository.retryAttachment(model.organization,op.operation.operationId)
                    }}) { Text(stringResource(R.string.ev_retry)) }
                    else TextButton(enabled=!busy,onClick={action { model.repository.pauseAttachment(model.organization,op.operation.operationId) }}) { Text(stringResource(R.string.ev_pause)) }
                    Text(stringResource(R.string.ev_pause_note),style=MaterialTheme.typography.bodySmall)
                }
            }
            val rows=page?.rows("items").orEmpty()
            items(rows,key={it.text("id")}) { item->
                OperationalCard {
                    Text(item.text("filename"));Text(item.text("mime")+" · "+item.text("size")+" B")
                    Text(item.text("creator_user_id"));Text(item.text("created_at"))
                    StatusBadge(stringResource(when(item.text("status")) { "READY"->R.string.ev_ready;"REJECTED"->R.string.ev_attention;else->R.string.ev_pending }),
                        if(item.text("status")=="READY")FieldTone.SUCCESS else FieldTone.WARNING)
                    if(item.text("status")=="READY")OutlinedButton(enabled=!busy,onClick={action {
                        val bytes=model.repository.attachmentDownload(model.organization,incidentId,item.text("id"),target.kind,target.id)
                        require(evidenceHash(bytes)==item.text("sha256"))
                        if(item.text("mime")=="application/pdf") {
                            // Explicit system document viewer; a bounded in-memory pipe, never a public/durable file.
                            val uri=IncidentEvidenceProvider.grant(context,bytes)
                            try {
                                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/pdf")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),null))
                                delay(60_000)
                            } finally { IncidentEvidenceProvider.release(context,uri) }
                        } else {
                            val image=withContext(Dispatchers.IO) {
                                val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
                                BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
                                require(bounds.outWidth>0 && bounds.outHeight>0)
                                var sample=1
                                while(maxOf(bounds.outWidth,bounds.outHeight)/sample>2048)sample*=2
                                BitmapFactory.decodeByteArray(bytes,0,bytes.size,BitmapFactory.Options().apply { inSampleSize=sample })
                                    ?: error("ATTACHMENT_MALFORMED")
                            }
                            bitmap?.recycle();bitmap=image;shown=true
                        }
                    }}){Text(stringResource(R.string.ev_open))}
                }
            }
            if(rows.isEmpty() && pending.isEmpty())item { Text(stringResource(R.string.ev_empty)) }
            if(page?.flag("has_more")==true)item { TextButton(enabled=!busy,onClick={action {
                model.repository.attachmentPage(model.organization,incidentId,target.kind,target.id,true)
            }}){Text(stringResource(R.string.mc_older))} }
        }
    }
    if(confirmAdd)AlertDialog(onDismissRequest={confirmAdd=false},title={Text(stringResource(R.string.ev_add))},
        text={Text(stringResource(R.string.ev_confirm))},confirmButton={Column {
            TextButton(onClick={confirmAdd=false;acquisition=acquisitionScope;picker.launch(arrayOf("image/jpeg","image/webp","application/pdf"))}) { Text(stringResource(R.string.ev_choose)) }
            TextButton(onClick={confirmAdd=false;action {
                val inputs=si.gasilko.app.feature.photos.data.PhotoInputs(context)
                val id=java.util.UUID.randomUUID().toString()
                val uri=inputs.createCamera(id);cameraId=id
                camera.launch(uri)
            }}) { Text(stringResource(R.string.ev_camera)) }
        }},dismissButton={TextButton(onClick={confirmAdd=false}){Text(stringResource(R.string.h_back))}})
    if(shown && bitmap!=null)AlertDialog(onDismissRequest={shown=false;bitmap?.recycle();bitmap=null},
        title={Text(stringResource(R.string.ev_title))},text={Image(bitmap!!.asImageBitmap(),stringResource(R.string.ev_title),Modifier.fillMaxWidth())},
        confirmButton={TextButton(onClick={shown=false;bitmap?.recycle();bitmap=null}){Text(stringResource(R.string.h_back))}})
}
