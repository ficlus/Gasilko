package si.gasilko.app.core.security.deviceproof

import java.util.UUID

/** Labels for future integration only. No transition/parser or SHARING state exists here. */
internal enum class DeviceProofPhase {
    UNAVAILABLE,POLICY_UNAPPROVED,DEVICE_UNBOUND,PROOF_PENDING,
    PROOF_VALIDATED_INACTIVE,BINDING_PENDING_APPROVAL,BOUND_INACTIVE,REVOKED,EXPIRED,OUTCOME_UNKNOWN
}
internal enum class DeviceProofError { INVALID_INPUT,INVALID_ENCODING,SCOPE_UNAVAILABLE,EXPIRED,
    KEY_UNAVAILABLE,KEY_INVALIDATED,CRYPTO_UNAVAILABLE,PUBLIC_KEY_MISMATCH,CLEANUP_FAILED }
internal class DeviceProofException(val error: DeviceProofError): java.security.GeneralSecurityException(error.name)
internal fun proofRequire(condition: Boolean,error: DeviceProofError=DeviceProofError.INVALID_INPUT) {
    if(!condition)throw DeviceProofException(error)
}
internal fun proofUuid(value: String) {
    proofRequire(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").matches(value) &&
        value!="00000000-0000-0000-0000-000000000000" && UUID.fromString(value).toString()==value)
}
internal fun proofHash(value: String) {proofRequire(Regex("[0-9a-f]{64}").matches(value))}
internal fun proofAudience(value: String) {proofRequire(value.length in 1..128 && Regex("[A-Za-z0-9._:/-]+").matches(value))}

/** Typed local scope is not evidence of actual membership, DRIVER eligibility or REAL mode. */
internal class DeviceProofScope(val account: String,val organization: String,val incident: String,
    val deployment: String,val vehicle: String,val authorityEpisode: String) {
    init {listOf(account,organization,incident,deployment,vehicle,authorityEpisode).forEach(::proofUuid)}
    internal fun identity()=listOf(account,organization,incident,deployment,vehicle,authorityEpisode).joinToString("\n")
    internal fun same(other: DeviceProofScope)=identity()==other.identity()
    override fun toString()="DeviceProofScope(redacted)"
}

/** Byte contract matches the M15A v1 proposal; no JSON, clock/authority or server receipt inferred. */
internal class DeviceProofChallengeV1(
    val audience: String,val recoveryEpoch: String,val scope: DeviceProofScope,
    val credentialId: String,val publicKeySha256: String,val policyVersion: String,
    val policyDocumentSha256: String,val preciseAudienceSha256: String,
    val issueOperationId: String,val confirmOperationId: String,val challengeId: String,
    val nonceBase64Url: String,val issuedAtSeconds: Long,val expiresAtSeconds: Long,
    val expectedIncidentVersion: Long,val expectedDeploymentVersion: Long,
    val expectedVehicleVersion: Long,val reservedGeneration: Long
) {
    init {
        proofAudience(audience)
        listOf(recoveryEpoch,credentialId,issueOperationId,confirmOperationId,challengeId).forEach(::proofUuid)
        listOf(publicKeySha256,policyDocumentSha256,preciseAudienceSha256).forEach(::proofHash)
        proofRequire(policyVersion.length in 1..64 && Regex("[A-Za-z0-9._-]+").matches(policyVersion))
        DeviceProofEncoding.nonce(nonceBase64Url)
        proofRequire(issuedAtSeconds>=0 && issuedAtSeconds<=Long.MAX_VALUE-120 &&
            expiresAtSeconds==issuedAtSeconds+120)
        proofRequire(listOf(expectedIncidentVersion,expectedDeploymentVersion,expectedVehicleVersion,reservedGeneration).all {it>0})
        proofRequire(issueOperationId!=confirmOperationId)
    }
    fun bytes(): ByteArray=(listOf(
        "GASILKO-VEHICLE-PHONE-BINDING-V1",audience,recoveryEpoch,"BIND_INACTIVE",
        scope.account,scope.organization,scope.incident,"REAL",scope.deployment,scope.vehicle,
        scope.authorityEpisode,"DRIVER",credentialId,publicKeySha256,policyVersion,
        policyDocumentSha256,preciseAudienceSha256,issueOperationId,confirmOperationId,challengeId,
        nonceBase64Url,issuedAtSeconds.toString(),expiresAtSeconds.toString(),
        expectedIncidentVersion.toString(),expectedDeploymentVersion.toString(),
        expectedVehicleVersion.toString(),reservedGeneration.toString()
    ).joinToString("\n")+"\n").toByteArray(Charsets.UTF_8)
    /** Advisory local clock guard only. Server must independently validate nonce/time/authority. */
    internal fun requireLocallyLive(nowSeconds: Long) {
        proofRequire(nowSeconds>=issuedAtSeconds && nowSeconds<expiresAtSeconds,DeviceProofError.EXPIRED)
    }
    override fun toString()="DeviceProofChallengeV1(redacted)"
}
