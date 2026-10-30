package si.gasilko.app.feature.incidents

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import androidx.room.withTransaction
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.storage.storage
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import si.gasilko.app.core.auth.KeystoreSessionManager
import si.gasilko.app.core.database.*
import si.gasilko.app.core.sync.HydrantSyncScheduler
import si.gasilko.app.feature.hydrants.data.hydrantRemoteAccess
import si.gasilko.app.feature.hydrants.domain.*
import java.math.BigInteger
import java.util.UUID

internal fun JsonObject.text(key: String)=(get(key) as? JsonPrimitive)?.contentOrNull.orEmpty()
internal fun JsonObject.flag(key: String)=(get(key) as? JsonPrimitive)?.booleanOrNull==true
internal fun JsonObject.obj(key: String)=(get(key) as? JsonObject) ?: JsonObject(emptyMap())
internal fun JsonObject.rows(key: String)=(get(key) as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
internal fun parse(value: String)=Json.parseToJsonElement(value).jsonObject
/** Serialize credential-changing UI actions with authenticated field requests. */
internal val incidentIdentityAccess=kotlinx.coroutines.sync.Mutex()
internal class MessageAccessFailure(val reason: String): IllegalStateException("MESSAGE_UNAVAILABLE")
private val evidenceGenerations=mutableMapOf<String,Long>() // guarded by incidentIdentityAccess
private val messageGenerations=mutableMapOf<String,Long>() // guarded by incidentIdentityAccess
private val activeDispatches=MutableStateFlow<Set<String>>(emptySet())
internal val terminal=setOf("COMPLETED","UNABLE","CANCELLED")
internal fun transitions(status: String,ack: Boolean)=when(status) {
    "ISSUED"->if(ack)listOf("ACKNOWLEDGED","UNABLE") else listOf("ACKNOWLEDGED","IN_PROGRESS","UNABLE")
    "ACKNOWLEDGED"->listOf("IN_PROGRESS","UNABLE")
    "IN_PROGRESS"->listOf("BLOCKED","COMPLETED")
    "BLOCKED"->listOf("IN_PROGRESS","UNABLE")
    else->emptyList()
}
/** A confirmed event can be newer than the last snapshot after an interrupted read.
 * It may order new local intent, but never substitutes for an authoritative version. */
internal fun unreconciledReceipt(assignment: JsonObject,op: FieldOperation?): Boolean {
    if(op?.operation?.state!="SERVER_CONFIRMED")return false
    val revision=op.result?.let(::parse)?.text("revision")?.toLongOrNull() ?: return false
    return revision>(assignment.text("changed_revision").toLongOrNull() ?: -1L)
}
data class IncidentFieldState(val incidents: List<JsonObject> = emptyList(),val operations: List<FieldOperation> = emptyList(),
    val locked: Boolean=true,val warning: Boolean=false,val verifiedAt: Long?=null)

/** Captures one authenticated identity. Scope checks also run after every network suspension. */
class IncidentRepository(private val context: Context,private val client: SupabaseClient,
    val account: String,private val remainingAuthorization: suspend (String)->Long) {
    private val db=RegistryDatabase.open(context)
    private val dao=db.incidents()
    private val scheduler=HydrantSyncScheduler(context)
    private val secure=KeystoreSessionManager(context)
    private val refreshFailure=MutableStateFlow<String?>(null)
    val syncFailure=refreshFailure.asStateFlow()
    private fun boot()=Settings.Global.getInt(context.contentResolver,Settings.Global.BOOT_COUNT,-1)
    private suspend fun scope(org: String): Long {
        if(client.auth.currentUserOrNull()?.id!=account || !scheduler.selected(account,org))throw CancellationException()
        return remainingAuthorization(org).also { if(it<=0)throw RegistryFailure(RegistryError.EXPIRED) }
    }
    private suspend fun lease(org: String,row: IncidentFieldCache?): Long {
        val remaining=scope(org)
        if(row==null)return 0
        val saved=secure.loadIncidentLease(account,org)?.let(::parse) ?: return 0
        if(saved.text("wall")!=row.verifiedAt.toString() || saved.text("elapsed")!=row.elapsed.toString() ||
            saved.text("boot")!=row.boot.toString())return 0
        val wall=System.currentTimeMillis()-row.verifiedAt
        val elapsed=SystemClock.elapsedRealtime()-row.elapsed
        if(boot()<0 || boot()!=row.boot || wall<0 || elapsed<0)return 0
        return minOf(remaining,86_400_000L-maxOf(wall,elapsed))
    }
    fun observe(org: String): Flow<IncidentFieldState> {
        val ticks=flow { while(true) { emit(Unit);delay(5_000) } }
        return combine(dao.observe(account,org),dao.observeOperations(account,org),ticks,activeDispatches) { row,ops,_,active ->
            try {
                val left=lease(org,row)
                if(left<=0)IncidentFieldState() else IncidentFieldState(parse(row!!.payload).rows("incidents"),ops.map { op ->
                    if(op.operation.state=="SENDING" && "$account/$org/${op.operation.operationId}" !in active)op.copy(operation=op.operation.copy(state="OUTCOME_UNKNOWN")) else op
                },false,left<=7_200_000,row.verifiedAt)
            } catch(e: CancellationException) { throw e } catch(_: Exception) { IncidentFieldState() }
        }
    }
    private suspend fun revoke(org: String)=incidentIdentityAccess.withLock {
        for(i in dao.snapshot(account,org)?.let { parse(it.payload).rows("incidents") }.orEmpty()) {
            val key="$account/$org/"+i.text("id")
            evidenceGenerations[key]=(evidenceGenerations[key] ?: 0L)+1
        }
        secure.clearIncidentLease(account,org)
        db.withTransaction {
            dao.revoke(account,org);dao.clearCursors(account,org)
        } // Pending operations and immutable payloads are retained.
    }
    private suspend fun rpc(name: String,request: JsonObject): JsonObject = incidentIdentityAccess.withLock {
        scope(request.text("p_acting_organization_id").ifEmpty { request.text("p_organization_id") })
        currentCoroutineContext().ensureActive()
        client.postgrest.rpc(name,request).decodeAs<JsonObject>()
    }
    suspend fun refresh(org: String)=hydrantRemoteAccess.withLock { refreshLocked(org) }
    private suspend fun revokeIncident(org: String,id: String)=incidentIdentityAccess.withLock {
        val key="$account/$org/$id"
        evidenceGenerations[key]=(evidenceGenerations[key] ?: 0L)+1
        db.withTransaction {
        dao.snapshot(account,org)?.let { row ->
            val value=parse(row.payload)
            dao.save(row.copy(payload=JsonObject(value+("incidents" to JsonArray(
                value.rows("incidents").filterNot { it.text("id")==id }))).toString()))
        }
        dao.removeCursor(account,org,id)
        }
    }
    private suspend fun invalidateMessages(org: String,id: String,reason: String) = incidentIdentityAccess.withLock {
        scope(org);currentCoroutineContext().ensureActive()
        val key="$account/$org/$id"
        messageGenerations[key]=(messageGenerations[key] ?: 0L)+1
        evidenceGenerations[key]=(evidenceGenerations[key] ?: 0L)+1
        var hadPage=false
        db.withTransaction {
            dao.snapshot(account,org)?.let { row ->
                val root=parse(row.payload)
                hadPage=root.rows("incidents").any { it.text("id")==id && it["message_page"] is JsonObject }
                dao.save(row.copy(payload=JsonObject(root+("incidents" to JsonArray(root.rows("incidents").map {
                    if(it.text("id")==id)JsonObject((it-"message_page")+("attachment_pages" to JsonObject(it.obj("attachment_pages").filterKeys { key -> !key.startsWith("MESSAGE:") }))+("message_access" to JsonPrimitive(reason))) else it
                }))).toString()))
            }
        }
        hadPage
    }
    private suspend fun refreshLocked(org: String) {
        scope(org)
        try {
            val previous=dao.snapshot(account,org)
            val reconciler=IncidentReconciliation(account,org,
                { name,request -> if(name=="incident_message_page")messageRead(org,request.text("p_incident_id"),name,request)
                    else rpc(name,request).also { scope(org) } },
                { id -> revokeIncident(org,id) })
            val staged=reconciler.reconcile(previous?.let { parse(it.payload).rows("incidents") }.orEmpty(),dao.cursors(account,org))
            scope(org)
            val payload=buildJsonObject {
                put("account",account);put("organization",org);put("incidents",JsonArray(staged.incidents))
            }
            val row=IncidentFieldCache(account,org,payload.toString(),System.currentTimeMillis(),SystemClock.elapsedRealtime(),boot())
            // Account changes cannot cross this final authorization + atomic cache/cursor commit.
            incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                for(i in staged.incidents)if(i["message_page"] is JsonObject) {
                    check(i.obj("message_page").text("_cache_generation")==
                        (messageGenerations["$account/$org/"+i.text("id")] ?: 0L).toString()) { "STALE" }
                }
                // Saving lease first fails closed if Room commit is interrupted.
                secure.saveIncidentLease(account,org,buildJsonObject {
                    put("wall",row.verifiedAt);put("elapsed",row.elapsed);put("boot",row.boot)
                }.toString())
                db.withTransaction {
                    scope(org)
                    val safe=parse(row.payload)
                    val guarded=JsonObject(safe+("incidents" to JsonArray(safe.rows("incidents").map { i->
                        val generation=(evidenceGenerations["$account/$org/"+i.text("id")] ?: 0L).toString()
                        val pages=i.obj("attachment_pages").filter { (key,page)->
                            val value=page as? JsonObject
                            value?.text("_generation")==generation &&
                                (key.startsWith("MESSAGE:").not() || i["message_page"] is JsonObject)
                        }
                        if(i.text("status") in listOf("ACTIVE","STABILIZED"))JsonObject(i+("attachment_pages" to JsonObject(pages)))
                        else JsonObject(i-"attachment_pages")
                    })))
                    dao.save(row.copy(payload=guarded.toString()));dao.clearCursors(account,org);dao.saveCursors(staged.cursors)
                }
            }
            if(!staged.caughtUp)throw FieldProtocolFailure("STALE")
            refreshFailure.value=null
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            val message=e.message.orEmpty()
            val denied=(e is RestException && e.statusCode in listOf(401,403)) || "NOT_AUTHORIZED" in message
            if(denied)revoke(org)
            refreshFailure.value=when {
                denied -> "ACCESS"
                "SCOPE_CHANGED" in message -> "SCOPE"
                "MANIFEST_EXPIRED" in message || "MANIFEST_NOT_FOUND" in message -> "MANIFEST"
                "SNAPSHOT_TOO_LARGE" in message || "FIELD_SNAPSHOT_LIMIT" in message || "SNAPSHOT_CAPACITY" in message -> "CAPACITY"
                "PGRST202" in message || "SCHEMA" in message || "PROTOCOL" in message || "MANIFEST_INCOMPLETE" in message -> "PROTOCOL"
                "lock timeout" in message || "55P03" in message -> "BUSY"
                "RESET_REQUIRED" in message || "STALE" in message -> "STALE"
                e is java.io.IOException || e is io.ktor.client.plugins.HttpRequestTimeoutException -> "NETWORK"
                else -> "SERVER"
            }
            android.util.Log.d("IncidentSync","refresh failure category="+refreshFailure.value)
            throw e
        }
    }
    private fun payload(op: FieldOperation)=parse(op.operation.payload)
    private suspend fun attention(org: String,op: FieldOperation,code: String) = db.withTransaction {
        dao.outcome(op.operation.sequence,op.result,code)
        dao.state(account,org,op.operation.sequence,"NEEDS_ATTENTION")
    }
    private suspend fun request(org: String,op: FieldOperation): String? {
        op.request?.let { return it } // Already prepared: never rebase, including an unknown outcome.
        val body=payload(op)
        val parent=op.parent?.let { id -> dao.operations(account,org).find { it.operation.sequence==id } }
        if(op.parent!=null && parent==null) { attention(org,op,"DEPENDENCY_MISSING");return null }
        if(parent!=null && parent.operation.state!="SERVER_CONFIRMED")return null
        val expected=if(parent!=null) {
            // Canonical receipt confirms the operation, but contains aggregate versions,
            // not assignment.version. Read it authoritatively; never guess expected + 1.
            refreshLocked(org)
            val incident=dao.snapshot(account,org)?.let { parse(it.payload).rows("incidents")
                .find { i -> i.text("id")==body.text("incident") } }
            val assignment=incident?.rows("assignments")?.find { it.text("id")==op.operation.entityId }
            val receipt=parent.result?.let(::parse)
            val parentIntent=payload(parent)
            if(assignment==null || !assignment.flag("can_execute") ||
                parent.operation.entityId!=op.operation.entityId || parentIntent.text("incident")!=body.text("incident") ||
                receipt==null || receipt.text("operation_id")!=parent.operation.operationId ||
                receipt.text("task_id")!=body.text("task") || receipt.text("incident_id")!=body.text("incident") ||
                assignment.text("changed_revision")!=receipt.text("revision") ||
                assignment.text("status")!=parentIntent.obj("payload").text("status") ||
                body.obj("payload").text("status") !in transitions(assignment.text("status"),
                    assignment.obj("task").obj("configuration").flag("requires_acknowledgement"))) {
                attention(org,op,"DEPENDENCY_CHANGED");return null
            }
            assignment.text("version")
        } else body.text("expected")
        return buildJsonObject {
            put("p_operation",op.operation.operationId);put("p_acting_organization_id",org)
            put("p_incident_id",body.text("incident"));put("p_expected_version",JsonPrimitive(BigInteger(expected).longValueExact()))
            put("p_payload",body.obj("payload"))
        }.toString().also { dao.prepare(op.operation.sequence,it) }
    }
    suspend fun transition(org: String,incident: String,assignment: String,status: String,reason: String) =
        hydrantRemoteAccess.withLock {
            scope(org)
            val row=dao.snapshot(account,org)
            require(lease(org,row)>0)
            val i=parse(row!!.payload).rows("incidents").single { it.text("id")==incident }
            val a=i.rows("assignments").single { it.text("id")==assignment }
            require(a.flag("can_execute"))
            val previous=dao.operations(account,org).lastOrNull { it.operation.entityId==assignment }
            require(previous?.operation?.state!="NEEDS_ATTENTION")
            val pending=previous?.takeIf { it.operation.state!="SERVER_CONFIRMED" || unreconciledReceipt(a,it) }
            val effective=pending?.let { payload(it).obj("payload").text("status") } ?: a.text("status")
            require(status in transitions(effective,a.obj("task").obj("configuration").flag("requires_acknowledgement")))
            require(reason.length<=2000 && (status !in listOf("BLOCKED","UNABLE") || reason.isNotBlank()))
            val intent=buildJsonObject {
                put("incident",incident);put("task",a.obj("task").text("id"));put("expected",a.text("version"))
                put("rpc","incident_transition_task_assignment")
                put("payload",buildJsonObject { put("id",assignment);put("status",status);put("reason",reason.trim()) })
            }
            db.withTransaction {
                val sequence=db.registry().enqueue(PendingHydrantChange(operationId=UUID.randomUUID().toString(),account=account,
                    organization=org,entityId=assignment,operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,
                    createdAt=System.currentTimeMillis(),state="LOCAL_PENDING"))
                dao.dispatch(IncidentDispatch(sequence,pending?.operation?.sequence,null))
            }
            scheduler.enqueue(account,org)
        }
    /** Same existing WorkManager/mutex. One failed assignment never stalls an independent assignment. */
    suspend fun synchronize(org: String): Boolean=hydrantRemoteAccess.withLock {
        scope(org)
        if(dao.snapshot(account,org)==null && dao.operations(account,org).isEmpty())return@withLock false
        var retry=false
        for(op in dao.operations(account,org)) {
            if(payload(op).text("rpc")=="incident_attachment_prepare") {
                if(op.operation.state !in listOf("SERVER_CONFIRMED","NEEDS_ATTENTION","DRAFT"))
                    if(!syncAttachment(org,op))retry=true
                continue
            }
            if(op.operation.state in listOf("SERVER_CONFIRMED","NEEDS_ATTENTION") ||
                payload(op).text("rpc") !in listOf("incident_transition_task_assignment","incident_message_send"))continue
            val parent=op.parent?.let { id -> dao.operations(account,org).find { it.operation.sequence==id } }
            if(parent?.operation?.state=="NEEDS_ATTENTION") {
                dao.state(account,org,op.operation.sequence,"NEEDS_ATTENTION")
                dao.outcome(op.operation.sequence,null,"DEPENDENCY_REJECTED");continue
            }
            try {
                val prepared=request(org,op) ?: continue
                if(!send(org,op,prepared))retry=true
            } catch(e: CancellationException) { throw e }
            catch(_: RestException) { retry=true } // A failed reconciliation is not a rejected child command.
            catch(_: java.io.IOException) { retry=true }
            catch(_: io.ktor.client.plugins.HttpRequestTimeoutException) { retry=true }
            catch(_: Exception) { retry=true }
        }
        try { refreshLocked(org) } catch(e: CancellationException) { throw e }
        catch(e: RestException) { if(e.statusCode>=500 || e.statusCode in listOf(408,429))retry=true }
        catch(_: Exception) { retry=true }
        retry
    }
    private suspend fun send(org: String,op: FieldOperation,request: String): Boolean {
        scope(org)
        dao.state(account,org,op.operation.sequence,"SENDING")
        val dispatchKey="$account/$org/${op.operation.operationId}"
        activeDispatches.update { it+dispatchKey }
        val result=try {
            rpc(payload(op).text("rpc"),parse(request))
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            val rejected=e is RestException && e.statusCode in 400..499 && e.statusCode !in listOf(408,429)
            db.withTransaction {
                dao.state(account,org,op.operation.sequence,if(rejected)"NEEDS_ATTENTION" else "OUTCOME_UNKNOWN")
                dao.outcome(op.operation.sequence,null,if(rejected) {
                    if(payload(op).text("unit").isNotEmpty())leaderError(e.message) else if(op.operation.state in listOf("SENDING","OUTCOME_UNKNOWN"))"RECOVERY_REJECTED" else "SERVER_REJECTED"
                } else "TRANSPORT_UNCERTAIN")
            }
            if(e is RestException && e.statusCode==401)revoke(org)
            else if(e is RestException && e.statusCode==403) {
                val unit=payload(op).text("unit")
                if(unit.isNotEmpty())invalidateLeader(org,payload(op).text("incident"),unit) else revoke(org)
            }
            return rejected
        } finally { activeDispatches.update { it-dispatchKey } }
        // A receipt proves this operation committed, not a fabricated current assignment
        // state/version. Cache reconciliation failures must never turn success into rejection.
        if(result.text("operation_id")!=op.operation.operationId || result.text("incident_id")!=payload(op).text("incident") ||
            (payload(op).text("rpc")=="incident_transition_task_assignment" && result.text("task_id")!=payload(op).text("task")) ||
            (payload(op).text("rpc")=="incident_message_send" && result.text("message_id")!=op.operation.entityId) ||
            (payload(op).text("rpc")=="incident_issue_task" && result.text("task_id")!=op.operation.entityId)) {
            dao.state(account,org,op.operation.sequence,"OUTCOME_UNKNOWN")
            dao.outcome(op.operation.sequence,null,"RECEIPT_UNCERTAIN")
            return false
        }
        db.withTransaction {
            dao.outcome(op.operation.sequence,result.toString(),null)
            dao.state(account,org,op.operation.sequence,"SERVER_CONFIRMED")
        }
        return true
    }
    suspend fun returnUnit(org: String,incident: String,unit: String,operation: String): Boolean=hydrantRemoteAccess.withLock {
        scope(org)
        var op=dao.operations(account,org).find { it.operation.operationId==operation }
        if(op==null) {
            refreshLocked(org)
            val i=parse(dao.snapshot(account,org)!!.payload).rows("incidents").single { it.text("id")==incident }
            val u=i.rows("units").single { it.text("id")==unit }
            require(u.flag("can_return"))
            val intent=buildJsonObject {
                put("incident",incident);put("expected",i.text("version"));put("rpc","incident_update_unit_status")
                put("payload",buildJsonObject { put("id",unit);put("version",u.text("version"));put("status","RETURNING") })
            }
            db.withTransaction {
                val sequence=db.registry().enqueue(PendingHydrantChange(operationId=operation,account=account,organization=org,
                    entityId=unit,operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,createdAt=System.currentTimeMillis(),state="LOCAL_PENDING"))
                dao.dispatch(IncidentDispatch(sequence,null,null))
            }
            op=dao.operations(account,org).single { it.operation.operationId==operation }
        }
        if(op.operation.state=="NEEDS_ATTENTION")return@withLock false
        if(op.operation.state=="SERVER_CONFIRMED")return@withLock true
        val sent=send(org,op,request(org,op)!!)
        if(sent)refreshLocked(org)
        dao.operations(account,org).single { it.operation.operationId==operation }.operation.state=="SERVER_CONFIRMED"
    }
    suspend fun queueMessage(org: String,incident: String,target: JsonObject,body: String,parent: JsonObject?,draftOperation: String) =
        hydrantRemoteAccess.withLock {
            scope(org)
            val row=dao.snapshot(account,org)
            require(lease(org,row)>0)
            val i=parse(row!!.payload).rows("incidents").single { it.text("id")==incident }
            require(i.text("status") in listOf("ACTIVE","STABILIZED"))
            require(i.obj("message_page").rows("targets").any { it==target })
            val normalized=body.replace("\r\n","\n").replace("\r","\n").trim()
            require(normalized.isNotEmpty() && normalized.codePointCount(0,normalized.length)<=4000)
            val existing=dao.operations(account,org).find { it.operation.operationId==draftOperation }
            if(existing!=null && existing.operation.state!="DRAFT")return@withLock
            val id=existing?.operation?.entityId ?: UUID.randomUUID().toString()
            val request=buildJsonObject {
                put("id",id);put("body",normalized);put("audience_kind",target.text("kind"))
                if(target.text("kind")=="ORGANIZATION")put("audience_org_id",target.text("id"))
                if(target.text("kind")=="UNIT")put("audience_unit_assignment_id",target.text("id"))
                if(parent!=null) {
                    require(parent.text("sender_user_id")==account && parent.flag("can_correct"))
                    require(parent.text("audience_kind")==target.text("kind"))
                    require(when(target.text("kind")) {
                        "ORGANIZATION" -> parent.text("audience_org_id")==target.text("id")
                        "UNIT" -> parent.text("audience_unit_assignment_id")==target.text("id")
                        else -> true
                    })
                    put("supersedes_id",parent.text("id"));put("parent_version",parent.text("version"))
                }
            }
            val intent=buildJsonObject {
                put("incident",incident);put("expected",i.text("version"));put("rpc","incident_message_send");put("payload",request)
            }
            db.withTransaction {
                if(existing!=null) {
                    check(dao.updateMessageDraft(account,org,draftOperation,intent.toString(),"LOCAL_PENDING")==1)
                } else {
                val seq=db.registry().enqueue(PendingHydrantChange(operationId=draftOperation,account=account,
                    organization=org,entityId=id,operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,
                    createdAt=System.currentTimeMillis(),state="LOCAL_PENDING"))
                dao.dispatch(IncidentDispatch(seq,null,null))
                }
            }
            scheduler.enqueue(account,org)
        }
    suspend fun saveMessageDraft(org: String,incident: String,operation: String,target: JsonObject,body: String,parent: JsonObject?) =
        hydrantRemoteAccess.withLock {
            scope(org)
            val row=dao.snapshot(account,org)
            require(lease(org,row)>0 && body.codePointCount(0,body.length)<=4000)
            val i=parse(row!!.payload).rows("incidents").single { it.text("id")==incident }
            require(i.obj("message_page").rows("targets").any { it==target })
            val existing=dao.operations(account,org).find { it.operation.operationId==operation }
            if(existing!=null && existing.operation.state!="DRAFT")return@withLock
            val id=existing?.operation?.entityId ?: UUID.randomUUID().toString()
            val intent=buildJsonObject {
                put("rpc","incident_message_draft");put("incident",incident)
                put("draft_target",target);put("draft_parent",parent ?: JsonNull)
                put("payload",buildJsonObject { put("id",id);put("body",body) })
            }.toString()
            db.withTransaction {
                scope(org)
                if(existing!=null)dao.updateMessageDraft(account,org,operation,intent,"DRAFT") else {
                    val seq=db.registry().enqueue(PendingHydrantChange(operationId=operation,account=account,
                        organization=org,entityId=id,operation="INCIDENT_TASK",payload=intent,baseVersion=null,
                        createdAt=System.currentTimeMillis(),state="DRAFT"))
                    dao.dispatch(IncidentDispatch(seq,null,null))
                }
            }
        }
    private suspend fun messageRead(org: String,incident: String,name: String,args: JsonObject): JsonObject {
        val key="$account/$org/$incident"
        val generation=incidentIdentityAccess.withLock { scope(org);messageGenerations[key] ?: 0L }
        try {
            val value=rpc(name,args)
            return incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                if((messageGenerations[key] ?: 0L)!=generation)throw FieldProtocolFailure("STALE")
                JsonObject(value+("_cache_generation" to JsonPrimitive(generation.toString())))
            }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            if(e is RestException && e.statusCode==401) { revoke(org);throw e }
            val changed="SCOPE_CHANGED" in e.message.orEmpty()
            val denied="NOT_AUTHORIZED" in e.message.orEmpty() || (e is RestException && e.statusCode==403)
            if(changed || denied) {
                if(invalidateMessages(org,incident,if(changed)"SCOPE_CHANGED" else "DENIED"))
                    si.gasilko.app.core.notifications.NotificationTap.hint()
                throw MessageAccessFailure(if(changed)"SCOPE_CHANGED" else "DENIED")
            }
            throw e
        }
    }
    suspend fun messageHistory(org: String,incident: String,id: String): JsonObject {
        scope(org)
        val value=messageRead(org,incident,"incident_message_history",buildJsonObject {
            put("p_acting_organization_id",org);put("p_incident_id",incident);put("p_message_id",id)
        })
        scope(org);return value
    }
    suspend fun olderMessages(org: String,incident: String)=hydrantRemoteAccess.withLock {
        scope(org)
        val row=dao.snapshot(account,org) ?: return@withLock
        require(lease(org,row)>0)
        val root=parse(row.payload);val current=root.rows("incidents").single { it.text("id")==incident }
        val page=current.obj("message_page")
        if(!page.flag("has_more"))return@withLock
        val next=messageRead(org,incident,"incident_message_page",buildJsonObject {
            put("p_acting_organization_id",org);put("p_incident_id",incident);put("p_before_sent_at",page.text("next_sent_at"))
            put("p_before_id",page.text("next_id"));put("p_limit",30)
            put("p_expected_revision",current.text("revision"));put("p_scope_fingerprint",page.text("scope_fingerprint"))
        })
        scope(org)
        check(next.text("account")==account && next.text("organization")==org && next.text("incident_id")==incident &&
            next.text("revision")==current.text("revision") && next.text("scope_fingerprint")==page.text("scope_fingerprint"))
        val combined=(page.rows("messages")+next.rows("messages")).distinctBy { it.text("id") }.take(100)
        val updated=JsonObject(next+("messages" to JsonArray(combined))+("has_more" to JsonPrimitive(combined.size<100 && next.flag("has_more"))))
        incidentIdentityAccess.withLock {
            scope(org)
            check(next.text("_cache_generation")==(messageGenerations["$account/$org/$incident"] ?: 0L).toString()) { "STALE" }
            db.withTransaction {
                dao.save(row.copy(payload=JsonObject(root+("incidents" to JsonArray(root.rows("incidents").map {
                    if(it.text("id")==incident)JsonObject(it+("message_page" to updated)) else it
                }))).toString()))
            }
        }
    }
    fun syncNow(org: String)=scheduler.enqueue(account,org)
    suspend fun catalog(org: String): List<JsonObject> {
        val rows=mutableListOf<JsonObject>()
        for(page in 0..4) {
            scope(org)
            val result=rpc("operational_action_catalog",buildJsonObject { put("p_organization_id",org);put("p_page",page) })
            scope(org);rows+=result.rows("rows").filter { catalogVersion(it)!=null }
            if(!result.flag("more"))return rows.distinctBy { it.text("id") }
        }
        throw FieldProtocolFailure("CATALOG_LIMIT")
    }
    /** Prepared immutable online proposal. Reconfirming an uncertain issue reuses this row. */
    suspend fun issue(org: String,incident: String,operation: String,requestPayload: JsonObject): Boolean=hydrantRemoteAccess.withLock {
        scope(org)
        var op=dao.operations(account,org).find { it.operation.operationId==operation }
        if(op==null) {
            refreshLocked(org)
            val i=parse(dao.snapshot(account,org)!!.payload).rows("incidents").single { it.text("id")==incident }
            val definition=catalog(org).singleOrNull { catalogVersion(it)==requestPayload.text("action_version_id") }
            require(validIssueDraft(definition,requestPayload,i))
            val recipient=requestPayload.rows("recipients").single()
            require(i.rows("units").filter { it.flag("leader") }.flatMap { it.rows("crew") }
                .any { it.text("id")==recipient.text("recipient_id") && it.flag("can_issue") })
            val intent=buildJsonObject { put("incident",incident);put("expected",i.text("version"));put("rpc","incident_issue_task");put("payload",requestPayload) }
            db.withTransaction {
                val seq=db.registry().enqueue(PendingHydrantChange(operationId=operation,account=account,organization=org,
                    entityId=requestPayload.text("id"),operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,
                    createdAt=System.currentTimeMillis(),state="LOCAL_PENDING"))
                dao.dispatch(IncidentDispatch(seq,null,null))
            }
            op=dao.operations(account,org).single { it.operation.operationId==operation }
        }
        require(payload(op).obj("payload")==requestPayload)
        if(op.operation.state=="NEEDS_ATTENTION")return@withLock false
        if(op.operation.state=="SERVER_CONFIRMED")return@withLock true
        val sent=send(org,op,request(org,op)!!)
        if(sent)refreshLocked(org)
        dao.operations(account,org).single { it.operation.operationId==operation }.operation.state=="SERVER_CONFIRMED"
    }

    private val evidenceFiles=IncidentEvidenceFiles(context)
    /** Original queue/dispatch tables: attachment bytes never enter Room JSON. */
    suspend fun stageAttachment(org: String,incident: String,kind: String,target: String?,uri: android.net.Uri,
        originAccount: String,checkAcquisition: ()->Unit)=hydrantRemoteAccess.withLock {
        scope(org);checkAcquisition();currentCoroutineContext().ensureActive()
        require(originAccount==account)
        val acquisitionGeneration=incidentIdentityAccess.withLock {
            scope(org);checkAcquisition()
            evidenceGenerations["$account/$org/$incident"] ?: 0L
        }
        val cache=dao.snapshot(account,org)
        require(lease(org,cache)>0)
        val i=parse(cache!!.payload).rows("incidents").single { it.text("id")==incident }
        require(i.text("status") in listOf("ACTIVE","STABILIZED"))
        require(kind in listOf("INCIDENT","TASK","MESSAGE"))
        if(kind=="INCIDENT")require(target==null)
        if(kind=="TASK")require(i.rows("assignments").any { it.obj("task").text("id")==target })
        val parent=if(kind=="MESSAGE")dao.operations(account,org).lastOrNull {
            it.operation.entityId==target && payload(it).text("incident")==incident &&
            payload(it).text("rpc") in listOf("incident_message_draft","incident_message_send")
        } else null
        if(kind=="MESSAGE")require(parent!=null || i.obj("message_page").rows("messages").any { it.text("id")==target })
        val pending=dao.operations(account,org).filter { payload(it).text("rpc")=="incident_attachment_prepare" && it.operation.state!="SERVER_CONFIRMED" }
        require(pending.size<32 && pending.sumOf { payload(it).obj("metadata").text("size").toLongOrNull() ?: 0L }<134217728)
        val id=UUID.randomUUID().toString();val operation=UUID.randomUUID().toString()
        val metadata=evidenceFiles.stage(account,org,incident,id,uri,checkAcquisition)
        scope(org);checkAcquisition();currentCoroutineContext().ensureActive()
        val intent=buildJsonObject {
            put("rpc","incident_attachment_prepare");put("incident",incident);put("kind",kind)
            put("target",target?.let(::JsonPrimitive) ?: JsonNull);put("metadata",metadata)
            put("finalize",UUID.randomUUID().toString())
        }
        incidentIdentityAccess.withLock {
            scope(org);checkAcquisition();currentCoroutineContext().ensureActive()
            check((evidenceGenerations["$account/$org/$incident"] ?: 0L)==acquisitionGeneration)
            require(lease(org,dao.snapshot(account,org))>0)
            db.withTransaction {
                checkAcquisition();currentCoroutineContext().ensureActive()
                val seq=db.registry().enqueue(PendingHydrantChange(operationId=operation,account=account,organization=org,
                    entityId=id,operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,
                    createdAt=System.currentTimeMillis(),state="LOCAL_PENDING"))
                dao.dispatch(IncidentDispatch(seq,parent?.operation?.sequence,null))
                checkAcquisition();currentCoroutineContext().ensureActive()
            }
        }
        scheduler.enqueue(account,org)
    }
    private suspend fun syncAttachment(org: String,op: FieldOperation): Boolean {
        val body=payload(op);val incident=body.text("incident")
        suspend fun paused()=dao.operations(account,org).find { it.operation.sequence==op.operation.sequence }?.operation?.state=="DRAFT"
        if(paused())return true
        val parent=op.parent?.let { seq->dao.operations(account,org).find { it.operation.sequence==seq } }
        if(op.parent!=null && parent==null){attention(org,op,"DEPENDENCY_MISSING");return true}
        if(parent!=null && parent.operation.state!="SERVER_CONFIRMED") {
            if(parent.operation.state=="NEEDS_ATTENTION")attention(org,op,"DEPENDENCY_REJECTED")
            return true // DRAFT/unsent parent waits; it is not automatically sent by an attachment.
        }
        val dispatchKey="$account/$org/${op.operation.operationId}"
        activeDispatches.update { it+dispatchKey }
        try {
            val args=buildJsonObject {
                put("p_operation",op.operation.operationId);put("p_acting_organization_id",org);put("p_incident_id",incident)
                put("p_attachment_id",op.operation.entityId);put("p_target_kind",body.text("kind"))
                put("p_target_id",body["target"] ?: JsonNull);put("p_metadata",body.obj("metadata"))
            }
            op.request?.let { require(parse(it)==args) }
            dao.prepare(op.operation.sequence,args.toString())
            val dispatching=incidentIdentityAccess.withLock {
                scope(org)
                if(paused())false else { dao.state(account,org,op.operation.sequence,"SENDING");true }
            }
            if(!dispatching)return true
            val reservation=rpc("incident_attachment_prepare",args)
            require(reservation.text("id")==op.operation.entityId && reservation.text("incident_id")==incident &&
                reservation.text("creator_user_id")==account && reservation.text("acting_organization_id")==org)
            if(reservation.text("status")=="REJECTED"){attention(org,op,"ATTACHMENT_REJECTED");return true}
            val request=buildJsonObject {
                put("action","verify");put("organization",org);put("incident",incident)
                put("attachment",op.operation.entityId);put("operation",body.text("finalize"))
            }
            var result: JsonObject?=if(reservation.text("status")=="READY")reservation else null
            if(result==null) {
                try { result=parse(String(evidenceRequest(client,request),Charsets.UTF_8)).obj("data") }
                catch(e: EvidenceFailure) { if(e.code!="ATTACHMENT_NOT_UPLOADED")throw e }
            }
            if(result==null && paused())return true
            if(result==null) {
                val metadata=body.obj("metadata")
                val bytes=evidenceFiles.read(account,org,incident,op.operation.entityId,metadata)
                val path=incident+"/"+op.operation.entityId+"/original."+evidenceExtension(metadata.text("mime"))
                require(reservation.text("bucket")=="incident-evidence" && reservation.text("path")==path)
                incidentIdentityAccess.withLock {
                    scope(org);currentCoroutineContext().ensureActive()
                    if(paused())return true
                    try {
                        client.storage.from("incident-evidence").upload(path,bytes) { upsert=false;contentType=io.ktor.http.ContentType.parse(metadata.text("mime")) }
                    } catch(e: CancellationException){throw e}
                    catch(_: Exception) {
                        // Lost ACK / existing path: validator must establish actual bytes; never upsert.
                    }
                }
                scope(org)
                if(paused())return true
                result=parse(String(evidenceRequest(client,request),Charsets.UTF_8)).obj("data")
            }
            val confirmed=result ?: error("ATTACHMENT_NOT_READY")
            if(confirmed.text("status")!="READY"){attention(org,op,"ATTACHMENT_REJECTED");return true}
            require(confirmed.text("id")==op.operation.entityId && confirmed.text("incident_id")==incident &&
                confirmed.text("operation_id")==op.operation.operationId && confirmed.text("creator_user_id")==account && confirmed.text("acting_organization_id")==org &&
                confirmed.text("sha256")==body.obj("metadata").text("sha256") && confirmed.text("size")==body.obj("metadata").text("size"))
            incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                db.withTransaction {
                    dao.outcome(op.operation.sequence,confirmed.toString(),null)
                    dao.state(account,org,op.operation.sequence,"SERVER_CONFIRMED")
                }
            }
            return true
        } catch(e: CancellationException){throw e}
        catch(e: Exception) {
            scope(org)
            val status=when(e){is EvidenceFailure->e.status;is RestException->e.statusCode;else->0}
            if(status==401){revoke(org);attention(org,op,"SESSION_REQUIRED");return true}
            val rejected=(status in 400..499 && status !in listOf(408,409,429)) || e is IllegalArgumentException || e is IllegalStateException
            var retryExhausted=false
            incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                if(status==403) {
                    evidenceGenerations["$account/$org/$incident"]=(evidenceGenerations["$account/$org/$incident"] ?: 0L)+1
                    saveEvidencePage(org,incident,body.text("kind")+":"+body.text("target"),buildJsonObject { put("denied",true) })
                }
                if(paused())return true
                if(rejected)attention(org,op,when {
                    status==403 -> "ATTACHMENT_REVOKED"
                    e.message?.startsWith("ATTACHMENT_LOCAL")==true -> e.message!!
                    else -> "ATTACHMENT_REJECTED"
                }) else db.withTransaction {
                    val previous=dao.operations(account,org).single { it.operation.sequence==op.operation.sequence }.error.orEmpty()
                    val attempts=(previous.removePrefix("EVIDENCE_RETRY_").toIntOrNull() ?: 0)+1
                    retryExhausted=attempts>=5
                    dao.state(account,org,op.operation.sequence,if(retryExhausted)"NEEDS_ATTENTION" else "OUTCOME_UNKNOWN")
                    dao.outcome(op.operation.sequence,null,"EVIDENCE_RETRY_"+attempts)
                }
            }
            return rejected || retryExhausted
        } finally { activeDispatches.update { it-dispatchKey } }
    }
    /** Metadata is cached only in the existing leased field projection. No durable URL. */
    suspend fun attachmentPage(org: String,incident: String,kind: String,target: String?,older: Boolean=false)=hydrantRemoteAccess.withLock {
        scope(org)
        val key=kind+":"+target.orEmpty()
        val row=dao.snapshot(account,org) ?: return@withLock
        require(lease(org,row)>0)
        val current=parse(row.payload).rows("incidents").single { it.text("id")==incident }
        val previous=current.obj("attachment_pages").obj(key)
        val generation=incidentIdentityAccess.withLock { evidenceGenerations["$account/$org/$incident"] ?: 0L }
        try {
            val page=rpc("incident_attachment_page",buildJsonObject {
                put("p_acting_organization_id",org);put("p_incident_id",incident);put("p_target_kind",kind)
                put("p_target_id",target?.let(::JsonPrimitive) ?: JsonNull)
                if(older && previous.flag("has_more")) {
                    put("p_before_created_at",previous.text("next_created_at"));put("p_before_id",previous.text("next_id"))
                }
            })
            require(page.text("account")==account && page.text("organization")==org && page.text("incident_id")==incident)
            incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                check((evidenceGenerations["$account/$org/$incident"] ?: 0L)==generation)
                val cached=if(older && page.text("scope_fingerprint")==previous.text("scope_fingerprint"))
                    JsonObject(page+("items" to JsonArray((previous.rows("items")+page.rows("items")).distinctBy { it.text("id") }.take(100)))+
                    ("has_more" to JsonPrimitive(page.flag("has_more") && previous.rows("items").size+page.rows("items").size<100))) else page
                saveEvidencePage(org,incident,key,cached)
            }
        } catch(e: CancellationException){throw e}
        catch(e: Exception) {
            if(e is RestException && e.statusCode==401)revoke(org)
            else if(e is RestException && e.statusCode==403)incidentIdentityAccess.withLock {
                scope(org);evidenceGenerations["$account/$org/$incident"]=(evidenceGenerations["$account/$org/$incident"] ?: 0L)+1
                saveEvidencePage(org,incident,key,buildJsonObject { put("denied",true) })
            }
            throw e
        }
    }
    private suspend fun saveEvidencePage(org: String,incident: String,key: String,page: JsonObject)=db.withTransaction {
        val row=dao.snapshot(account,org) ?: return@withTransaction
        val root=parse(row.payload)
        val guardedPage=JsonObject(page+("_generation" to JsonPrimitive((evidenceGenerations["$account/$org/$incident"] ?: 0L).toString())))
        dao.save(row.copy(payload=JsonObject(root+("incidents" to JsonArray(root.rows("incidents").map { i ->
            if(i.text("id")==incident)JsonObject(i+("attachment_pages" to JsonObject((i.obj("attachment_pages").filterKeys { it!=key }.entries.toList().takeLast(7).associate { it.toPair() })+(key to guardedPage)))) else i
        }))).toString()))
    }
    suspend fun attachmentDownload(org: String,incident: String,id: String,kind: String,target: String?): ByteArray {
        scope(org);require(lease(org,dao.snapshot(account,org))>0)
        val generation=incidentIdentityAccess.withLock { evidenceGenerations["$account/$org/$incident"] ?: 0L }
        try {
            val bytes=evidenceRequest(client,buildJsonObject { put("action","download");put("organization",org);put("incident",incident);put("attachment",id) })
            return incidentIdentityAccess.withLock {
                scope(org);currentCoroutineContext().ensureActive()
                require(lease(org,dao.snapshot(account,org))>0 && parse(dao.snapshot(account,org)!!.payload).rows("incidents").any { it.text("id")==incident })
                check((evidenceGenerations["$account/$org/$incident"] ?: 0L)==generation)
                bytes
            }
        } catch(e: CancellationException){throw e}
        catch(e: EvidenceFailure) {
            if(e.status==401)revoke(org)
            else if(e.status==403)incidentIdentityAccess.withLock {
                scope(org)
                // Target-specific denial hides evidence only, never tasks/cursor/lease.
                evidenceGenerations["$account/$org/$incident"]=(evidenceGenerations["$account/$org/$incident"] ?: 0L)+1
                saveEvidencePage(org,incident,kind+":"+target.orEmpty(),buildJsonObject { put("denied",true) })
            }
            throw e
        }
    }

    suspend fun retryAttachment(org: String,operation: String)=hydrantRemoteAccess.withLock {
        scope(org);require(lease(org,dao.snapshot(account,org))>0)
        val op=dao.operations(account,org).single { it.operation.operationId==operation }
        require(payload(op).text("rpc")=="incident_attachment_prepare")
        require(op.operation.state in listOf("NEEDS_ATTENTION","OUTCOME_UNKNOWN","DRAFT"))
        incidentIdentityAccess.withLock {
            scope(org);currentCoroutineContext().ensureActive()
            dao.state(account,org,op.operation.sequence,"LOCAL_PENDING")
            if(op.operation.state=="NEEDS_ATTENTION")dao.outcome(op.operation.sequence,op.result,"EVIDENCE_RETRY_0")
        } // Keep original payload, request, UUID, evidence file and prior result; reset only explicit retry budget.
        scheduler.enqueue(account,org)
    }

    /** Pause future phases/retries only; an already committed READY result remains authoritative. */
    suspend fun pauseAttachment(org: String,operation: String)=incidentIdentityAccess.withLock {
        scope(org);currentCoroutineContext().ensureActive()
        val op=dao.operations(account,org).single { it.operation.operationId==operation }
        require(payload(op).text("rpc")=="incident_attachment_prepare")
        if(op.operation.state!="SERVER_CONFIRMED")dao.state(account,org,op.operation.sequence,"DRAFT")
    }

    /** Fresh online review, frozen once in existing dispatch tables; DRAFT is NOT an order.
     * The worker allowlist deliberately excludes these authority-changing RPCs. */
    suspend fun prepareLeader(org: String,incident: String,unit: String,rpcName: String,operation: String,proposed: JsonObject,candidateQuery: String=""): String=hydrantRemoteAccess.withLock {
        scope(org);require(rpcName in leaderRpcs && canonicalUuid(operation))
        val existing=dao.operations(account,org).find { it.operation.operationId==operation }
        if(existing!=null) {
            require(payload(existing).text("unit")==unit && payload(existing).text("incident")==incident &&
                payload(existing).text("rpc")==rpcName && payload(existing).obj("payload")==proposed)
            return@withLock operation
        }
        refreshLocked(org)
        val i=parse(dao.snapshot(account,org)!!.payload).rows("incidents").single { it.text("id")==incident }
        val u=i.rows("units").single { it.text("id")==unit }
        validateLeaderPayload(i,u,rpcName,proposed)
        val ownIncident=JsonObject(i+("units" to JsonArray(listOf(u))))
        val catalogRow=if(rpcName=="incident_issue_task")catalog(org).singleOrNull { catalogVersion(it)==proposed.text("action_version_id") } else null
        if(rpcName=="incident_issue_task")require(validIssueDraft(catalogRow,proposed,ownIncident)) { "STALE_VERSION" }
        val person=if(rpcName=="incident_add_crew_member")crewCandidatesLocked(org,incident,unit,candidateQuery).firstOrNull { it.text("id")==proposed.text("user_id") } else null
        if(rpcName=="incident_add_crew_member")require(person!=null) { "INVALID_CREW_MEMBER" }
        // Server rechecks exact membership at commit.
        val recipient=u.rows("crew").find { it.text("id")==proposed.rows("recipients").firstOrNull()?.text("recipient_id") ||
            it.text("id")==proposed.text("id") }
        val allocation=u.rows("resources").find { it.text("id")==proposed.text("id") }
        val intent=buildJsonObject {
            put("rpc",rpcName);put("incident",incident);put("unit",unit);put("leader",leaderStamp(u))
            put("expected",i.text("version"));put("unit_version",u.text("version"));put("payload",proposed)
            put("review",buildJsonObject {
                put("reference",i.text("reference"));put("mode",i.text("mode"));put("unit",u.text("name"));put("source_status",u.text("status"))
                put("subject",recipient?.text("name") ?: person?.text("name") ?: allocation?.text("name") ?: proposed.text("user_id"))
                put("quantity",allocation?.text("quantity").orEmpty());put("measure",allocation?.text("unit_of_measure_code").orEmpty())
                put("measure_label",allocation?.obj("measure") ?: JsonObject(emptyMap()))
                put("action",catalogRow?.obj("configuration") ?: JsonObject(emptyMap()))
            })
        }
        val request=buildJsonObject {
            put("p_operation",operation);put("p_acting_organization_id",org);put("p_incident_id",incident)
            put("p_expected_version",JsonPrimitive(BigInteger(i.text("version")).longValueExact()));put("p_payload",proposed)
        }
        incidentIdentityAccess.withLock {
            scope(org);currentCoroutineContext().ensureActive()
            db.withTransaction {
                val seq=db.registry().enqueue(PendingHydrantChange(operationId=operation,account=account,organization=org,
                    entityId=proposed.text("id"),operation="INCIDENT_TASK",payload=intent.toString(),baseVersion=null,
                    createdAt=System.currentTimeMillis(),state="DRAFT"))
                dao.dispatch(IncidentDispatch(seq,null,request.toString()))
            }
        }
        operation
    }
    private suspend fun crewCandidatesLocked(org: String,incident: String,unit: String,query: String): List<JsonObject> {
        try {
            return incidentIdentityAccess.withLock {
                scope(org);require(query.length<=100)
                val args=buildJsonObject { put("p_acting_organization_id",org);put("p_incident_id",incident);put("p_unit_assignment_id",unit);put("p_query",query) }
                client.postgrest.rpc("incident_crew_candidates",args).decodeAs<JsonArray>().map { it.jsonObject }.also { scope(org);currentCoroutineContext().ensureActive() }
            }
        } catch(e: RestException) {
            if(e.statusCode==401)revoke(org) else if(e.statusCode==403)invalidateLeader(org,incident,unit)
            throw e
        }
    }
    suspend fun crewCandidates(org: String,incident: String,unit: String,query: String): List<JsonObject> = hydrantRemoteAccess.withLock {
        refreshLocked(org)
        val i=parse(dao.snapshot(account,org)!!.payload).rows("incidents").single { it.text("id")==incident }
        val u=i.rows("units").single { it.text("id")==unit }
        require(isCurrentLeader(i,u) && u.flag("can_manage_crew")) { "NOT_AUTHORIZED" }
        crewCandidatesLocked(org,incident,unit,query)
    }
    /** Explicit interactive submit/replay. Never called by synchronize(). */
    suspend fun confirmLeader(org: String,incident: String,unit: String,operation: String): FieldOperation=hydrantRemoteAccess.withLock {
        scope(org)
        val op=dao.operations(account,org).single { it.operation.operationId==operation }
        val intent=payload(op)
        require(intent.text("unit")==unit && intent.text("incident")==incident && intent.text("rpc") in leaderRpcs)
        require(op.operation.state in listOf("DRAFT","LOCAL_PENDING","SENDING","OUTCOME_UNKNOWN","SERVER_CONFIRMED")) { "STALE_VERSION" }
        refreshLocked(org)
        val i=parse(dao.snapshot(account,org)!!.payload).rows("incidents").single { it.text("id")==incident }
        val u=i.rows("units").single { it.text("id")==unit }
        require(isCurrentLeader(i,u) && leaderStamp(u)==intent.text("leader")) { "NOT_AUTHORIZED" }
        if(op.operation.state=="SERVER_CONFIRMED")return@withLock op
        if(op.operation.state=="DRAFT") {
            val ownIncident=JsonObject(i+("units" to JsonArray(listOf(u))))
            try {
                require(i.text("version")==intent.text("expected") && u.text("version")==intent.text("unit_version")) { "STALE_VERSION" }
                validateLeaderPayload(i,u,intent.text("rpc"),intent.obj("payload"))
                if(intent.text("rpc")=="incident_issue_task") {
                    val row=catalog(org).singleOrNull { catalogVersion(it)==intent.obj("payload").text("action_version_id") }
                    require(validIssueDraft(row,intent.obj("payload"),ownIncident)) { "STALE_VERSION" }
                }
            } catch(e: IllegalArgumentException) {
                attention(org,op,"STALE_VERSION");throw e
            }
        }
        // Unknown outcomes intentionally replay the original expected version, even
        // if this very command advanced it. Existing SQL checks receipt before version.
        val sent=send(org,op,op.request ?: error("PROTOCOL"))
        if(sent)try { refreshLocked(org) } catch(e: CancellationException){throw e} catch(_: Exception) { /* Receipt remains confirmed; view is stale. */ }
        dao.operations(account,org).single { it.operation.operationId==operation }
    }
    private suspend fun invalidateLeader(org: String,incident: String,unit: String)=incidentIdentityAccess.withLock {
        scope(org)
        val key="$account/$org/$incident"
        evidenceGenerations[key]=(evidenceGenerations[key] ?: 0L)+1
        db.withTransaction {
            val row=dao.snapshot(account,org) ?: return@withTransaction
            val root=parse(row.payload)
            dao.save(row.copy(payload=JsonObject(root+("incidents" to JsonArray(root.rows("incidents").map { i->
                if(i.text("id")!=incident)i else JsonObject(i+mapOf(
                    "leader_reset" to JsonPrimitive(true),
                    "units" to JsonArray(i.rows("units").map { u->if(u.text("id")!=unit)u else JsonObject(
                        (u-"leader_assignment"-"resources"-"crew_history")+mapOf("leader" to JsonPrimitive(false),"can_return" to JsonPrimitive(false),
                         "can_manage_crew" to JsonPrimitive(false),"status_actions" to JsonArray(emptyList()),
                         "crew" to JsonArray(u.rows("crew").filter { it.text("user_id")==account }.map { JsonObject(it+("can_issue" to JsonPrimitive(false))) }))) }),
                    "assignments" to JsonArray(i.rows("assignments").filter { it.text("unit_id")!=unit || it.flag("mine") || it.text("recipient_type")=="INCIDENT_UNIT" }
                        .map { a->if(a.text("unit_id")==unit && !a.flag("mine"))JsonObject(a-"blocked_reason"-"unable_reason") else a }),
                    "attachment_pages" to JsonObject(i.obj("attachment_pages").filterKeys { key->
                        !i.rows("assignments").any { a->a.text("unit_id")==unit && key=="TASK:"+a.obj("task").text("id") }
                    }),
                    "history" to JsonArray(emptyList())
                ))
            }))).toString()))
        }
    }
}
