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
    private val vehiclePrefs = context.getSharedPreferences("vehicle_commands_encrypted", Context.MODE_PRIVATE)
    private val lock = Mutex()
    private companion object {val vehicleLock=Mutex()}
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("gasilko_auth_v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("gasilko_auth_v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private suspend fun saveValue(entry: String, value: String, storage: android.content.SharedPreferences = prefs) = withContext(Dispatchers.IO) { lock.withLock {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        check(storage.edit().putString(entry, Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)).commit())
    } }
    private suspend fun loadValue(entry: String, storage: android.content.SharedPreferences = prefs): String = withContext(Dispatchers.IO) { lock.withLock {
        val bytes = Base64.decode(checkNotNull(storage.getString(entry, null)), Base64.NO_WRAP)
        require(bytes.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12))) }
        cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    } }
    // One scoped command/credential journal and one outstanding STOP; NEVER GPS samples.
    // Static lock spans manager instances; generation/CAS prevents old callbacks
    // overwriting a newer identity's credential/immutable request journal.
    suspend fun saveVehicleState(account: String,value: String,current: ()->Boolean={true},expectedCredential: String?=null) =
        vehicleLock.withLock {
            check(current())
            if(expectedCredential!=null && vehicleCredential(account)!=expectedCredential)return@withLock
            saveValue("state/$account",value,vehiclePrefs)
            check(current())
        }
    private suspend fun vehicleCredential(account: String): String? {
        if(!vehiclePrefs.contains("state/$account"))return null
        val value=Json.parseToJsonElement(loadValue("state/$account",vehiclePrefs)) as? kotlinx.serialization.json.JsonObject
        return (value?.get("credential") as? kotlinx.serialization.json.JsonPrimitive)?.content
    }
    suspend fun loadVehicleState(account: String): String?=vehicleLock.withLock {
        if(vehiclePrefs.contains("state/$account"))loadValue("state/$account",vehiclePrefs) else null
    }
    suspend fun saveVehicleStop(account: String,value: String)=vehicleLock.withLock {
        if(vehiclePrefs.contains("stop/$account")) {
            val old=loadValue("stop/$account",vehiclePrefs)
            check(Json.parseToJsonElement(old)==Json.parseToJsonElement(value)) {"PENDING_WITHDRAWAL_EXISTS"}
        } else saveValue("stop/$account",value,vehiclePrefs)
    }
    suspend fun loadVehicleStop(account: String): String?=vehicleLock.withLock {
        if(vehiclePrefs.contains("stop/$account"))loadValue("stop/$account",vehiclePrefs) else null
    }
    suspend fun clearVehicleStop(account: String)=vehicleLock.withLock {withContext(Dispatchers.IO){lock.withLock {
        check(vehiclePrefs.edit().remove("stop/$account").commit())
    }}}
    suspend fun clearVehicleState(account: String,credential: String)=vehicleLock.withLock {
        if(vehicleCredential(account)==credential)withContext(Dispatchers.IO){lock.withLock {
            check(vehiclePrefs.edit().remove("state/$account").commit())
        }}
    }
    override suspend fun saveSession(session: UserSession) = saveValue("session", json.encodeToString(UserSession.serializer(), session))
    suspend fun saveIncidentLease(account: String,org: String,value: String) = saveValue("incident_lease/$account/$org",value)
    suspend fun loadIncidentLease(account: String,org: String): String? =
        if(prefs.contains("incident_lease/$account/$org")) loadValue("incident_lease/$account/$org") else null
    suspend fun clearIncidentLease(account: String,org: String) = withContext(Dispatchers.IO) { lock.withLock {
        check(prefs.edit().remove("incident_lease/$account/$org").commit())
    } }
    suspend fun saveAuthorization(value: String) = saveValue("authorization", value)
    suspend fun loadAuthorization(): String? = if(prefs.contains("authorization")) loadValue("authorization") else null
    suspend fun clearAuthorization() = withContext(Dispatchers.IO) { lock.withLock {
        val edit=prefs.edit().remove("authorization")
        prefs.all.keys.filter { it.startsWith("incident_lease/") }.forEach { edit.remove(it) }
        check(edit.commit())
    } }
    override suspend fun loadSession(): UserSession = json.decodeFromString(UserSession.serializer(), loadValue("session"))
    override suspend fun saveCodeVerifier(codeVerifier: String) = saveValue("pkce", codeVerifier)
    override suspend fun loadCodeVerifier(): String? = if (prefs.contains("pkce")) loadValue("pkce") else null
    override suspend fun deleteCodeVerifier() = withContext(Dispatchers.IO) { lock.withLock { check(prefs.edit().remove("pkce").commit()) } }
    override suspend fun deleteSession() = withContext(Dispatchers.IO) { lock.withLock { check(prefs.edit().clear().commit()) } }
}
