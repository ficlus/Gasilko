package si.gasilko.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test

class LaunchTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun launchShowsLocalizedFoundation() {
        compose.onNodeWithText(compose.activity.getString(R.string.app_name)).assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.foundation_running)).assertIsDisplayed()
    }
}
