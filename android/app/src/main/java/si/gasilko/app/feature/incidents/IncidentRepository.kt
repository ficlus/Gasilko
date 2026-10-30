package si.gasilko.app.feature.incidents

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import androidx.room.withTransaction
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.postgrest
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
    private suspend fun revoke(org: String) {
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
    private suspend fun revokeIncident(org: String,id: String)=db.withTransaction {
        dao.snapshot(account,org)?.let { row ->
            val value=parse(row.payload)
            dao.save(row.copy(payload=JsonObject(value+("incidents" to JsonArray(
                value.rows("incidents").filterNot { it.text("id")==id }))).toString()))
        }
        dao.removeCursor(account,org,id)
    }
    private suspend fun refreshLocked(org: String) {
        scope(org)
        try {
            val previous=dao.snapshot(account,org)
            val reconciler=IncidentReconciliation(account,org,
                { name,request -> rpc(name,request).also { scope(org) } },
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
                // Saving lease first fails closed if Room commit is interrupted.
                secure.saveIncidentLease(account,org,buildJsonObject {
                    put("wall",row.verifiedAt);put("elapsed",row.elapsed);put("boot",row.boot)
                }.toString())
                db.withTransaction {
                    scope(org);dao.save(row);dao.clearCursors(account,org);dao.saveCursors(staged.cursors)
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
            if(op.operation.state in listOf("SERVER_CONFIRMED","NEEDS_ATTENTION") ||
                payload(op).text("rpc")!="incident_transition_task_assignment")continue
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
                    if(op.operation.state in listOf("SENDING","OUTCOME_UNKNOWN"))"RECOVERY_REJECTED" else "SERVER_REJECTED"
                } else "TRANSPORT_UNCERTAIN")
            }
            if(e is RestException && (e.statusCode==401 || e.statusCode==403))revoke(org)
            return rejected
        } finally { activeDispatches.update { it-dispatchKey } }
        // A receipt proves this operation committed, not a fabricated current assignment
        // state/version. Cache reconciliation failures must never turn success into rejection.
        if(result.text("operation_id")!=op.operation.operationId || result.text("incident_id")!=payload(op).text("incident") ||
            (payload(op).text("rpc")=="incident_transition_task_assignment" && result.text("task_id")!=payload(op).text("task"))) {
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
    fun syncNow(org: String)=scheduler.enqueue(account,org)
    suspend fun catalog(org: String): List<JsonObject> {
        scope(org)
        val result=rpc("operational_action_catalog",buildJsonObject { put("p_organization_id",org) })
        scope(org)
        return result.rows("rows").filter { catalogVersion(it)!=null }
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
}
