package si.gasilko.app.core.security.deviceproof

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Ephemeral caller-owned identity generation, NOT a JWT/policy/consent approval.
 * Future integration must replace this object on every identity/scope epoch and
 * revoke it synchronously on logout, role/capability loss or scope switch.
 */
internal class LocalDeviceProofAccess(val scope: DeviceProofScope,val audience: String,val recoveryEpoch: String) {
    init {proofAudience(audience);proofUuid(recoveryEpoch)}
    private val revoked=AtomicBoolean(false)
    fun revoke() {revoked.set(true)}
    internal fun current(owner: ()->LocalDeviceProofAccess?)=!revoked.get() && owner()===this
    override fun toString()="LocalDeviceProofAccess(redacted)"
}
internal class LocalDeviceCredential internal constructor(val id: String,val scope: DeviceProofScope,spkiDer: ByteArray) {
    private val spki=spkiDer.copyOf()
    val publicKeySha256=DeviceProofEncoding.sha256(spki)
    fun publicSpkiDer()=spki.copyOf()
    override fun toString()="LocalDeviceCredential(redacted)"
}
/** Frozen, defensive-copy result for exact retry. Local signing is NOT server validation. */
internal class PreparedLocalDeviceProof internal constructor(val credential: LocalDeviceCredential,
    transcript: ByteArray,signatureDer: ByteArray) {
    private val transcriptBytes=transcript.copyOf()
    private val signatureBytes=signatureDer.copyOf()
    fun transcript()=transcriptBytes.copyOf()
    fun derSignature()=signatureBytes.copyOf()
    fun rawSignature()=DeviceProofEncoding.derToRaw(signatureBytes)
    override fun toString()="PreparedLocalDeviceProof(redacted)"
}

/** Reusable local primitive, deliberately has NO app/UI/network/worker callers.
 * Construction does not create a key. No create-on-read, fallback software key,
 * private-key export, attestation claim, enrollment, consent or location support.
 * currentAccess must be thread-safe and supplied by the future authenticated owner.
 */
internal class LocalDeviceProofKeys(private val access: LocalDeviceProofAccess,
    private val currentAccess: ()->LocalDeviceProofAccess?,
    private val nowSeconds: ()->Long={System.currentTimeMillis()/1000}) {
    private val prefix="gasilko_device_proof_v1_"+DeviceProofEncoding.sha256((access.scope.identity()+"\n"+access.audience+"\n"+access.recoveryEpoch).toByteArray(Charsets.UTF_8))+"_"
    private fun alias(id: String): String {proofUuid(id);return prefix+id}
    private suspend fun guard() {
        currentCoroutineContext().ensureActive()
        proofRequire(access.current(currentAccess),DeviceProofError.SCOPE_UNAVAILABLE)
    }
    /** Only an explicit future local ceremony calls this; always a NEW UUID/key. */
    suspend fun createNew(): LocalDeviceCredential=operation {store->
        guard()
        val id=UUID.randomUUID().toString();val name=alias(id)
        proofRequire(!store.containsAlias(name),DeviceProofError.KEY_UNAVAILABLE)
        var keep=false
        try {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(name,KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false).build())
            }.generateKeyPair()
            val result=loadCredential(store,id)
            guard()
            keep=true
            result
        } finally {
            if(!keep)try {store.deleteEntry(name)}
                catch(e: Exception) {
                    // Preserve coroutine cancellation, and never return a credential after failed cleanup.
                    if(e is CancellationException)throw e
                    if(currentCoroutineContext().isActive)throw DeviceProofException(DeviceProofError.CLEANUP_FAILED)
                }
        }
    }
    /** Restore requires the original public hash. Missing/inaccessible keys NEVER regenerate. */
    suspend fun openExisting(id: String,expectedPublicKeySha256: String): LocalDeviceCredential=operation {store->
        guard();proofHash(expectedPublicKeySha256)
        val result=loadCredential(store,id)
        proofRequire(result.publicKeySha256==expectedPublicKeySha256,DeviceProofError.PUBLIC_KEY_MISMATCH)
        guard();result
    }
    suspend fun prepareProof(credential: LocalDeviceCredential,challenge: DeviceProofChallengeV1): PreparedLocalDeviceProof=operation {store->
        guard()
        proofRequire(credential.scope.same(access.scope) && challenge.scope.same(access.scope) &&
            challenge.audience==access.audience && challenge.recoveryEpoch==access.recoveryEpoch,DeviceProofError.SCOPE_UNAVAILABLE)
        proofRequire(challenge.credentialId==credential.id && challenge.publicKeySha256==credential.publicKeySha256,
            DeviceProofError.PUBLIC_KEY_MISMATCH)
        challenge.requireLocallyLive(nowSeconds())
        val original=loadCredential(store,credential.id)
        proofRequire(original.publicKeySha256==credential.publicKeySha256,DeviceProofError.PUBLIC_KEY_MISMATCH)
        val entry=store.getEntry(alias(credential.id),null) as? KeyStore.PrivateKeyEntry
            ?: throw DeviceProofException(DeviceProofError.KEY_UNAVAILABLE)
        val bytes=challenge.bytes()
        val der=Signature.getInstance("SHA256withECDSA").run {
            initSign(entry.privateKey);update(bytes);sign()
        }
        // Validate exact format and verify local key correspondence; not a trusted remote verifier.
        val raw=DeviceProofEncoding.derToRaw(der)
        proofRequire(DeviceProofEncoding.rawToDer(raw).contentEquals(der),DeviceProofError.INVALID_ENCODING)
        proofRequire(Signature.getInstance("SHA256withECDSA").run {
            initVerify(DeviceProofEncoding.publicKey(original.publicSpkiDer()));update(bytes);verify(der)
        },DeviceProofError.CRYPTO_UNAVAILABLE)
        guard();challenge.requireLocallyLive(nowSeconds())
        PreparedLocalDeviceProof(original,bytes,der)
    }
    /** Immediate local denial; does NOT revoke any server credential/session. */
    fun revokeLocalAccess() {access.revoke()}
    /** Explicit own-namespace cleanup, usable after logout. Never deletes auth AES or pending evidence. */
    suspend fun deleteScopeKeys() {
        revokeLocalAccess()
        operation {store->
            // Under the same mutex as creation: an old logout must never delete a new epoch's keys.
            val owner=currentAccess()
            proofRequire(owner==null || owner===access,DeviceProofError.SCOPE_UNAVAILABLE)
            Collections.list(store.aliases()).filter {it.startsWith(prefix)}.forEach {store.deleteEntry(it)}
        }
    }
    private fun loadCredential(store: KeyStore,id: String): LocalDeviceCredential {
        val entry=store.getEntry(alias(id),null) as? KeyStore.PrivateKeyEntry
            ?: throw DeviceProofException(DeviceProofError.KEY_UNAVAILABLE)
        proofRequire(entry.privateKey.algorithm=="EC",DeviceProofError.KEY_UNAVAILABLE)
        val spki=entry.certificate.publicKey.encoded
            ?: throw DeviceProofException(DeviceProofError.KEY_UNAVAILABLE)
        DeviceProofEncoding.publicKey(spki)
        return LocalDeviceCredential(id,access.scope,spki)
    }
    private suspend fun <T> operation(block: suspend (KeyStore)->T): T=withContext(Dispatchers.IO) {
        mutex.withLock {
            try {
                currentCoroutineContext().ensureActive()
                block(KeyStore.getInstance("AndroidKeyStore").apply {load(null)})
            } catch(e: CancellationException){throw e}
            catch(e: DeviceProofException){throw e}
            catch(_: KeyPermanentlyInvalidatedException){throw DeviceProofException(DeviceProofError.KEY_INVALIDATED)}
            catch(_: java.security.UnrecoverableKeyException){throw DeviceProofException(DeviceProofError.KEY_UNAVAILABLE)}
            catch(_: java.security.GeneralSecurityException){throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)}
            catch(_: java.security.ProviderException){throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)}
            catch(_: IllegalArgumentException){throw DeviceProofException(DeviceProofError.CRYPTO_UNAVAILABLE)}
        }
    }
    private companion object {val mutex=Mutex()}
}
