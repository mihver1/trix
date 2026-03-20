package chat.trix.android.core.devices

import android.content.Context
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.Ed25519KeyMaterial
import chat.trix.android.core.ffi.FfiDeviceStatus
import chat.trix.android.core.ffi.FfiDeviceSummary
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.TrixFfiException
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class DeviceRepository(
    context: Context,
    private val session: AuthenticatedSession,
) : AutoCloseable {
    @Suppress("unused")
    private val appContext = context.applicationContext
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl)
    }

    suspend fun loadInventory(): DeviceInventory = withContext(Dispatchers.IO) {
        runFfi("Failed to load device list") {
            loadInventoryInternal()
        }
    }

    suspend fun createLinkIntent(): DeviceLinkIntent = withContext(Dispatchers.IO) {
        runFfi("Failed to create link intent") {
            val response = authenticatedClient().createLinkIntent()
            DeviceLinkIntent(
                linkIntentId = response.linkIntentId,
                qrPayload = response.qrPayload,
                expiresAtUnix = response.expiresAtUnix.toLong(),
            )
        }
    }

    suspend fun approveDevice(deviceId: String): DeviceInventory = withContext(Dispatchers.IO) {
        runFfi("Failed to approve pending device") {
            val accountRoot = restoreAccountRoot()
            authenticatedClient().approveDeviceWithAccountRoot(
                deviceId = deviceId,
                accountRoot = accountRoot.requireAccountRootMaterial(),
                transferBundle = null,
            )
            loadInventoryInternal()
        }
    }

    suspend fun revokeDevice(
        deviceId: String,
        reason: String,
    ): DeviceInventory = withContext(Dispatchers.IO) {
        val normalizedReason = reason.trim().ifEmpty {
            throw IOException("Revoke reason cannot be empty")
        }

        runFfi("Failed to revoke device") {
            val accountRoot = restoreAccountRoot()
            authenticatedClient().revokeDeviceWithAccountRoot(
                deviceId = deviceId,
                reason = normalizedReason,
                accountRoot = accountRoot.requireAccountRootMaterial(),
            )
            loadInventoryInternal()
        }
    }

    override fun close() {
        if (clientDelegate.isInitialized()) {
            clientDelegate.value.close()
        }
    }

    private fun loadInventoryInternal(): DeviceInventory {
        val response = authenticatedClient().listDevices()
        return DeviceInventory(
            accountId = response.accountId,
            devices = response.devices.map(::mapDevice),
        )
    }

    private fun mapDevice(device: FfiDeviceSummary): AccountDevice {
        return AccountDevice(
            deviceId = device.deviceId,
            displayName = device.displayName,
            platform = device.platform,
            status = when (device.deviceStatus) {
                FfiDeviceStatus.PENDING -> AccountDeviceStatus.Pending
                FfiDeviceStatus.ACTIVE -> AccountDeviceStatus.Active
                FfiDeviceStatus.REVOKED -> AccountDeviceStatus.Revoked
            },
            isCurrentDevice = device.deviceId == session.localState.deviceId,
        )
    }

    private fun authenticatedClient(): FfiServerApiClient {
        val client = clientDelegate.value
        client.setAccessToken(session.accessToken)
        return client
    }

    private fun restoreAccountRoot(): Ed25519KeyMaterial {
        val privateSeed = session.localState.accountRootPrivateSeed
            ?: throw IOException(
                "This device does not have local account-root material yet. Approve or revoke from an older trusted device.",
            )
        return Ed25519KeyMaterial.fromAccountRootPrivateSeed(
            privateSeed,
        )
    }

    private inline fun <T> runFfi(
        fallbackMessage: String,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            throw error
        } catch (error: TrixFfiException) {
            throw IOException(error.message ?: fallbackMessage, error)
        } catch (error: UnsatisfiedLinkError) {
            throw IOException("Rust FFI library is not available in the Android app bundle", error)
        } catch (error: RuntimeException) {
            throw IOException(fallbackMessage, error)
        }
    }
}

data class DeviceInventory(
    val accountId: String,
    val devices: List<AccountDevice>,
)

data class AccountDevice(
    val deviceId: String,
    val displayName: String,
    val platform: String,
    val status: AccountDeviceStatus,
    val isCurrentDevice: Boolean,
)

enum class AccountDeviceStatus {
    Pending,
    Active,
    Revoked,
}

data class DeviceLinkIntent(
    val linkIntentId: String,
    val qrPayload: String,
    val expiresAtUnix: Long,
)
