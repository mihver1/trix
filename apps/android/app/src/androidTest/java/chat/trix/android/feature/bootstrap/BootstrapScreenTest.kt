package chat.trix.android.feature.bootstrap

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import chat.trix.android.core.auth.StoredDeviceSummary
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class BootstrapScreenTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun createUserUsesEditedBaseUrl() {
        val usedBaseUrl = AtomicReference<String?>(null)
        composeRule.setContent {
            BootstrapScreen(
                baseUrl = "http://10.0.2.2:8080",
                defaultBaseUrl = "http://10.0.2.2:8080",
                storedDevice = null,
                busyMessage = null,
                errorMessage = null,
                backendErrorMessage = null,
                onCreateAccount = { baseUrl, _ -> usedBaseUrl.set(baseUrl) },
                onCompleteLinkIntent = { _, _ -> },
                onReconnectStoredDevice = null,
                onForgetStoredDevice = null,
            )
        }

        composeRule.onNodeWithTag("bootstrap:base-url-field").performTextReplacement("http://10.0.2.2:9000")
        composeRule.onNodeWithTag("bootstrap:profile-name-field").performTextReplacement("UI Smoke Android")
        composeRule.onNodeWithTag("bootstrap:create-device-name-field").performTextReplacement("Pixel 9")
        composeRule.waitForIdle()
        composeRule
            .onNodeWithTag("bootstrap:create-user-button")
            .performScrollTo()
            .assertIsDisplayed()
            .assertIsEnabled()
            .performClick()

        composeRule.runOnIdle {
            assertEquals("http://10.0.2.2:9000", usedBaseUrl.get())
        }
    }

    @Test
    fun backendServerCardShowsResetAndPendingDeviceState() {
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
                onCreateAccount = { _, _ -> },
                onCompleteLinkIntent = { _, _ -> },
                onReconnectStoredDevice = { _ -> },
                onForgetStoredDevice = {},
            )
        }

        composeRule.onNodeWithText("Current target: http://staging.example:8080").assertIsDisplayed()
        composeRule.onNodeWithText("Pending approval").assertIsDisplayed()
        composeRule.onNodeWithText("Reset").performClick()
        composeRule.onNodeWithTag("bootstrap:base-url-field")
            .assertTextContains("http://10.0.2.2:8080")
    }
}
