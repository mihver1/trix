package chat.trix.android.core.system

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject

class SystemApiClient(
    baseUrl: String,
) {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')

    suspend fun fetchSnapshot(): SystemSnapshot = withContext(Dispatchers.IO) {
        val health = fetchHealth()
        val version = fetchVersion()
        SystemSnapshot(
            health = health,
            version = version,
            baseUrl = normalizedBaseUrl,
        )
    }

    private fun fetchHealth(): HealthStatus {
        val payload = readJson("/v0/system/health")
        return HealthStatus(
            service = payload.getString("service"),
            status = ServiceStatus.fromWire(payload.getString("status")),
            version = payload.getString("version"),
            uptimeMs = payload.getLong("uptime_ms"),
        )
    }

    private fun fetchVersion(): VersionInfo {
        val payload = readJson("/v0/system/version")
        return VersionInfo(
            service = payload.getString("service"),
            version = payload.getString("version"),
            gitSha = payload.optNullableString("git_sha"),
        )
    }

    private fun readJson(path: String): JSONObject {
        val connection = (URL("$normalizedBaseUrl$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 5_000
            readTimeout = 5_000
            setRequestProperty("Accept", "application/json")
        }

        return try {
            val statusCode = connection.responseCode
            val body = connection.readResponseBody(statusCode)
            if (statusCode !in 200..299) {
                throw IOException(body.ifBlank { "HTTP $statusCode" })
            }
            JSONObject(body)
        } catch (error: JSONException) {
            throw IOException("Malformed JSON from $path", error)
        } finally {
            connection.disconnect()
        }
    }

    private fun HttpURLConnection.readResponseBody(statusCode: Int): String {
        val stream = if (statusCode in 200..299) inputStream else errorStream
        return stream?.bufferedReader()?.use { it.readText().trim() }.orEmpty()
    }

    private fun JSONObject.optNullableString(key: String): String? {
        val value = opt(key)
        return if (value is String && value.isNotBlank()) value else null
    }
}

data class SystemSnapshot(
    val health: HealthStatus,
    val version: VersionInfo,
    val baseUrl: String,
)

data class HealthStatus(
    val service: String,
    val status: ServiceStatus,
    val version: String,
    val uptimeMs: Long,
)

data class VersionInfo(
    val service: String,
    val version: String,
    val gitSha: String?,
)

enum class ServiceStatus {
    Ok,
    Degraded;

    companion object {
        fun fromWire(raw: String): ServiceStatus = when (raw) {
            "ok" -> Ok
            "degraded" -> Degraded
            else -> throw IOException("Unknown service status: $raw")
        }
    }
}
