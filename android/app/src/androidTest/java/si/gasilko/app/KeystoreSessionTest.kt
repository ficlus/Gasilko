package si.gasilko.app
import androidx.test.platform.app.InstrumentationRegistry
import android.content.Context
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import si.gasilko.app.core.auth.KeystoreSessionManager
class KeystoreSessionTest {
    @Test fun pkceVerifierSurvivesRecreationEncrypted() = runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val storage=KeystoreSessionManager(context)
        try {
            storage.saveCodeVerifier("non-secret-pkce-fixture")
            assertFalse(context.getSharedPreferences("auth_encrypted",Context.MODE_PRIVATE).getString("pkce",null)!!.contains("non-secret-pkce-fixture"))
            assertEquals("non-secret-pkce-fixture",KeystoreSessionManager(context).loadCodeVerifier())
            storage.deleteCodeVerifier();assertNull(storage.loadCodeVerifier())
        } finally { storage.deleteSession() }
    }
    @Test fun sdkSessionIsEncryptedRestoredAndDeleted() = runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val storage=KeystoreSessionManager(context)
        val fixture=UserSession(accessToken="non-secret-fixture-access",refreshToken="non-secret-fixture-refresh",expiresIn=3600,tokenType="Bearer")
        try {
            storage.saveSession(fixture)
            val disk=context.getSharedPreferences("auth_encrypted",Context.MODE_PRIVATE).getString("session",null)!!
            assertFalse(disk.contains(fixture.accessToken));assertFalse(disk.contains(fixture.refreshToken))
            assertEquals(fixture,KeystoreSessionManager(context).loadSession())
            storage.deleteSession();assertNull(storage.loadSessionOrNull())
        } finally { storage.deleteSession() }
    }
}
