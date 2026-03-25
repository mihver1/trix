package chat.trix.android.core.auth

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StoredDeviceStateTest {
    private val sampleDevice = StoredDeviceSummary(
        accountId = "account-1",
        deviceId = "device-1",
        profileName = "Test User",
        deviceDisplayName = "Pixel Fold",
        deviceStatus = null,
    )

    @Test
    fun `revoked device disables reconnect`() {
        val presentation = storedDevicePresentation(sampleDevice.copy(deviceStatus = "revoked"))

        assertEquals("Device revoked", presentation.title)
        assertEquals(null, presentation.primaryActionLabel)
        assertFalse(presentation.canReconnect)
    }

    @Test
    fun `pending restore error produces approval guidance`() {
        val message = restoreSessionErrorMessage(
            sampleDevice.copy(deviceStatus = "pending"),
            IOException("device is not active"),
        )

        assertTrue(message.contains("pending approval"))
    }

    @Test
    fun `revoked restore error is actionable`() {
        assertTrue(
            isActionableSessionError(
                storedDeviceStatus = "revoked",
                error = IOException("device revoked on server"),
            ),
        )
    }

    @Test
    fun `unknown active-ish error is not marked actionable`() {
        assertFalse(
            isActionableSessionError(
                storedDeviceStatus = null,
                error = IOException("temporary network issue"),
            ),
        )
    }

    @Test
    fun `pending issue notification is specific`() {
        val issue = storedDeviceIssueNotification(
            storedDeviceStatus = "pending",
            error = IOException("device is not active"),
        )

        assertEquals("Trix device is pending approval", issue.title)
        assertTrue(issue.body.contains("trusted device"))
    }
}
