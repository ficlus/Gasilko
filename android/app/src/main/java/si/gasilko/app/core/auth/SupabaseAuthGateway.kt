package si.gasilko.app.core.auth

import android.content.Context
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.exceptions.RestException
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.logging.LogLevel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import si.gasilko.app.BuildConfig
import java.net.URI

class SupabaseAuthGateway(private val client: SupabaseClient, scope: CoroutineScope) : AuthGateway {
    override val sessions = client.auth.sessionStatus.map { status -> when (status) {
        is SessionStatus.Initializing -> SessionSignal.LOADING
        is SessionStatus.NotAuthenticated -> SessionSignal.UNAUTHENTICATED
        is SessionStatus.Authenticated -> SessionSignal.AUTHENTICATED
        is SessionStatus.RefreshFailure -> SessionSignal.UNAVAILABLE
    } }.stateIn(scope, SharingStarted.Eagerly, SessionSignal.LOADING)
    private suspend fun <T> request(block: suspend () -> T): T = try { block()
    } catch (e: CancellationException) { throw e
    } catch (e: AuthFailure) { throw e
    } catch (e: RestException) {
        throw AuthFailure(when (e.error) {
            "invalid_credentials" -> AuthMessage.INVALID_CREDENTIALS
            "email_not_confirmed" -> AuthMessage.CONFIRM_EMAIL
            "weak_password" -> AuthMessage.WEAK_PASSWORD
            "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired", "bad_jwt", "user_not_found" -> AuthMessage.EXPIRED
            "user_already_exists", "email_exists" -> AuthMessage.SIGNUP_NOTICE
            else -> if (e.statusCode == 401 || e.statusCode == 403) AuthMessage.EXPIRED else AuthMessage.ERROR
        })
    } catch (_: Exception) { throw AuthFailure(AuthMessage.ERROR) }
    override suspend fun startGoogle() = request { client.auth.signInWith(Google); Unit }
    override suspend fun completeGoogle(code: String) = request { client.auth.exchangeCodeForSession(code); Unit }
    fun accessGateway() = si.gasilko.app.core.access.SupabaseAccessGateway(client)
    override suspend fun signIn(email: String, password: String) = request {
        client.auth.signInWith(Email) { this.email = email; this.password = password }; Unit
    }
    override suspend fun signUp(email: String, password: String, displayName: String, language: String): Boolean = request {
        client.auth.signUpWith(Email) { this.email = email; this.password = password
            data = buildJsonObject { put("display_name", displayName); put("preferred_language", language) }
        }
        client.auth.currentSessionOrNull() == null
    }
    override suspend fun verifiedAccountStatus(): String? = request {
        client.auth.awaitInitialization()
        if (client.auth.sessionStatus.value is SessionStatus.RefreshFailure) throw AuthFailure(AuthMessage.ERROR)
        if (client.auth.currentSessionOrNull() == null) throw AuthFailure(AuthMessage.EXPIRED)
        client.auth.retrieveUserForCurrentSession()
        client.postgrest.rpc("get_my_account_status").decodeAs<String?>()
    }
    override suspend fun signOut() = request {
        if (client.auth.sessionStatus.value is SessionStatus.RefreshFailure) throw AuthFailure(AuthMessage.ERROR)
        client.auth.signOut(); Unit
    }
    fun close() { CoroutineScope(Dispatchers.IO).launch { client.close() } }
    companion object {
        fun create(context: Context, scope: CoroutineScope): SupabaseAuthGateway? {
            val url = BuildConfig.SUPABASE_URL; val key = BuildConfig.SUPABASE_PUBLISHABLE_KEY
            if (url.isBlank() || !key.startsWith("sb_publishable_")) return null
            val uri = try { URI(url) } catch (_: Exception) { return null }
            if (uri.scheme != "https" || uri.host.isNullOrBlank()) return null
            val client = createSupabaseClient(url, key) {
                defaultLogLevel = LogLevel.NONE
                install(Auth) {
                    val encrypted = KeystoreSessionManager(context.applicationContext)
                    sessionManager = encrypted
                    codeVerifierCache = encrypted
                    flowType = FlowType.PKCE
                    scheme = BuildConfig.AUTH_REDIRECT_SCHEME
                    host = "auth-callback"
                }
                install(Postgrest)
            }
            return SupabaseAuthGateway(client, scope)
        }
    }
}
