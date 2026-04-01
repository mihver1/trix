package chat.trix.android.core.auth

import android.content.Context
import android.util.Base64
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class LocalAuthStateStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val stateFile = File(appContext.filesDir, "secure/auth-state-v1.bin")
    private val keyAlias = "${appContext.packageName}.auth.state.v1"

    suspend fun read(): LocalAuthState? = withContext(Dispatchers.IO) {
        if (!stateFile.exists()) {
            return@withContext null
        }

        try {
            val payload = stateFile.readBytes()
            if (payload.size < 13) {
                throw IOException("Stored auth state is corrupted")
            }

            val version = payload[0].toInt()
            if (version != 1) {
                throw IOException("Unsupported auth state version: $version")
            }

            val iv = payload.copyOfRange(1, 13)
            val ciphertext = payload.copyOfRange(13, payload.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(TAG_LENGTH_BITS, iv))
            val plaintext = cipher.doFinal(ciphertext)
            LocalAuthState.fromJson(JSONObject(plaintext.decodeToString()))
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("Failed to decrypt local auth state", error)
        }
    }

    suspend fun write(state: LocalAuthState) = withContext(Dispatchers.IO) {
        val plaintext = state.toJson().toString().encodeToByteArray()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plaintext)

        stateFile.parentFile?.mkdirs()
        val envelope = ByteBuffer.allocate(1 + iv.size + ciphertext.size)
            .put(1)
            .put(iv)
            .put(ciphertext)
            .array()
        stateFile.writeBytes(envelope)
    }

    suspend fun clear() = withContext(Dispatchers.IO) {
        if (stateFile.exists()) {
            stateFile.delete()
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existing != null) {
            return existing
        }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        val parameterSpec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setKeySize(KEY_SIZE_BITS)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(parameterSpec)
        return keyGenerator.generateKey()
    }

    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val KEY_SIZE_BITS = 256
        private const val TAG_LENGTH_BITS = 128
    }
}

data class LocalAuthState(
    val accountId: String,
    val deviceId: String,
    val accountSyncChatId: String?,
    val deviceStatus: String?,
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceDisplayName: String,
    val credentialIdentity: ByteArray,
    val accountRootPrivateSeed: ByteArray?,
    val accountRootPublicKey: ByteArray?,
    val transportPrivateSeed: ByteArray,
    val transportPublicKey: ByteArray,
    val accessToken: String?,
    val accessTokenExpiresAtUnix: Long?,
) {
    val hasAccountRootMaterial: Boolean
        get() = accountRootPrivateSeed != null && accountRootPublicKey != null

    fun toSummary(): StoredDeviceSummary {
        return StoredDeviceSummary(
            accountId = accountId,
            deviceId = deviceId,
            profileName = profileName,
            deviceDisplayName = deviceDisplayName,
            deviceStatus = deviceStatus,
        )
    }

    fun toOfflineAuthenticatedSession(baseUrl: String): AuthenticatedSession {
        return AuthenticatedSession(
            localState = this,
            accountProfile = AccountProfile(
                accountId = accountId,
                handle = handle,
                profileName = profileName,
                profileBio = profileBio,
                deviceId = deviceId,
                deviceStatus = deviceStatus ?: "active",
            ),
            accessToken = accessToken.orEmpty(),
            accessTokenExpiresAtUnix = accessTokenExpiresAtUnix ?: 0L,
            baseUrl = baseUrl,
        )
    }

    fun toJson(): JSONObject {
        return JSONObject().apply {
            put("account_id", accountId)
            put("device_id", deviceId)
            put("account_sync_chat_id", accountSyncChatId)
            put("device_status", deviceStatus)
            put("handle", handle)
            put("profile_name", profileName)
            put("profile_bio", profileBio)
            put("device_display_name", deviceDisplayName)
            put("credential_identity_b64", credentialIdentity.encodeBase64())
            put("account_root_private_seed_b64", accountRootPrivateSeed?.encodeBase64())
            put("account_root_public_key_b64", accountRootPublicKey?.encodeBase64())
            put("transport_private_seed_b64", transportPrivateSeed.encodeBase64())
            put("transport_public_key_b64", transportPublicKey.encodeBase64())
            put("access_token", accessToken)
            put("access_token_expires_at_unix", accessTokenExpiresAtUnix)
        }
    }

    companion object {
        fun fromJson(json: JSONObject): LocalAuthState {
            return LocalAuthState(
                accountId = json.getString("account_id"),
                deviceId = json.getString("device_id"),
                accountSyncChatId = json.optNullableString("account_sync_chat_id"),
                deviceStatus = json.optNullableString("device_status"),
                handle = json.optNullableString("handle"),
                profileName = json.getString("profile_name"),
                profileBio = json.optNullableString("profile_bio"),
                deviceDisplayName = json.getString("device_display_name"),
                credentialIdentity = json.requireBase64("credential_identity_b64"),
                accountRootPrivateSeed = json.optNullableBase64("account_root_private_seed_b64"),
                accountRootPublicKey = json.optNullableBase64("account_root_public_key_b64"),
                transportPrivateSeed = json.requireBase64("transport_private_seed_b64"),
                transportPublicKey = json.requireBase64("transport_public_key_b64"),
                accessToken = json.optNullableString("access_token"),
                accessTokenExpiresAtUnix = json.optNullableLong("access_token_expires_at_unix"),
            )
        }
    }
}

data class StoredDeviceSummary(
    val accountId: String,
    val deviceId: String,
    val profileName: String,
    val deviceDisplayName: String,
    val deviceStatus: String?,
)

private fun JSONObject.optNullableString(key: String): String? {
    val value = opt(key)
    return if (value is String && value.isNotBlank()) value else null
}

private fun JSONObject.optNullableLong(key: String): Long? {
    val value = opt(key)
    return when (value) {
        is Number -> value.toLong()
        else -> null
    }
}

private fun JSONObject.requireBase64(key: String): ByteArray {
    val value = getString(key)
    return runCatching {
        Base64.decode(value, Base64.DEFAULT)
    }.getOrElse { error ->
        throw IOException("Invalid base64 payload for $key", error)
    }
}

private fun JSONObject.optNullableBase64(key: String): ByteArray? {
    val value = optNullableString(key) ?: return null
    return runCatching {
        Base64.decode(value, Base64.DEFAULT)
    }.getOrElse { error ->
        throw IOException("Invalid base64 payload for $key", error)
    }
}

private fun ByteArray.encodeBase64(): String {
    return Base64.encodeToString(this, Base64.NO_WRAP)
}
