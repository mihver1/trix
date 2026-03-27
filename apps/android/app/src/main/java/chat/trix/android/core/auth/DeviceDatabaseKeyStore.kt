package chat.trix.android.core.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class DeviceDatabaseKeyStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val random = SecureRandom()

    suspend fun read(storeKeyPath: File): ByteArray? = withContext(Dispatchers.IO) {
        if (!storeKeyPath.exists()) {
            return@withContext null
        }

        try {
            val payload = storeKeyPath.readBytes()
            if (payload.size < 13) {
                throw IOException("Stored device database key is corrupted")
            }

            val version = payload[0].toInt()
            if (version != 1) {
                throw IOException("Unsupported device database key version: $version")
            }

            val iv = payload.copyOfRange(1, 13)
            val ciphertext = payload.copyOfRange(13, payload.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(keyAlias(storeKeyPath)),
                GCMParameterSpec(TAG_LENGTH_BITS, iv),
            )
            val plaintext = cipher.doFinal(ciphertext)
            if (plaintext.size != STORE_KEY_BYTES) {
                throw IOException("Stored device database key has invalid size")
            }
            plaintext
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("Failed to decrypt local device database key", error)
        }
    }

    suspend fun getOrCreate(storeKeyPath: File): ByteArray = withContext(Dispatchers.IO) {
        read(storeKeyPath) ?: run {
            val plaintext = ByteArray(STORE_KEY_BYTES).also(random::nextBytes)
            write(storeKeyPath, plaintext)
            plaintext
        }
    }

    suspend fun clear(storeKeyPath: File) = withContext(Dispatchers.IO) {
        if (storeKeyPath.exists()) {
            storeKeyPath.delete()
        }
    }

    private fun write(
        storeKeyPath: File,
        plaintext: ByteArray,
    ) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(keyAlias(storeKeyPath)))
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plaintext)

        storeKeyPath.parentFile?.mkdirs()
        val envelope = ByteBuffer.allocate(1 + iv.size + ciphertext.size)
            .put(1)
            .put(iv)
            .put(ciphertext)
            .array()
        storeKeyPath.writeBytes(envelope)
    }

    private fun getOrCreateKey(alias: String): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = keyStore.getKey(alias, null) as? SecretKey
        if (existing != null) {
            return existing
        }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        val parameterSpec = KeyGenParameterSpec.Builder(
            alias,
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

    private fun keyAlias(storeKeyPath: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(storeKeyPath.absolutePath.encodeToByteArray())
            .joinToString(separator = "") { byte -> "%02x".format(byte) }
        return "${appContext.packageName}.device.store.$digest"
    }

    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val KEY_SIZE_BITS = 256
        private const val TAG_LENGTH_BITS = 128
        private const val STORE_KEY_BYTES = 32
    }
}
