package chat.trix.android.core.auth

import chat.trix.android.core.ffi.FfiAccountProfile
import chat.trix.android.core.ffi.FfiCreateAccountParams
import chat.trix.android.core.ffi.FfiDeviceStatus
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.TrixFfiException
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

    suspend fun createAccount(request: CreateAccountPayload): CreateAccountResult = withContext(Dispatchers.IO) {
        runFfi("Failed to create account") {
            val response = ffiClient.createAccount(
                FfiCreateAccountParams(
                    handle = request.handle,
                    profileName = request.profileName,
                    profileBio = request.profileBio,
                    deviceDisplayName = request.deviceDisplayName,
                    platform = request.platform,
                    credentialIdentity = request.credentialIdentity,
                    accountRootPubkey = request.accountRootPubkey,
                    accountRootSignature = request.accountRootSignature,
                    transportPubkey = request.transportPubkey,
                ),
            )
            CreateAccountResult(
                accountId = response.accountId,
                deviceId = response.deviceId,
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

    suspend fun getCurrentAccount(accessToken: String): AccountProfile = withContext(Dispatchers.IO) {
        runFfi("Failed to fetch current account") {
            ffiClient.setAccessToken(accessToken)
            ffiClient.getMe().toAccountProfile()
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
    val accountRootPubkey: ByteArray,
    val accountRootSignature: ByteArray,
    val transportPubkey: ByteArray,
)

data class CreateAccountResult(
    val accountId: String,
    val deviceId: String,
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

data class AccountProfile(
    val accountId: String,
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceId: String,
    val deviceStatus: String,
)
