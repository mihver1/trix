package chat.trix.android.interop

import java.net.URI
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object AndroidInteropLaunchEnvironment {
    const val ACTION_JSON = "TRIX_INTEROP_ACTION_JSON"
    const val RESULT_PATH = "TRIX_INTEROP_RESULT_PATH"
}

data class AndroidInteropConfig(
    val hostBaseUrl: String,
    val deviceReachableBaseUrl: String,
) {
    companion object {
        fun forGenymotion(hostBaseUrl: String): AndroidInteropConfig {
            val normalized = hostBaseUrl.trim().trimEnd('/')
            return AndroidInteropConfig(
                hostBaseUrl = normalized,
                deviceReachableBaseUrl = remapBaseUrlForGenymotion(normalized),
            )
        }
    }
}

enum class AndroidInteropActionName(
    private val wireValue: String,
) {
    SEND_TEXT("sendText"),
    BOOTSTRAP_APPROVED_ACCOUNT("bootstrapApprovedAccount"),
    ;

    fun toWireValue(): String = wireValue

    companion object {
        fun fromWireValue(value: String): AndroidInteropActionName {
            return entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("Unsupported Android interop action: $value")
        }
    }
}

data class AndroidInteropAction(
    val name: AndroidInteropActionName,
    val actor: String,
    val chatAlias: String?,
    val text: String?,
) {
    fun encodedJSON(): ByteArray {
        val payload = buildJsonObject {
            put("name", JsonPrimitive(name.toWireValue()))
            put("actor", JsonPrimitive(actor))
            chatAlias?.let { put("chatAlias", JsonPrimitive(it)) }
            text?.let { put("text", JsonPrimitive(it)) }
        }
        return interopJson.encodeToString(JsonObject.serializer(), payload).encodeToByteArray()
    }

    companion object {
        fun decode(json: String): AndroidInteropAction {
            val payload = interopJson.parseToJsonElement(json).jsonObject
            return AndroidInteropAction(
                name = AndroidInteropActionName.fromWireValue(
                    value = payload.requireString("name"),
                ),
                actor = payload.requireString("actor"),
                chatAlias = payload.optionalString("chatAlias"),
                text = payload.optionalString("text"),
            )
        }
    }
}

data class AndroidInteropActionResult(
    val status: Status,
    val detail: String?,
    val accountId: String?,
    val transcriptPath: String?,
    val screenshotPaths: List<String>?,
) {
    enum class Status(
        private val wireValue: String,
    ) {
        OK("ok"),
        FAILED("failed"),
        ;

        fun toWireValue(): String = wireValue

        companion object {
            fun fromWireValue(value: String): Status {
                return entries.firstOrNull { it.wireValue == value }
                    ?: throw IllegalArgumentException("Unsupported Android interop status: $value")
            }
        }
    }

    fun withDriverArtifacts(
        transcriptPath: String,
        screenshotPaths: List<String>,
    ): AndroidInteropActionResult {
        return copy(
            transcriptPath = transcriptPath,
            screenshotPaths = screenshotPaths.ifEmpty { null },
        )
    }

    fun encodedJSON(): ByteArray {
        val payload = buildJsonObject {
            put("status", JsonPrimitive(status.toWireValue()))
            detail?.let { put("detail", JsonPrimitive(it)) }
            accountId?.let { put("accountId", JsonPrimitive(it)) }
            transcriptPath?.let { put("transcriptPath", JsonPrimitive(it)) }
            screenshotPaths?.let { values ->
                put(
                    "screenshotPaths",
                    buildJsonArray {
                        values.forEach { add(JsonPrimitive(it)) }
                    },
                )
            }
        }
        return interopJson.encodeToString(JsonObject.serializer(), payload).encodeToByteArray()
    }

    companion object {
        fun success(
            accountId: String?,
            detail: String? = null,
        ): AndroidInteropActionResult {
            return AndroidInteropActionResult(
                status = Status.OK,
                detail = detail,
                accountId = accountId,
                transcriptPath = null,
                screenshotPaths = null,
            )
        }

        fun failure(detail: String): AndroidInteropActionResult {
            return AndroidInteropActionResult(
                status = Status.FAILED,
                detail = detail,
                accountId = null,
                transcriptPath = null,
                screenshotPaths = null,
            )
        }

        fun decode(json: String): AndroidInteropActionResult {
            val payload = interopJson.parseToJsonElement(json).jsonObject
            return AndroidInteropActionResult(
                status = Status.fromWireValue(payload.requireString("status")),
                detail = payload.optionalString("detail"),
                accountId = payload.optionalString("accountId"),
                transcriptPath = payload.optionalString("transcriptPath"),
                screenshotPaths = payload.optionalStringList("screenshotPaths"),
            )
        }
    }
}

enum class AndroidInteropDriverPresetAction {
    BOOTSTRAP_APPROVED_ACCOUNT,
    SEND_TEXT_UNSUPPORTED,
    ;

    fun encodedJSON(): ByteArray {
        val action = when (this) {
            BOOTSTRAP_APPROVED_ACCOUNT -> AndroidInteropAction(
                name = AndroidInteropActionName.BOOTSTRAP_APPROVED_ACCOUNT,
                actor = "android-interop-smoke",
                chatAlias = null,
                text = null,
            )

            SEND_TEXT_UNSUPPORTED -> AndroidInteropAction(
                name = AndroidInteropActionName.SEND_TEXT,
                actor = "android-interop-failure-smoke",
                chatAlias = "stub",
                text = "stub",
            )
        }
        return action.encodedJSON()
    }
}

private val interopJson = Json {
    ignoreUnknownKeys = true
}

private fun JsonObject.requireString(key: String): String {
    return this[key]?.jsonPrimitive?.content
        ?: throw IllegalArgumentException("Missing Android interop JSON field: $key")
}

private fun JsonObject.optionalString(key: String): String? {
    return this[key]?.jsonPrimitive?.contentOrNull
}

private fun JsonObject.optionalStringList(key: String): List<String>? {
    val array = this[key]?.jsonArray ?: return null
    return array.mapNotNull { element -> element.jsonPrimitive.contentOrNull }
}

private fun remapBaseUrlForGenymotion(baseUrl: String): String {
    val uri = runCatching { URI(baseUrl) }.getOrElse { return baseUrl }
    val host = uri.host ?: return baseUrl
    val remappedHost = when (host.lowercase()) {
        "127.0.0.1",
        "0.0.0.0",
        "localhost",
        "10.0.2.2",
        -> "10.0.3.2"

        else -> return baseUrl
    }

    return URI(
        uri.scheme,
        uri.userInfo,
        remappedHost,
        uri.port,
        uri.path,
        uri.query,
        uri.fragment,
    ).toString().trimEnd('/')
}
