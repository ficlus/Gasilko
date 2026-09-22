package si.gasilko.app.core.auth

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

enum class AuthRoute { LOADING, UNAUTHENTICATED, ACTIVE, PENDING_APPROVAL, SUSPENDED, REJECTED, ERROR }
enum class AuthMessage { NONE, INVALID_CREDENTIALS, CONFIRM_EMAIL, SIGNUP_NOTICE, WEAK_PASSWORD, ERROR, PROFILE_UNAVAILABLE, EXPIRED, CONFIGURATION, OFFLINE_SEVEN_DAYS, OFFLINE_ONE_DAY }
data class AuthState(val route: AuthRoute = AuthRoute.LOADING, val message: AuthMessage = AuthMessage.NONE, val account: String? = null)
enum class SessionSignal { LOADING, AUTHENTICATED, UNAUTHENTICATED, UNAVAILABLE }
class AuthFailure(val reason: AuthMessage) : Exception()
interface AuthGateway {
    fun accountId(): String? = null
    val sessions: StateFlow<SessionSignal>
    suspend fun startGoogle() { throw AuthFailure(AuthMessage.ERROR) }
    suspend fun completeGoogle(code: String) { throw AuthFailure(AuthMessage.ERROR) }
    suspend fun signIn(email: String, password: String)
    suspend fun signUp(email: String, password: String, displayName: String, language: String): Boolean
    suspend fun verifiedAccountStatus(): String?
    suspend fun authorizationNotice(): AuthMessage = AuthMessage.NONE
    suspend fun authorizationRemainingMs(): Long? = null
    suspend fun invalidateAuthorization() {}
    suspend fun signOut()
}
fun accountRoute(status: String?): AuthRoute = when (status) {
    "ACTIVE" -> AuthRoute.ACTIVE
    "PENDING_APPROVAL" -> AuthRoute.PENDING_APPROVAL
    "SUSPENDED" -> AuthRoute.SUSPENDED
    "REJECTED" -> AuthRoute.REJECTED
    else -> AuthRoute.ERROR
}
class AuthRepository(private val gateway: AuthGateway?, private val scope: CoroutineScope) {
    private val mutableState = MutableStateFlow(AuthState())
    val state = mutableState.asStateFlow()
    private val operations = Mutex()
    init {
        if (gateway == null) mutableState.value = AuthState(AuthRoute.ERROR, AuthMessage.CONFIGURATION)
        else scope.launch {
            gateway.sessions.collect { signal -> operations.withLock {
                when (signal) {
                    SessionSignal.LOADING -> mutableState.value = AuthState()
                    SessionSignal.UNAUTHENTICATED -> { gateway.invalidateAuthorization(); mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED) }
                    SessionSignal.UNAVAILABLE -> loadStatus()
                    SessionSignal.AUTHENTICATED -> loadStatus()
                }
            } }
        }
        scope.launch {
            state.map { it.route }.distinctUntilChanged().collectLatest { route ->
                if(route == AuthRoute.ACTIVE) while(true) {
                    try {
                        val remaining = gateway?.authorizationRemainingMs() ?: break
                        val notice = gateway?.authorizationNotice() ?: AuthMessage.NONE
                        if(state.value.route == AuthRoute.ACTIVE) mutableState.value = state.value.copy(message = notice)
                        delay(remaining.coerceIn(1, 60_000))
                    } catch(e: CancellationException) { throw e }
                    catch(_: Exception) {
                        mutableState.value = AuthState(AuthRoute.ERROR, AuthMessage.EXPIRED)
                        break
                    }
                }
            }
        }
    }
    private suspend fun loadStatus() {
        mutableState.value = AuthState()
        try {
            val route = accountRoute(gateway?.verifiedAccountStatus())
            mutableState.value = AuthState(route, if (route == AuthRoute.ERROR) AuthMessage.PROFILE_UNAVAILABLE else AuthMessage.NONE, gateway?.accountId())
        } catch (e: CancellationException) { throw e
        } catch (e: AuthFailure) {
            mutableState.value = AuthState(if (e.reason == AuthMessage.EXPIRED) AuthRoute.UNAUTHENTICATED else AuthRoute.ERROR, e.reason)
        } catch (_: Exception) { mutableState.value = AuthState(AuthRoute.ERROR, AuthMessage.ERROR) }
    }
    suspend fun google() = operations.withLock {
        val client=gateway?:return@withLock
        mutableState.value=AuthState()
        try { client.startGoogle(); mutableState.value=AuthState(AuthRoute.UNAUTHENTICATED)
        } catch(e: CancellationException) { throw e
        } catch(_: Exception) { mutableState.value=AuthState(AuthRoute.UNAUTHENTICATED,AuthMessage.ERROR) }
    }
    suspend fun googleCallback(code: String?) {
        if(code==null) { mutableState.value=AuthState(AuthRoute.UNAUTHENTICATED,AuthMessage.ERROR);return }
        authenticate { it.completeGoogle(code);false }
    }
    suspend fun refresh() = operations.withLock {
        if (gateway == null) return@withLock
        if (gateway.sessions.value == SessionSignal.UNAUTHENTICATED) mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED) else loadStatus()
    }
    suspend fun signIn(email: String, password: String) = authenticate { it.signIn(email.trim(), password); false }
    suspend fun signUp(email: String, password: String, name: String, language: String) {
        if (name.isBlank() || name.length > 120 || password.length < 8 || language !in listOf("sl", "de")) {
            mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED, AuthMessage.WEAK_PASSWORD); return
        }
        authenticate { it.signUp(email.trim(), password, name.trim(), language) }
    }
    private suspend fun authenticate(action: suspend (AuthGateway) -> Boolean) = operations.withLock {
        val client = gateway ?: return@withLock
        mutableState.value = AuthState()
        try {
            if (action(client)) mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED, AuthMessage.SIGNUP_NOTICE) else loadStatus()
        } catch (e: CancellationException) { throw e
        } catch (e: AuthFailure) { mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED, e.reason)
        } catch (_: Exception) { mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED, AuthMessage.ERROR) }
    }
    suspend fun signOut() = operations.withLock {
        mutableState.value = AuthState()
        try { gateway?.signOut(); mutableState.value = AuthState(AuthRoute.UNAUTHENTICATED)
        } catch (e: CancellationException) { throw e
        } catch (_: Exception) { mutableState.value = AuthState(AuthRoute.ERROR, AuthMessage.ERROR) }
    }
}
