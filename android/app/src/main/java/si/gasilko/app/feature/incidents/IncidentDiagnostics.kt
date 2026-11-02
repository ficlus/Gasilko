package si.gasilko.app.feature.incidents

import si.gasilko.app.core.database.FieldOperation

/** Ephemeral presentation over the existing Room projection; never telemetry or a queue. */
internal enum class DiagnosticIssue { LOCAL_STALE_VERSION,PROTOCOL,NETWORK,BUSY,STORAGE }
internal data class IncidentDiagnostics(
    val rows: List<FieldOperation>,val phases: Map<Long,RecoveryPhase>,val counts: Map<RecoveryPhase,Int>,
    val pending: Int,val unknown: Int,val oldestIntent: Long?,val lastReceipt: Long?,
    val organizationScope: Boolean,val incompleteScope: Boolean,val issues: Map<DiagnosticIssue,Int>
)
internal fun incidentDiagnostics(state: IncidentFieldState,incident: String?): IncidentDiagnostics {
    val parents=state.operations.associateBy {it.operation.sequence}
    val organizationScope=state.locked || incident==null
    var incomplete=false
    val rows=if(organizationScope)state.operations else state.operations.filter {
        val body=runCatching {parse(it.operation.payload)}.getOrNull()
        if(body==null)incomplete=true
        body?.text("incident")==incident
    }
    val phases=rows.associate {op->op.operation.sequence to recoveryPhaseWithParent(op,
        op.parent?.let(parents::get),recoveryVisible(op,state))}
    val counts=phases.values.groupingBy {it}.eachCount()
    val pending=rows.count {it.operation.state=="LOCAL_PENDING"}
    val unknown=rows.count {it.operation.state=="OUTCOME_UNKNOWN" || it.error?.startsWith("UNKNOWN_")==true ||
        (it.operation.state=="SENDING" && it.error=="RECEIPT_ABSENT")}
    val oldest=rows.filter {it.operation.state !in listOf("DRAFT","SERVER_CONFIRMED")}
        .minOfOrNull {it.operation.createdAt}
    val receipt=rows.asSequence().filter {recoveryVisible(it,state)}.mapNotNull {
        runCatching {java.time.Instant.parse(it.result?.let(::parse)?.text("_d1_confirmed_at")).toEpochMilli()}.getOrNull()
    }.maxOrNull()
    val issues=rows.asSequence().filter {recoveryVisible(it,state)}.mapNotNull {
        when(it.error.orEmpty().removePrefix("REJECTED:").removePrefix("UNKNOWN_REJECTED:")) {
            "STALE_VERSION","LOCAL_STALE","DEPENDENCY_CHANGED"->DiagnosticIssue.LOCAL_STALE_VERSION
            "COMPATIBILITY","RECEIPT_UNCERTAIN","IDENTITY_MISMATCH","OPERATION_REUSED"->DiagnosticIssue.PROTOCOL
            "TRANSPORT_UNCERTAIN"->DiagnosticIssue.NETWORK
            "TEMPORARY_BUSY"->DiagnosticIssue.BUSY
            "LOCAL_STORAGE","SECURE_STORAGE"->DiagnosticIssue.STORAGE
            else->null
        }
    }.groupingBy {it}.eachCount()
    return IncidentDiagnostics(rows,phases,counts,pending,unknown,oldest,receipt,organizationScope,incomplete,issues)
}
