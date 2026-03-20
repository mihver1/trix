package chat.trix.android.core.auth

import chat.trix.android.core.ffi.FfiAccountRootMaterial
import chat.trix.android.core.ffi.FfiDeviceKeyMaterial

class Ed25519KeyMaterial private constructor(
    private val accountRootMaterial: FfiAccountRootMaterial?,
    private val deviceMaterial: FfiDeviceKeyMaterial?,
) {
    val privateSeed: ByteArray
        get() = when {
            accountRootMaterial != null -> accountRootMaterial.privateKeyBytes()
            deviceMaterial != null -> deviceMaterial.privateKeyBytes()
            else -> error("Missing key material")
        }

    val publicKey: ByteArray
        get() = when {
            accountRootMaterial != null -> accountRootMaterial.publicKeyBytes()
            deviceMaterial != null -> deviceMaterial.publicKeyBytes()
            else -> error("Missing key material")
        }

    fun sign(message: ByteArray): ByteArray {
        return when {
            accountRootMaterial != null -> accountRootMaterial.sign(message)
            deviceMaterial != null -> deviceMaterial.sign(message)
            else -> error("Missing key material")
        }
    }

    companion object {
        fun generateAccountRoot(): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(
                accountRootMaterial = FfiAccountRootMaterial.generate(),
                deviceMaterial = null,
            )
        }

        fun fromAccountRootPrivateSeed(privateSeed: ByteArray): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(
                accountRootMaterial = FfiAccountRootMaterial.fromPrivateKey(privateSeed),
                deviceMaterial = null,
            )
        }

        fun generateDevice(): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(
                accountRootMaterial = null,
                deviceMaterial = FfiDeviceKeyMaterial.generate(),
            )
        }

        fun fromDevicePrivateSeed(privateSeed: ByteArray): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(
                accountRootMaterial = null,
                deviceMaterial = FfiDeviceKeyMaterial.fromPrivateKey(privateSeed),
            )
        }
    }
}
