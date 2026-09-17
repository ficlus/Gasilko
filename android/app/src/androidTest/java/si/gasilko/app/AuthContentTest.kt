package si.gasilko.app
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import si.gasilko.app.core.auth.*
import si.gasilko.app.feature.auth.AuthContent
class AuthContentTest {
    @get:Rule val compose=createComposeRule()
    private fun text(id:Int)=InstrumentationRegistry.getInstrumentation().targetContext.getString(id)
    private fun show(route:AuthRoute) { compose.setContent { MaterialTheme { AuthContent(AuthState(route),{_,_->},{_,_,_,_->},{},{}) } } }
    @Test fun loadingHidesAuthenticatedShell() { show(AuthRoute.LOADING);compose.onNodeWithText(text(R.string.auth_loading)).assertIsDisplayed();compose.onNodeWithText(text(R.string.auth_active)).assertDoesNotExist() }
    @Test fun pendingShowsRefreshAndSignout() { show(AuthRoute.PENDING_APPROVAL);compose.onNodeWithText(text(R.string.auth_pending)).assertIsDisplayed();compose.onNodeWithText(text(R.string.auth_refresh_status)).assertIsDisplayed();compose.onNodeWithText(text(R.string.auth_sign_out)).assertIsDisplayed() }
    @Test fun suspendedHidesProtectedShell() { show(AuthRoute.SUSPENDED);compose.onNodeWithText(text(R.string.auth_suspended)).assertIsDisplayed();compose.onNodeWithText(text(R.string.auth_active)).assertDoesNotExist() }
    @Test fun rejectedHidesProtectedShell() { show(AuthRoute.REJECTED);compose.onNodeWithText(text(R.string.auth_rejected)).assertIsDisplayed() }
}
