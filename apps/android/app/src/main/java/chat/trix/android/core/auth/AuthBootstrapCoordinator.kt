package chat.trix.android.core.auth

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.SecureRandom
import java.util.Base64

class AuthBootstrapCoordinator(
    context: Context,
    baseUrl: String,
) {
    private val stateStore = LocalAuthStateStore(context)
    private val authApiClient = AuthApiClient(baseUrl)
    private val base64 = Base64.getEncoder()
    private val base64Decoder = Base64.getDecoder()
    private val random = SecureRandom()

    suspend fun peekStoredDevice(): StoredDeviceSummary? = stateStore.read()?.toSummary()

    suspend fun clearStoredDevice() {
        stateStore.clear()
    }

    suspend fun createAccount(input: BootstrapInput): AuthenticatedSession {
        val accountRootKey = Ed25519KeyMaterial.generate()
        val transportKey = Ed25519KeyMaterial.generate()
        val credentialIdentity = ByteArray(32).also(random::nextBytes)
        val bootstrapMessage = buildBootstrapMessage(
            transportPubkey = transportKey.publicKey,
            credentialIdentity = credentialIdentity,
        )
        val accountRootSignature = accountRootKey.sign(bootstrapMessage)

        val created = authApiClient.createAccount(
            CreateAccountPayload(
                handle = input.handle.nullIfBlank(),
                profileName = input.profileName.trim(),
                profileBio = input.profileBio.nullIfBlank(),
                deviceDisplayName = input.deviceDisplayName.trim(),
                platform = "android",
                credentialIdentityB64 = base64.encodeToString(credentialIdentity),
                accountRootPubkeyB64 = base64.encodeToString(accountRootKey.publicKey),
                accountRootSignatureB64 = base64.encodeToString(accountRootSignature),
                transportPubkeyB64 = base64.encodeToString(transportKey.publicKey),
            ),
        )

        val localState = LocalAuthState(
            accountId = created.accountId,
            deviceId = created.deviceId,
            handle = input.handle.nullIfBlank(),
            profileName = input.profileName.trim(),
            profileBio = input.profileBio.nullIfBlank(),
            deviceDisplayName = input.deviceDisplayName.trim(),
            credentialIdentityB64 = base64.encodeToString(credentialIdentity),
            accountRootPrivateSeedB64 = base64.encodeToString(accountRootKey.privateSeed),
            accountRootPublicKeyB64 = base64.encodeToString(accountRootKey.publicKey),
            transportPrivateSeedB64 = base64.encodeToString(transportKey.privateSeed),
            transportPublicKeyB64 = base64.encodeToString(transportKey.publicKey),
            accessToken = null,
            accessTokenExpiresAtUnix = null,
        )

        val session = signIn(localState)
        stateStore.write(session.localState)
        return session
    }

    suspend fun restoreSession(): AuthenticatedSession {
        val localState = stateStore.read() ?: throw IllegalStateException("No stored device state")
        val session = signIn(localState)
        stateStore.write(session.localState)
        return session
    }

    private suspend fun signIn(localState: LocalAuthState): AuthenticatedSession {
        val transportPrivateSeed = try {
            base64Decoder.decode(localState.transportPrivateSeedB64)
        } catch (error: IllegalArgumentException) {
            throw IOException("Invalid stored transport key material", error)
        }
        val transportKey = Ed25519KeyMaterial.fromPrivateSeed(privateSeed = transportPrivateSeed)
        val challenge = authApiClient.createChallenge(localState.deviceId)
        val challengeBytes = try {
            base64Decoder.decode(challenge.challengeB64)
        } catch (error: IllegalArgumentException) {
            throw IOException("Invalid challenge payload from server", error)
        }
        val signature = transportKey.sign(challengeBytes)
        val authSession = authApiClient.createSession(
            deviceId = localState.deviceId,
            challengeId = challenge.challengeId,
            signatureB64 = base64.encodeToString(signature),
        )
        val accountProfile = authApiClient.getCurrentAccount(authSession.accessToken)
        if (authSession.accountId != localState.accountId) {
            throw IOException("Session account id does not match local device state")
        }
        if (accountProfile.accountId != localState.accountId) {
            throw IOException("Profile account id does not match local device state")
        }
        if (accountProfile.deviceId != localState.deviceId) {
            throw IOException("Profile device id does not match local device state")
        }
        val updatedLocalState = localState.copy(
            handle = accountProfile.handle,
            profileName = accountProfile.profileName,
            profileBio = accountProfile.profileBio,
            accessToken = authSession.accessToken,
            accessTokenExpiresAtUnix = authSession.expiresAtUnix,
        )

        return AuthenticatedSession(
            localState = updatedLocalState,
            accountProfile = accountProfile,
            accessToken = authSession.accessToken,
            accessTokenExpiresAtUnix = authSession.expiresAtUnix,
            baseUrl = authApiClient.baseUrl,
        )
    }

    private fun buildBootstrapMessage(
        transportPubkey: ByteArray,
        credentialIdentity: ByteArray,
    ): ByteArray {
        return ByteArrayOutputStream().use { stream ->
            stream.write(BOOTSTRAP_CONTEXT)
            stream.write(transportPubkey.size.toUInt32Bytes())
            stream.write(transportPubkey)
            stream.write(credentialIdentity.size.toUInt32Bytes())
            stream.write(credentialIdentity)
            stream.toByteArray()
        }
    }

    companion object {
        private val BOOTSTRAP_CONTEXT = "trix-account-bootstrap:v1".encodeToByteArray()
    }
}

data class BootstrapInput(
    val profileName: String,
    val handle: String?,
    val profileBio: String?,
    val deviceDisplayName: String,
)

data class AuthenticatedSession(
    val localState: LocalAuthState,
    val accountProfile: AccountProfile,
    val accessToken: String,
    val accessTokenExpiresAtUnix: Long,
    val baseUrl: String,
)

private fun String?.nullIfBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }

private fun Int.toUInt32Bytes(): ByteArray {
    return byteArrayOf(
        ((this ushr 24) and 0xFF).toByte(),
        ((this ushr 16) and 0xFF).toByte(),
        ((this ushr 8) and 0xFF).toByte(),
        (this and 0xFF).toByte(),
    )
}
