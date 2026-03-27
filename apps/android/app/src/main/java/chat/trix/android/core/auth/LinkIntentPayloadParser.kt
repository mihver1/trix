package chat.trix.android.core.auth

import java.io.IOException
import java.net.URI
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

fun parseLinkIntentPayload(
    rawPayload: String,
    fallbackBaseUrl: String,
): ParsedLinkIntentPayload {
    val payload = runCatching {
        Json.parseToJsonElement(rawPayload.trim()).jsonObject
    }.getOrElse { error ->
        throw IOException("Link payload must be valid JSON", error)
    }

    val linkIntentId = payload["link_intent_id"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
    if (linkIntentId.isEmpty()) {
        throw IOException("Link payload is missing link_intent_id")
    }

    val linkToken = payload["link_token"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
    if (linkToken.isEmpty()) {
        throw IOException("Link payload is missing link_token")
    }

    val baseUrl = payload["base_url"]?.jsonPrimitive?.contentOrNull
        ?.takeIf { it.isNotBlank() }
        ?.let(::normalizeBackendUrl)
        ?: normalizeBackendUrl(fallbackBaseUrl)

    return ParsedLinkIntentPayload(
        baseUrl = baseUrl,
        linkIntentId = linkIntentId,
        linkToken = linkToken,
    )
}

private fun normalizeBackendUrl(value: String): String {
    val normalized = value.trim().trimEnd('/')
    if (normalized.isEmpty()) {
        throw IOException("Backend URL cannot be empty")
    }
    if (!normalized.startsWith("http://") && !normalized.startsWith("https://")) {
        throw IOException("Backend URL must start with http:// or https://")
    }

    val uri = runCatching { URI(normalized) }.getOrElse { error ->
        throw IOException("Backend URL is invalid", error)
    }
    if (uri.scheme.isNullOrBlank() || uri.host.isNullOrBlank()) {
        throw IOException("Backend URL must include a host")
    }

    return normalized
}
