package chat.trix.android.core.auth

import java.io.IOException
import java.net.URI
import org.json.JSONObject

fun parseLinkIntentPayload(
    rawPayload: String,
    fallbackBaseUrl: String,
): ParsedLinkIntentPayload {
    val payload = runCatching {
        JSONObject(rawPayload.trim())
    }.getOrElse { error ->
        throw IOException("Link payload must be valid JSON", error)
    }

    val linkIntentId = payload.optString("link_intent_id").trim()
    if (linkIntentId.isEmpty()) {
        throw IOException("Link payload is missing link_intent_id")
    }

    val linkToken = payload.optString("link_token").trim()
    if (linkToken.isEmpty()) {
        throw IOException("Link payload is missing link_token")
    }

    val baseUrl = payload.optString("base_url")
        .takeIf { it.isNotBlank() }
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
