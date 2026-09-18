package si.gasilko.app.core.auth
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AuthRepositoryTest {
    private class Fake : AuthGateway {
        override val sessions = MutableStateFlow(SessionSignal.LOADING)
        var status: String? = "ACTIVE"
        var failure: AuthMessage? = null
        var wait: CompletableDeferred<Unit>? = null
        var confirmed = true
        var receivedName = ""
        override suspend fun verifiedAccountStatus(): String? { wait?.await(); failure?.let { throw AuthFailure(it) }; return status }
        override suspend fun startGoogle() { failure?.let { throw AuthFailure(it) } }
        override suspend fun completeGoogle(code:String) { failure?.let { throw AuthFailure(it) } }
        override suspend fun signIn(email: String, password: String) { failure?.let { throw AuthFailure(it) } }
        override suspend fun signUp(email: String, password: String, displayName: String, language: String): Boolean { receivedName=displayName; return !confirmed }
        override suspend fun signOut() { failure?.let { throw AuthFailure(it) }; sessions.value=SessionSignal.UNAUTHENTICATED }
    }
    @Test fun googleLaunchDoesNotAuthorize() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);runCurrent();r.google();assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route) }
    @Test fun googleCallbackUsesSameStatusGate() = runTest { val g=Fake();g.status="PENDING_APPROVAL";val r=AuthRepository(g,backgroundScope);runCurrent();r.googleCallback("fixture");assertEquals(AuthRoute.PENDING_APPROVAL,r.state.value.route) }
    @Test fun googleExchangeFailureDoesNotAuthorize() = runTest { val g=Fake();g.failure=AuthMessage.ERROR;val r=AuthRepository(g,backgroundScope);runCurrent();r.googleCallback("fixture");assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route) }
    @Test fun startsLoadingWithoutProtectedFlash() = runTest { val r=AuthRepository(Fake(),backgroundScope); assertEquals(AuthRoute.LOADING,r.state.value.route) }
    @Test fun noSessionIsUnauthenticated() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.UNAUTHENTICATED;runCurrent();assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route) }
    private fun restored(status:String,expected:AuthRoute) = runTest { val g=Fake();g.status=status;val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();assertEquals(expected,r.state.value.route) }
    @Test fun activeRoutesToShell() = restored("ACTIVE",AuthRoute.ACTIVE)
    @Test fun pendingRoutesToWaiting() = restored("PENDING_APPROVAL",AuthRoute.PENDING_APPROVAL)
    @Test fun suspendedRoutesToLocked() = restored("SUSPENDED",AuthRoute.SUSPENDED)
    @Test fun rejectedRoutesToLocked() = restored("REJECTED",AuthRoute.REJECTED)
    @Test fun unknownStatusFailsClosed() = restored("ADMIN",AuthRoute.ERROR)
    @Test fun missingProfileFailsClosed() = runTest { val g=Fake();g.status=null;val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();assertEquals(AuthMessage.PROFILE_UNAVAILABLE,r.state.value.message) }
    @Test fun restoreWaitsForVerification() = runTest { val g=Fake();g.wait=CompletableDeferred();val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();assertEquals(AuthRoute.LOADING,r.state.value.route);g.wait!!.complete(Unit);runCurrent();assertEquals(AuthRoute.ACTIVE,r.state.value.route) }
    @Test fun invalidCredentialsAreSafe() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);runCurrent();g.failure=AuthMessage.INVALID_CREDENTIALS;r.signIn("fixture@example.invalid","fixture");assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route);assertEquals(AuthMessage.INVALID_CREDENTIALS,r.state.value.message) }
    @Test fun expiredSessionRequestsSignIn() = runTest { val g=Fake();g.failure=AuthMessage.EXPIRED;val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route) }
    @Test fun networkFailureLocksShell() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();g.failure=AuthMessage.ERROR;r.refresh();assertEquals(AuthRoute.ERROR,r.state.value.route) }
    @Test fun sdkRefreshFailureLocksShell() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();g.sessions.value=SessionSignal.UNAVAILABLE;runCurrent();assertEquals(AuthRoute.ERROR,r.state.value.route) }
    @Test fun pendingRefreshReflectsApproval() = runTest { val g=Fake();g.status="PENDING_APPROVAL";val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();g.status="ACTIVE";r.refresh();assertEquals(AuthRoute.ACTIVE,r.state.value.route) }
    @Test fun signoutClearsRoute() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);g.sessions.value=SessionSignal.AUTHENTICATED;runCurrent();r.signOut();assertEquals(AuthRoute.UNAUTHENTICATED,r.state.value.route) }
    @Test fun failedSignoutLocksAndAllowsRetry() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);runCurrent();g.failure=AuthMessage.ERROR;r.signOut();assertEquals(AuthRoute.ERROR,r.state.value.route) }
    @Test fun signupWaitsForConfirmation() = runTest { val g=Fake();g.confirmed=false;val r=AuthRepository(g,backgroundScope);runCurrent();r.signUp("fixture@example.invalid","test-value-only"," Fixture ","de");assertEquals("Fixture",g.receivedName);assertEquals(AuthMessage.SIGNUP_NOTICE,r.state.value.message) }
    @Test fun signupValidatesSafeFields() = runTest { val g=Fake();val r=AuthRepository(g,backgroundScope);runCurrent();r.signUp("fixture@example.invalid","short","Fixture","de");assertEquals(AuthMessage.WEAK_PASSWORD,r.state.value.message);assertEquals("",g.receivedName) }
    @Test fun missingConfigurationNeverShowsShell() = runTest { val r=AuthRepository(null,backgroundScope);assertEquals(AuthMessage.CONFIGURATION,r.state.value.message);assertEquals(AuthRoute.ERROR,r.state.value.route) }
}
