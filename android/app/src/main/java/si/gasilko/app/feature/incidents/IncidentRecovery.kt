package si.gasilko.app.feature.incidents

import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.exception.PostgrestRestException
import si.gasilko.app.core.database.FieldOperation
import kotlinx.serialization.json.*

internal val recoverableFieldRpcs=leaderRpcs+setOf("incident_transition_task_assignment","incident_message_send")
/** Only canonical P0001 business messages may establish a first rejection.
 * Permission/identity/receipt/transport errors are deliberately outside this set. */
internal val firstRejections=setOf("STALE_VERSION","INVALID_TASK_TRANSITION","TASK_NOT_FOUND","INCIDENT_TERMINAL",
    "VALIDATION_FAILED","INVALID_CREW_MEMBER","INVALID_UNIT","INVALID_UNIT_STATUS","INVALID_RESOURCE","INVALID_RESOURCE_STATUS",
    "INVALID_TASK_RECIPIENT","INVALID_ACTION_DEFINITION","INVALID_ACTION_PARAMETERS","INVALID_TASK_TARGET","TASK_POINT_REQUIRED",
    "TASK_LIMIT_REACHED","UNIT_HAS_ACTIVE_COMMAND","UNIT_HAS_ACTIVE_CREW","UNRESOLVED_TASKS","RESOURCE_IN_USE",
    "RESOURCE_LIMIT_REACHED","INSUFFICIENT_RESOURCE_QUANTITY","SIMULATION_RESOURCE_DISABLED","INVALID_SIMULATION_UNIT")
internal fun fieldFailure(e: Exception): String {
    if(e is android.database.sqlite.SQLiteException)return "LOCAL_STORAGE"
    if(e is java.security.GeneralSecurityException)return "SECURE_STORAGE"
    if(e is FieldProtocolFailure && "SCOPE" in e.code)return "SCOPE_UNAVAILABLE"
    if(e !is RestException)return "TRANSPORT_UNCERTAIN"
    // SDK error/code are server fields. Exception.message also includes hints,
    // details, URL and headers: none of those are business-rejection evidence.
    val code=(e as? PostgrestRestException)?.code
    if(code in setOf("57014","55P03","40P01","40001") || e.statusCode in listOf(408,429))return "TEMPORARY_BUSY"
    if(code in setOf("PGRST202","PGRST204","42883","42703","42P01"))return "COMPATIBILITY"
    if(e.statusCode in listOf(401,403) || code=="42501")return "NOT_AUTHORIZED"
    if(e.statusCode !in 400..499)return "TRANSPORT_UNCERTAIN"
    if(code!="P0001")return "TRANSPORT_UNCERTAIN"
    return e.error.takeIf {it in firstRejections || it=="OPERATION_REUSED"} ?: "TRANSPORT_UNCERTAIN"
}
internal fun fieldReceiptMatches(op: FieldOperation,result: JsonObject): Boolean {
    val body=parse(op.operation.payload)
    return result.text("operation_id")==op.operation.operationId && result.text("incident_id")==body.text("incident") &&
        when(body.text("rpc")) {
            "incident_transition_task_assignment"->result.text("task_id")==body.text("task")
            "incident_issue_task"->result.text("task_id")==op.operation.entityId
            "incident_message_send"->result.text("message_id")==op.operation.entityId
            else->true
        } && result["error"]==null && result.text("timeline_sequence").toLongOrNull()?.let {it>=0}==true &&
        (body.text("rpc")=="incident_message_send" || result.text("version").toLongOrNull()?.let {it>0}==true) &&
        result.text("revision").toLongOrNull()?.let {it>=0}==true
}
internal fun FieldOperation.uncertain()=operation.state in listOf("SENDING","OUTCOME_UNKNOWN") ||
    error?.startsWith("UNKNOWN_")==true
internal fun FieldOperation.firstRejected()=operation.state=="NEEDS_ATTENTION" && error?.startsWith("REJECTED:")==true && error.orEmpty().removePrefix("REJECTED:") in firstRejections
internal fun neutralOperation(op: FieldOperation)=op.copy(operation=op.operation.copy(payload="{}"),
    request=null,result=null,error="SCOPE_UNAVAILABLE")
internal enum class RecoveryPhase { LOCAL_INTENT,READY_TO_SEND,SENDING,OUTCOME_UNKNOWN,SERVER_CONFIRMED,
    DEFINITIVELY_REJECTED,NEEDS_ATTENTION,BLOCKED_DEPENDENCY,SCOPE_UNAVAILABLE }
internal fun recoveryPhase(op: FieldOperation,all: List<FieldOperation>,visible: Boolean): RecoveryPhase {
    if(!visible || op.error in setOf("SCOPE_UNAVAILABLE","NOT_AUTHORIZED"))return RecoveryPhase.SCOPE_UNAVAILABLE
    if(op.error in setOf("OPERATION_REUSED","IDENTITY_MISMATCH"))return RecoveryPhase.NEEDS_ATTENTION
    if(op.operation.state=="SERVER_CONFIRMED")return RecoveryPhase.SERVER_CONFIRMED
    if(op.operation.state=="SENDING")return RecoveryPhase.SENDING
    if(op.uncertain())return RecoveryPhase.OUTCOME_UNKNOWN
    val parent=op.parent?.let {p->all.find {it.operation.sequence==p}}
    if(op.parent!=null && parent?.operation?.state!="SERVER_CONFIRMED")return RecoveryPhase.BLOCKED_DEPENDENCY
    if(op.firstRejected())return RecoveryPhase.DEFINITIVELY_REJECTED
    return when(op.operation.state) {
        "DRAFT"->RecoveryPhase.LOCAL_INTENT
        "LOCAL_PENDING"->RecoveryPhase.READY_TO_SEND
        else->RecoveryPhase.NEEDS_ATTENTION
    }
}

internal fun recoveryVisible(op: FieldOperation,state: IncidentFieldState): Boolean {
    if(state.locked || op.error in setOf("SCOPE_UNAVAILABLE","NOT_AUTHORIZED"))return false
    val body=runCatching {parse(op.operation.payload)}.getOrNull() ?: return false
    val i=state.incidents.find {it.text("id")==body.text("incident")} ?: return false
    return when(body.text("rpc")) {
        "incident_transition_task_assignment"->i.rows("assignments").any {it.text("id")==op.operation.entityId && it.obj("task").text("id")==body.text("task")}
        "incident_message_send","incident_message_draft"-> {
            val d=body.obj("payload");val draft=body.obj("draft_target")
            val kind=d.text("audience_kind").ifEmpty {draft.text("kind")}
            val id=when(kind) {"UNIT"->d.text("audience_unit_assignment_id");"ORGANIZATION"->d.text("audience_org_id");else->""}.ifEmpty {draft.text("id")}
            i.obj("message_page").rows("targets").any {it.text("kind")==kind && (kind=="INCIDENT" || it.text("id")==id)}
        }
        "incident_attachment_prepare"->when(body.text("kind")) {
            "TASK"->i.rows("assignments").any {it.obj("task").text("id")==body.text("target")}
            "MESSAGE"->i.obj("message_page").rows("messages").any {it.text("id")==body.text("target")}
            else->true
        }
        else->i.rows("units").any {u->isCurrentLeader(i,u) && body.text("unit")==u.text("id") && body.text("leader")==leaderStamp(u)}
    }
}

internal fun FieldOperation.correctable()=firstRejected() || (operation.state=="NEEDS_ATTENTION" &&
    (error=="LOCAL_STALE" || (request==null && error in setOf("DEPENDENCY_CHANGED","DEPENDENCY_REJECTED"))))

/** Local immutable tuple check, in addition to canonical server receipt equality. */
internal fun fieldRequestMatches(op: FieldOperation,org: String,request: String)=runCatching {
    val body=parse(op.operation.payload);val args=parse(request)
    args.text("p_operation")==op.operation.operationId && args.text("p_acting_organization_id")==org &&
        args.text("p_incident_id")==body.text("incident") && args.obj("p_payload")==body.obj("payload") &&
        args.obj("p_payload").text("id")==op.operation.entityId &&
        args.text("p_expected_version").toLongOrNull()?.let {it>0}==true &&
        (op.parent!=null || args.text("p_expected_version")==body.text("expected")) &&
        body.text("rpc") in recoverableFieldRpcs
}.getOrDefault(false)
