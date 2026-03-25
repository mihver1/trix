package chat.trix.android.core.auth

import chat.trix.android.core.ffi.FfiAccountRootMaterial
import chat.trix.android.core.ffi.FfiCreateDeviceTransferBundleParams
import chat.trix.android.core.ffi.FfiDeviceKeyMaterial
import chat.trix.android.core.ffi.FfiImportedDeviceTransferBundle
import chat.trix.android.core.ffi.TrixFfiException
import java.io.IOException

class Ed25519KeyMaterial private constructor(
    private val accountRootMaterial: FfiAccountRootMaterial?,
    private val deviceMaterial: FfiDeviceKeyMaterial?,
) {
    internal fun requireAccountRootMaterial(): FfiAccountRootMaterial {
        return accountRootMaterial ?: error("Missing account root key material")
    }

    internal fun requireDeviceMaterial(): FfiDeviceKeyMaterial {
        return deviceMaterial ?: error("Missing device key material")
    }

    val privateSeed: ByteArray
        get() = runCryptoFfi("Failed to read private key material") {
            when {
                accountRootMaterial != null -> accountRootMaterial.privateKeyBytes()
                deviceMaterial != null -> deviceMaterial.privateKeyBytes()
                else -> error("Missing key material")
            }
        }

    val publicKey: ByteArray
        get() = runCryptoFfi("Failed to read public key material") {
            when {
                accountRootMaterial != null -> accountRootMaterial.publicKeyBytes()
                deviceMaterial != null -> deviceMaterial.publicKeyBytes()
                else -> error("Missing key material")
            }
        }

    fun sign(message: ByteArray): ByteArray {
        return runCryptoFfi("Failed to sign payload with local key material") {
            when {
                accountRootMaterial != null -> accountRootMaterial.sign(message)
                deviceMaterial != null -> deviceMaterial.sign(message)
                else -> error("Missing key material")
            }
        }
    }

    fun accountBootstrapPayload(
        transportPubkey: ByteArray,
        credentialIdentity: ByteArray,
    ): ByteArray {
        return runCryptoFfi("Failed to build account bootstrap payload") {
            requireAccountRootMaterial().accountBootstrapPayload(
                transportPubkey,
                credentialIdentity,
            )
        }
    }

    fun createDeviceTransferBundle(
        input: DeviceTransferBundleInput,
        senderDeviceKey: Ed25519KeyMaterial,
        recipientTransportPubkey: ByteArray,
    ): ByteArray {
        return runCryptoFfi("Failed to create device transfer bundle") {
            requireAccountRootMaterial().createDeviceTransferBundle(
                FfiCreateDeviceTransferBundleParams(
                    accountId = input.accountId,
                    sourceDeviceId = input.sourceDeviceId,
                    targetDeviceId = input.targetDeviceId,
                    accountSyncChatId = input.accountSyncChatId,
                ),
                senderDeviceKey.requireDeviceMaterial(),
                recipientTransportPubkey,
            )
        }
    }

    fun decryptDeviceTransferBundle(payload: ByteArray): ImportedDeviceTransferBundle {
        return runCryptoFfi("Failed to decrypt device transfer bundle") {
            requireDeviceMaterial().decryptDeviceTransferBundle(payload).toImportedDeviceTransferBundle()
        }
    }

    companion object {
        fun generateAccountRoot(): Ed25519KeyMaterial {
            return runCryptoFfi("Failed to generate account root key material") {
                Ed25519KeyMaterial(
                    accountRootMaterial = FfiAccountRootMaterial.generate(),
                    deviceMaterial = null,
                )
            }
        }

        fun fromAccountRootPrivateSeed(privateSeed: ByteArray): Ed25519KeyMaterial {
            return runCryptoFfi("Failed to restore account root key material") {
                Ed25519KeyMaterial(
                    accountRootMaterial = FfiAccountRootMaterial.fromPrivateKey(privateSeed),
                    deviceMaterial = null,
                )
            }
        }

        fun generateDevice(): Ed25519KeyMaterial {
            return runCryptoFfi("Failed to generate device transport key material") {
                Ed25519KeyMaterial(
                    accountRootMaterial = null,
                    deviceMaterial = FfiDeviceKeyMaterial.generate(),
                )
            }
        }

        fun fromDevicePrivateSeed(privateSeed: ByteArray): Ed25519KeyMaterial {
            return runCryptoFfi("Failed to restore device transport key material") {
                Ed25519KeyMaterial(
                    accountRootMaterial = null,
                    deviceMaterial = FfiDeviceKeyMaterial.fromPrivateKey(privateSeed),
                )
            }
        }

        private inline fun <T> runCryptoFfi(
            fallbackMessage: String,
            block: () -> T,
        ): T {
            return try {
                block()
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

        private fun FfiImportedDeviceTransferBundle.toImportedDeviceTransferBundle(): ImportedDeviceTransferBundle {
            return ImportedDeviceTransferBundle(
                accountId = accountId,
                sourceDeviceId = sourceDeviceId,
                targetDeviceId = targetDeviceId,
                accountSyncChatId = accountSyncChatId,
                accountRootPrivateKey = accountRootPrivateKey,
                accountRootPublicKey = accountRootPublicKey,
            )
        }
    }
}

data class DeviceTransferBundleInput(
    val accountId: String,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val accountSyncChatId: String?,
)

data class ImportedDeviceTransferBundle(
    val accountId: String,
    val sourceDeviceId: String,
    val targetDeviceId: String,
    val accountSyncChatId: String?,
    val accountRootPrivateKey: ByteArray,
    val accountRootPublicKey: ByteArray,
)
