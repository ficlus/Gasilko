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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import si.gasilko.app.feature.hydrants.domain.*
import si.gasilko.app.feature.hydrants.data.*

class SupabaseAuthGateway(private val client: SupabaseClient, scope: CoroutineScope, context: Context) : AuthGateway {
    private val offline = OfflineAuthorization(context.applicationContext)
    private fun account() = client.auth.currentUserOrNull()?.id ?: throw AuthFailure(AuthMessage.EXPIRED)
    override fun accountId() = client.auth.currentUserOrNull()?.id
    override fun usingOfflineAuthorization() = offlineAccount != null && offlineAccount == accountId()
    private fun unavailable(e: Exception) = e is java.io.IOException || e is io.ktor.client.plugins.HttpRequestTimeoutException ||
        (e is RestException && e.statusCode >= 500) || (e is RegistryFailure && e.reason in listOf(RegistryError.NETWORK, RegistryError.SERVER))
    override suspend fun invalidateAuthorization() { authorization.withLock { offlineAccount = null; offline.clear() } }
    override suspend fun authorizationNotice(): AuthMessage {
        val remaining = offline.read(account()).second
        return when { remaining <= OfflineAuthorization.DAY -> AuthMessage.OFFLINE_ONE_DAY
            remaining <= 7 * OfflineAuthorization.DAY -> AuthMessage.OFFLINE_SEVEN_DAYS
            else -> AuthMessage.NONE }
    }
    override suspend fun authorizationRemainingMs() = offline.read(account()).second
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
    override suspend fun startGoogle() = request { invalidateAuthorization(); client.auth.awaitInitialization(); client.auth.signInWith(Google); Unit }
    override suspend fun completeGoogle(code: String) = request { client.auth.awaitInitialization(); client.auth.exchangeCodeForSession(code); Unit }
    fun accessGateway() = si.gasilko.app.core.access.SupabaseAccessGateway(client)
    fun hydrantRepository(context: Context): si.gasilko.app.feature.hydrants.domain.HydrantRepository {
        val scheduler = si.gasilko.app.core.sync.HydrantSyncScheduler(context)
        val transport = si.gasilko.app.feature.hydrants.data.SupabaseRegistryTransport(client)
        val online = si.gasilko.app.feature.hydrants.data.OnlineHydrantRepository(transport) { operation, reason ->
            android.util.Log.w("HydrantRegistry", "$operation: ${reason.name}")
        }
        return si.gasilko.app.feature.hydrants.data.RoomHydrantRepository(
            si.gasilko.app.core.database.RegistryDatabase.open(context), online, transport::actor,
            scheduler::select, scheduler::enqueue,
            authorizedOrganizations = { expected ->
                try {
                    if(account() != expected) throw AuthFailure(AuthMessage.EXPIRED)
                    offline.read(expected).first
                } catch(_: AuthFailure) { throw RegistryFailure(RegistryError.EXPIRED) }
            }, refreshAuthorization = {
                try {
                    if(verifyOnline() != "ACTIVE") throw RegistryFailure(RegistryError.FORBIDDEN)
                    offline.read(account()).first
                } catch(e: CancellationException) { throw e }
                catch(e: Exception) {
                    throw RegistryFailure(when { unavailable(e) -> RegistryError.NETWORK
                        e is RegistryFailure -> e.reason
                        e is AuthFailure -> RegistryError.EXPIRED
                        else -> RegistryError.FORBIDDEN })
                }
            }, observeWork = scheduler::observe)
    }
    suspend fun synchronizeHydrants(context: Context, account: String, organization: String) {
        client.auth.awaitInitialization()
        val scheduler = si.gasilko.app.core.sync.HydrantSyncScheduler(context)
        val transport = si.gasilko.app.feature.hydrants.data.SupabaseRegistryTransport(client)
        val checkContext = {
            if(transport.actor() != account || !scheduler.selected(account, organization))
                throw si.gasilko.app.feature.hydrants.domain.RegistryFailure(si.gasilko.app.feature.hydrants.domain.RegistryError.EXPIRED)
        }
        checkContext()
        if(request { verifyOnline() } != "ACTIVE")
            throw si.gasilko.app.feature.hydrants.domain.RegistryFailure(si.gasilko.app.feature.hydrants.domain.RegistryError.FORBIDDEN)
        si.gasilko.app.feature.hydrants.data.HydrantSyncEngine(
            si.gasilko.app.core.database.RegistryDatabase.open(context),
            si.gasilko.app.feature.hydrants.data.OnlineHydrantRepository(transport), account, checkContext).sync(organization)
    }
    override suspend fun signIn(email: String, password: String) = request {
        invalidateAuthorization()
        client.auth.signInWith(Email) { this.email = email; this.password = password }; Unit
    }
    override suspend fun signUp(email: String, password: String, displayName: String, language: String): Boolean = request {
        invalidateAuthorization()
        client.auth.signUpWith(Email) { this.email = email; this.password = password
            data = buildJsonObject { put("display_name", displayName); put("preferred_language", language) }
        }
        client.auth.currentSessionOrNull() == null
    }
    private suspend fun verifyOnline(): String? = authorization.withLock {
        client.auth.awaitInitialization()
        val expected = account()
        try {
            client.auth.retrieveUserForCurrentSession()
            val status = client.postgrest.rpc("get_my_account_status").decodeAs<String?>()
            if(status != "ACTIVE") { offlineAccount = null; offline.clear(); return@withLock status }
            val organizations = OnlineHydrantRepository(SupabaseRegistryTransport(client)).organizations()
            if(account() != expected) throw AuthFailure(AuthMessage.EXPIRED)
            offline.save(expected, organizations)
            offlineAccount = null
            status
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            if(!unavailable(e)) { offlineAccount = null; offline.clear() }
            else offlineAccount = expected
            throw e
        }
    }
    override suspend fun verifiedAccountStatus(): String? {
        try { return verifyOnline() }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            if(unavailable(e)) { offline.read(account()); return "ACTIVE" }
            if(e is AuthFailure) throw e
            throw AuthFailure(AuthMessage.ERROR)
        }
    }
    override suspend fun signOut() = request {
        invalidateAuthorization()
        if (client.auth.sessionStatus.value is SessionStatus.RefreshFailure) throw AuthFailure(AuthMessage.ERROR)
        client.auth.signOut(); Unit
    }
    // UI and default WorkManager share one application-lifetime client/token refresher.
    // Releasing a gateway must not close the client while the other caller is using it.
    fun close() { }
    companion object {
        private val authorization = Mutex()
        @Volatile private var offlineAccount: String? = null
        private var sharedClient: SupabaseClient? = null
        @Synchronized
        fun create(context: Context, scope: CoroutineScope): SupabaseAuthGateway? {
            val url = BuildConfig.SUPABASE_URL; val key = BuildConfig.SUPABASE_PUBLISHABLE_KEY
            if (url.isBlank() || !key.startsWith("sb_publishable_")) return null
            val uri = try { URI(url) } catch (_: Exception) { return null }
            if (uri.scheme != "https" || uri.host.isNullOrBlank()) return null
            val client = sharedClient ?: createSupabaseClient(url, key) {
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
            }.also { sharedClient = it }
            return SupabaseAuthGateway(client, scope, context.applicationContext)
        }
    }
}
