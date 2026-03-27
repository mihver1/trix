package chat.trix.android.feature.bootstrap

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import chat.trix.android.core.auth.BootstrapInput
import chat.trix.android.core.auth.LinkExistingAccountInput
import chat.trix.android.core.auth.StoredDeviceSummary
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class BootstrapScreenTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun backendServerCardAppliesEditedBaseUrl() {
        var appliedBaseUrl: String? = null
        composeRule.setContent {
            BootstrapScreen(
                baseUrl = "http://10.0.2.2:8080",
                defaultBaseUrl = "http://10.0.2.2:8080",
                storedDevice = null,
                busyMessage = null,
                errorMessage = null,
                backendErrorMessage = null,
                onUpdateBaseUrl = { appliedBaseUrl = it },
                onResetBaseUrl = {},
                onCreateAccount = {},
                onCompleteLinkIntent = {},
                onReconnectStoredDevice = null,
                onForgetStoredDevice = null,
            )
        }

        composeRule.onNodeWithTag("bootstrap:base-url-field").performTextReplacement("http://10.0.2.2:9000")
        composeRule.onNodeWithText("Apply").performClick()

        assertEquals("http://10.0.2.2:9000", appliedBaseUrl)
    }

    @Test
    fun backendServerCardShowsResetAndPendingDeviceState() {
        var resetClicks = 0
        composeRule.setContent {
            BootstrapScreen(
                baseUrl = "http://staging.example:8080",
                defaultBaseUrl = "http://10.0.2.2:8080",
                storedDevice = StoredDeviceSummary(
                    accountId = "account-1",
                    deviceId = "device-1",
                    profileName = "Linked account",
                    deviceDisplayName = "Pixel Fold",
                    deviceStatus = "pending",
                ),
                busyMessage = null,
                errorMessage = null,
                backendErrorMessage = null,
                onUpdateBaseUrl = {},
                onResetBaseUrl = { resetClicks += 1 },
                onCreateAccount = { _: BootstrapInput -> },
                onCompleteLinkIntent = { _: LinkExistingAccountInput -> },
                onReconnectStoredDevice = {},
                onForgetStoredDevice = {},
            )
        }

        composeRule.onNodeWithText("Active endpoint: http://staging.example:8080").assertIsDisplayed()
        composeRule.onNodeWithText("Approval pending").assertIsDisplayed()
        composeRule.onNodeWithText("Reset").performClick()

        assertEquals(1, resetClicks)
    }
}
