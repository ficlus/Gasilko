package si.gasilko.app.core.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.jan.supabase.auth.CodeVerifierCache
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.user.UserSession
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** Only the SDK persistence adapter: SDK retains session parsing, refresh and rotation. */
class KeystoreSessionManager(context: Context) : SessionManager, CodeVerifierCache {
    private val prefs = context.getSharedPreferences("auth_encrypted", Context.MODE_PRIVATE)
    private val lock = Mutex()
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("gasilko_auth_v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("gasilko_auth_v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private suspend fun saveValue(entry: String, value: String) = withContext(Dispatchers.IO) { lock.withLock {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString(entry, Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)).commit())
    } }
    private suspend fun loadValue(entry: String): String = withContext(Dispatchers.IO) { lock.withLock {
        val bytes = Base64.decode(checkNotNull(prefs.getString(entry, null)), Base64.NO_WRAP)
        require(bytes.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12))) }
        cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    } }
    override suspend fun saveSession(session: UserSession) = saveValue("session", json.encodeToString(UserSession.serializer(), session))
    override suspend fun loadSession(): UserSession = json.decodeFromString(UserSession.serializer(), loadValue("session"))
    override suspend fun saveCodeVerifier(codeVerifier: String) = saveValue("pkce", codeVerifier)
    override suspend fun loadCodeVerifier(): String? = if (prefs.contains("pkce")) loadValue("pkce") else null
    override suspend fun deleteCodeVerifier() = withContext(Dispatchers.IO) { lock.withLock { check(prefs.edit().remove("pkce").commit()) } }
    override suspend fun deleteSession() = withContext(Dispatchers.IO) { lock.withLock { check(prefs.edit().clear().commit()) } }
}
