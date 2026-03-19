package chat.trix.android.core.auth

import java.security.SecureRandom
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.math.ec.rfc8032.Ed25519

class Ed25519KeyMaterial private constructor(
    private val privateKey: Ed25519PrivateKeyParameters,
) {
    val privateSeed: ByteArray
        get() = privateKey.encoded

    val publicKey: ByteArray
        get() = privateKey.generatePublicKey().encoded

    fun sign(message: ByteArray): ByteArray {
        val signature = ByteArray(Ed25519PrivateKeyParameters.SIGNATURE_SIZE)
        privateKey.sign(
            Ed25519.Algorithm.Ed25519,
            null,
            message,
            0,
            message.size,
            signature,
            0,
        )
        return signature
    }

    companion object {
        private val secureRandom = SecureRandom()

        fun generate(): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(Ed25519PrivateKeyParameters(secureRandom))
        }

        fun fromPrivateSeed(privateSeed: ByteArray): Ed25519KeyMaterial {
            return Ed25519KeyMaterial(Ed25519PrivateKeyParameters(privateSeed))
        }
    }
}
