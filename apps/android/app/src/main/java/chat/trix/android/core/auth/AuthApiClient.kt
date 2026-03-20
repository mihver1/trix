package chat.trix.android.core.auth

import chat.trix.android.core.ffi.FfiAccountProfile
import chat.trix.android.core.ffi.FfiCompleteLinkIntentWithDeviceKeyParams
import chat.trix.android.core.ffi.FfiCreateAccountParams
import chat.trix.android.core.ffi.FfiCreateAccountWithMaterialsParams
import chat.trix.android.core.ffi.FfiDeviceStatus
import chat.trix.android.core.ffi.FfiPublishKeyPackage
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.ffi.FfiUpdateAccountProfileParams
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext

class AuthApiClient(
    val baseUrl: String,
) {
    private val ffiClient by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(baseUrl)
    }

    suspend fun createAccount(
        request: CreateAccountPayload,
        accountRootKey: Ed25519KeyMaterial,
        transportKey: Ed25519KeyMaterial,
    ): CreateAccountResult = withContext(Dispatchers.IO) {
        runFfi("Failed to create account") {
            val response = ffiClient.createAccountWithMaterials(
                FfiCreateAccountWithMaterialsParams(
                    handle = request.handle,
                    profileName = request.profileName,
                    profileBio = request.profileBio,
                    deviceDisplayName = request.deviceDisplayName,
                    platform = request.platform,
                    credentialIdentity = request.credentialIdentity,
                ),
                accountRootKey.requireAccountRootMaterial(),
                transportKey.requireDeviceMaterial(),
            )
            CreateAccountResult(
                accountId = response.accountId,
                deviceId = response.deviceId,
                accountSyncChatId = response.accountSyncChatId,
            )
        }
    }

    suspend fun createChallenge(deviceId: String): AuthChallengeResult = withContext(Dispatchers.IO) {
        runFfi("Failed to create auth challenge") {
            val response = ffiClient.createAuthChallenge(deviceId)
            AuthChallengeResult(
                challengeId = response.challengeId,
                challenge = response.challenge,
                expiresAtUnix = response.expiresAtUnix.toLong(),
            )
        }
    }

    suspend fun createSession(
        deviceId: String,
        challengeId: String,
        signature: ByteArray,
    ): AuthSessionResult = withContext(Dispatchers.IO) {
        runFfi("Failed to create auth session") {
            val response = ffiClient.createAuthSession(
                deviceId = deviceId,
                challengeId = challengeId,
                signature = signature,
            )
            AuthSessionResult(
                accessToken = response.accessToken,
                expiresAtUnix = response.expiresAtUnix.toLong(),
                accountId = response.accountId,
                deviceStatus = response.deviceStatus.asApiString(),
            )
        }
    }

    suspend fun authenticateWithDeviceKey(
        deviceId: String,
        deviceKey: Ed25519KeyMaterial,
        setAccessToken: Boolean = true,
    ): AuthSessionResult = withContext(Dispatchers.IO) {
        runFfi("Failed to authenticate with device key") {
            val response = ffiClient.authenticateWithDeviceKey(
                deviceId = deviceId,
                deviceKeys = deviceKey.requireDeviceMaterial(),
                setAccessToken = setAccessToken,
            )
            AuthSessionResult(
                accessToken = response.accessToken,
                expiresAtUnix = response.expiresAtUnix.toLong(),
                accountId = response.accountId,
                deviceStatus = response.deviceStatus.asApiString(),
            )
        }
    }

    suspend fun completeLinkIntentWithDeviceKey(
        linkIntentId: String,
        request: CompleteLinkIntentPayload,
        deviceKey: Ed25519KeyMaterial,
    ): CompletedLinkIntentResult = withContext(Dispatchers.IO) {
        runFfi("Failed to complete device link intent") {
            val response = ffiClient.completeLinkIntentWithDeviceKey(
                linkIntentId = linkIntentId,
                params = FfiCompleteLinkIntentWithDeviceKeyParams(
                    linkToken = request.linkToken,
                    deviceDisplayName = request.deviceDisplayName,
                    platform = request.platform,
                    credentialIdentity = request.credentialIdentity,
                    keyPackages = request.keyPackages,
                ),
                deviceKeys = deviceKey.requireDeviceMaterial(),
            )
            CompletedLinkIntentResult(
                accountId = response.accountId,
                pendingDeviceId = response.pendingDeviceId,
                deviceStatus = response.deviceStatus.asApiString(),
                bootstrapPayload = response.bootstrapPayload,
            )
        }
    }

    suspend fun getCurrentAccount(accessToken: String): AccountProfile = withContext(Dispatchers.IO) {
        runFfi("Failed to fetch current account") {
            ffiClient.setAccessToken(accessToken)
            ffiClient.getMe().toAccountProfile()
        }
    }

    suspend fun importDeviceTransferBundle(
        accessToken: String,
        deviceId: String,
        deviceKey: Ed25519KeyMaterial,
    ): ImportedDeviceTransferBundle? = withContext(Dispatchers.IO) {
        try {
            runFfi("Failed to import device transfer bundle") {
                ffiClient.setAccessToken(accessToken)
                val bundle = ffiClient.getDeviceTransferBundle(deviceId)
                deviceKey.decryptDeviceTransferBundle(bundle.transferBundle)
            }
        } catch (error: IOException) {
            if (error.message?.contains("transfer bundle not found", ignoreCase = true) == true) {
                null
            } else {
                throw error
            }
        }
    }

    suspend fun updateCurrentAccount(
        accessToken: String,
        request: UpdateAccountProfilePayload,
    ): AccountProfile = withContext(Dispatchers.IO) {
        runFfi("Failed to update account profile") {
            ffiClient.setAccessToken(accessToken)
            ffiClient.updateAccountProfile(
                FfiUpdateAccountProfileParams(
                    handle = request.handle,
                    profileName = request.profileName,
                    profileBio = request.profileBio,
                ),
            ).toAccountProfile()
        }
    }

    private inline fun <T> runFfi(
        fallbackMessage: String,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: TrixFfiException) {
            throw IOException(error.message ?: fallbackMessage, error)
        } catch (error: UnsatisfiedLinkError) {
            throw IOException("Rust FFI library is not available in the Android app bundle", error)
        } catch (error: RuntimeException) {
            throw IOException(fallbackMessage, error)
        }
    }

    companion object {
        private fun FfiAccountProfile.toAccountProfile(): AccountProfile {
            return AccountProfile(
                accountId = accountId,
                handle = handle,
                profileName = profileName,
                profileBio = profileBio,
                deviceId = deviceId,
                deviceStatus = deviceStatus.asApiString(),
            )
        }

        private fun FfiDeviceStatus.asApiString(): String = name.lowercase()
    }
}

data class CreateAccountPayload(
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceDisplayName: String,
    val platform: String,
    val credentialIdentity: ByteArray,
)

data class CreateAccountResult(
    val accountId: String,
    val deviceId: String,
    val accountSyncChatId: String,
)

data class AuthChallengeResult(
    val challengeId: String,
    val challenge: ByteArray,
    val expiresAtUnix: Long,
)

data class AuthSessionResult(
    val accessToken: String,
    val expiresAtUnix: Long,
    val accountId: String,
    val deviceStatus: String,
)

data class CompleteLinkIntentPayload(
    val linkToken: String,
    val deviceDisplayName: String,
    val platform: String,
    val credentialIdentity: ByteArray,
    val keyPackages: List<FfiPublishKeyPackage>,
)

data class CompletedLinkIntentResult(
    val accountId: String,
    val pendingDeviceId: String,
    val deviceStatus: String,
    val bootstrapPayload: ByteArray,
)

data class AccountProfile(
    val accountId: String,
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceId: String,
    val deviceStatus: String,
)

data class UpdateAccountProfilePayload(
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
)
