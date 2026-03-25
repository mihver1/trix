package chat.trix.android.core.devices

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceInventoryPresentationTest {
    @Test
    fun `sort devices shows pending first current second and revoked last`() {
        val pendingDevice = AccountDevice(
            deviceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            displayName = "Pending Mac",
            platform = "macos",
            status = AccountDeviceStatus.Pending,
            isCurrentDevice = false,
        )
        val currentDevice = AccountDevice(
            deviceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            displayName = "Current Phone",
            platform = "android",
            status = AccountDeviceStatus.Active,
            isCurrentDevice = true,
        )
        val otherActiveDevice = AccountDevice(
            deviceId = "cccccccc-cccc-cccc-cccc-cccccccccccc",
            displayName = "Tablet",
            platform = "android",
            status = AccountDeviceStatus.Active,
            isCurrentDevice = false,
        )
        val revokedDevice = AccountDevice(
            deviceId = "dddddddd-dddd-dddd-dddd-dddddddddddd",
            displayName = "Old Mac",
            platform = "macos",
            status = AccountDeviceStatus.Revoked,
            isCurrentDevice = false,
        )

        val sorted = sortedDevicesForDisplay(
            listOf(revokedDevice, otherActiveDevice, currentDevice, pendingDevice),
        )

        assertEquals(
            listOf(
                pendingDevice.deviceId,
                currentDevice.deviceId,
                otherActiveDevice.deviceId,
                revokedDevice.deviceId,
            ),
            sorted.map(AccountDevice::deviceId),
        )
    }

    @Test
    fun `pending device ids only includes pending rows`() {
        val ids = pendingDeviceIds(
            listOf(
                AccountDevice(
                    deviceId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    displayName = "Current Phone",
                    platform = "android",
                    status = AccountDeviceStatus.Active,
                    isCurrentDevice = true,
                ),
                AccountDevice(
                    deviceId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                    displayName = "Pending Mac",
                    platform = "macos",
                    status = AccountDeviceStatus.Pending,
                    isCurrentDevice = false,
                ),
            ),
        )

        assertEquals(setOf("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"), ids)
    }
}
