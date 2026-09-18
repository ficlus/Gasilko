package si.gasilko.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import si.gasilko.app.core.access.*
import si.gasilko.app.feature.auth.AccessScreen

class AccessRefreshTest {
    @get:Rule val compose = createComposeRule()
    @Test fun requestRefreshAlsoRequestsAuthoritativeAccountRefresh() {
        val gateway = object : AccessGateway {
            override suspend fun countries() = emptyList<Choice>()
            override suspend fun areas(country:String,parent:String?,after:String?) = emptyList<Choice>()
            override suspend fun organizations(country:String,area:String?,after:String?) = emptyList<Organization>()
            override suspend fun history(last:AccessRequest?) = listOf(AccessRequest("id","Organization","FIREFIGHTER","APPROVED","2026-01-01"))
            override suspend fun submit(organization:String,role:String) = "ERROR"
        }
        var refreshed = false
        val repository = AccessRepository(gateway)
        compose.setContent { MaterialTheme { AccessScreen(repository, {}, {}, { refreshed = true }) } }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.onNodeWithText(context.getString(R.string.access_refresh_requests)).performScrollTo().performClick()
        compose.runOnIdle { assertTrue(refreshed) }
        compose.onNodeWithText(context.getString(R.string.access_request_approved)).assertExists()
    }
}
