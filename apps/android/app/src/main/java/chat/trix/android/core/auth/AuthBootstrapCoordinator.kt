package chat.trix.android.core.auth

import android.content.Context
import chat.trix.android.core.ffi.FfiMlsFacade
import java.io.File
import java.io.IOException
import java.security.SecureRandom
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AuthBootstrapCoordinator(
    context: Context,
    baseUrl: String,
) {
    private val appContext = context.applicationContext
    private val stateStore = LocalAuthStateStore(context)
    private val authApiClient = AuthApiClient(baseUrl)
    private val random = SecureRandom()

    suspend fun peekStoredDevice(): StoredDeviceSummary? = stateStore.read()?.toSummary()

    suspend fun clearStoredDevice() {
        stateStore.clear()
    }

    suspend fun createAccount(input: BootstrapInput): AuthenticatedSession {
        val accountRootKey = Ed25519KeyMaterial.generateAccountRoot()
        val transportKey = Ed25519KeyMaterial.generateDevice()
        val credentialIdentity = ByteArray(32).also(random::nextBytes)

        val created = authApiClient.createAccount(
            CreateAccountPayload(
                handle = input.handle.nullIfBlank(),
                profileName = input.profileName.trim(),
                profileBio = input.profileBio.nullIfBlank(),
                deviceDisplayName = input.deviceDisplayName.trim(),
                platform = "android",
                credentialIdentity = credentialIdentity,
            ),
            accountRootKey = accountRootKey,
            transportKey = transportKey,
        )

        val localState = LocalAuthState(
            accountId = created.accountId,
            deviceId = created.deviceId,
            accountSyncChatId = created.accountSyncChatId,
            deviceStatus = "active",
            handle = input.handle.nullIfBlank(),
            profileName = input.profileName.trim(),
            profileBio = input.profileBio.nullIfBlank(),
            deviceDisplayName = input.deviceDisplayName.trim(),
            credentialIdentity = credentialIdentity,
            accountRootPrivateSeed = accountRootKey.privateSeed,
            accountRootPublicKey = accountRootKey.publicKey,
            transportPrivateSeed = transportKey.privateSeed,
            transportPublicKey = transportKey.publicKey,
            accessToken = null,
            accessTokenExpiresAtUnix = null,
        )

        val session = signIn(localState)
        stateStore.write(session.localState)
        return session
    }

    suspend fun completeLinkDevice(input: LinkDeviceInput): StoredDeviceSummary {
        val normalizedDeviceName = input.deviceDisplayName.trim().ifEmpty {
            throw IOException("Device name cannot be empty")
        }
        val transportKey = Ed25519KeyMaterial.generateDevice()
        val credentialIdentity = ByteArray(32).also(random::nextBytes)
        val pendingStorageRoot = pendingLinkStorageRoot(input.linkIntent.linkIntentId)
        val mlsStorageRoot = File(pendingStorageRoot, "mls")
        val keyPackages = preparePendingLinkKeyPackages(
            credentialIdentity = credentialIdentity,
            mlsStorageRoot = mlsStorageRoot,
        )

        try {
            val completed = authApiClient.completeLinkIntentWithDeviceKey(
                linkIntentId = input.linkIntent.linkIntentId,
                request = CompleteLinkIntentPayload(
                    linkToken = input.linkIntent.linkToken,
                    deviceDisplayName = normalizedDeviceName,
                    platform = ANDROID_PLATFORM,
                    credentialIdentity = credentialIdentity,
                    keyPackages = keyPackages,
                ),
                deviceKey = transportKey,
            )

            finalizePendingLinkStorage(
                fromRoot = pendingStorageRoot,
                accountId = completed.accountId,
                deviceId = completed.pendingDeviceId,
            )

            val localState = LocalAuthState(
                accountId = completed.accountId,
                deviceId = completed.pendingDeviceId,
                accountSyncChatId = null,
                deviceStatus = completed.deviceStatus,
                handle = null,
                profileName = "Linked account",
                profileBio = null,
                deviceDisplayName = normalizedDeviceName,
                credentialIdentity = credentialIdentity,
                accountRootPrivateSeed = null,
                accountRootPublicKey = null,
                transportPrivateSeed = transportKey.privateSeed,
                transportPublicKey = transportKey.publicKey,
                accessToken = null,
                accessTokenExpiresAtUnix = null,
            )
            stateStore.write(localState)
            return localState.toSummary()
        } catch (error: IOException) {
            pendingStorageRoot.deleteRecursively()
            throw error
        }
    }

    suspend fun restoreSession(): AuthenticatedSession {
        val localState = stateStore.read() ?: throw IllegalStateException("No stored device state")
        val session = signIn(localState)
        stateStore.write(session.localState)
        return session
    }

    private suspend fun signIn(localState: LocalAuthState): AuthenticatedSession {
        val transportKey = try {
            Ed25519KeyMaterial.fromDevicePrivateSeed(privateSeed = localState.transportPrivateSeed)
        } catch (error: RuntimeException) {
            throw IOException("Invalid stored transport key material", error)
        }
        val authSession = authApiClient.authenticateWithDeviceKey(
            deviceId = localState.deviceId,
            deviceKey = transportKey,
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
            deviceStatus = accountProfile.deviceStatus,
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

    private suspend fun preparePendingLinkKeyPackages(
        credentialIdentity: ByteArray,
        mlsStorageRoot: File,
    ) = withContext(Dispatchers.IO) {
        if (mlsStorageRoot.parentFile?.exists() == true) {
            mlsStorageRoot.parentFile?.deleteRecursively()
        }
        mlsStorageRoot.parentFile?.mkdirs()

        var facade: FfiMlsFacade? = null
        try {
            facade = FfiMlsFacade.newPersistent(
                credentialIdentity = credentialIdentity,
                storageRoot = mlsStorageRoot.absolutePath,
            )
            val packages = facade.generatePublishKeyPackages(LINK_KEY_PACKAGE_COUNT.toUInt())
            facade.saveState()
            packages
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            throw error
        } catch (error: UnsatisfiedLinkError) {
            throw IOException("Rust FFI library is not available in the Android app bundle", error)
        } catch (error: Exception) {
            throw IOException("Failed to prepare MLS state for linked device", error)
        } finally {
            facade?.close()
        }
    }

    private suspend fun finalizePendingLinkStorage(
        fromRoot: File,
        accountId: String,
        deviceId: String,
    ) = withContext(Dispatchers.IO) {
        val finalRoot = deviceSessionRoot(accountId, deviceId)
        if (!fromRoot.exists()) {
            return@withContext
        }

        finalRoot.parentFile?.mkdirs()
        if (finalRoot.exists()) {
            finalRoot.deleteRecursively()
        }
        if (!fromRoot.renameTo(finalRoot)) {
            fromRoot.copyRecursively(finalRoot, overwrite = true)
            fromRoot.deleteRecursively()
        }
    }

    private fun pendingLinkStorageRoot(linkIntentId: String): File {
        return File(appContext.filesDir, "trix/pending-links/$linkIntentId")
    }

    private fun deviceSessionRoot(accountId: String, deviceId: String): File {
        return File(
            appContext.filesDir,
            "trix/accounts/$accountId/devices/$deviceId",
        )
    }

    companion object {
        private const val ANDROID_PLATFORM = "android"
        private const val LINK_KEY_PACKAGE_COUNT = 24
    }
}

data class BootstrapInput(
    val profileName: String,
    val handle: String?,
    val profileBio: String?,
    val deviceDisplayName: String,
)

data class LinkDeviceInput(
    val linkIntent: ParsedLinkIntentPayload,
    val deviceDisplayName: String,
)

data class LinkExistingAccountInput(
    val rawPayload: String,
    val deviceDisplayName: String,
)

data class AuthenticatedSession(
    val localState: LocalAuthState,
    val accountProfile: AccountProfile,
    val accessToken: String,
    val accessTokenExpiresAtUnix: Long,
    val baseUrl: String,
)

data class ParsedLinkIntentPayload(
    val baseUrl: String,
    val linkIntentId: String,
    val linkToken: String,
)

private fun String?.nullIfBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
