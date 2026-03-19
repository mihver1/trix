package chat.trix.android.core.auth

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject

class AuthApiClient(
    val baseUrl: String,
) {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')

    suspend fun createAccount(request: CreateAccountPayload): CreateAccountResult = withContext(Dispatchers.IO) {
        val payload = JSONObject().apply {
            put("handle", request.handle)
            put("profile_name", request.profileName)
            put("profile_bio", request.profileBio)
            put("device_display_name", request.deviceDisplayName)
            put("platform", request.platform)
            put("credential_identity_b64", request.credentialIdentityB64)
            put("account_root_pubkey_b64", request.accountRootPubkeyB64)
            put("account_root_signature_b64", request.accountRootSignatureB64)
            put("transport_pubkey_b64", request.transportPubkeyB64)
        }
        val json = requestJson(
            method = "POST",
            path = "/v0/accounts",
            body = payload.toString(),
        )
        CreateAccountResult(
            accountId = json.getString("account_id"),
            deviceId = json.getString("device_id"),
        )
    }

    suspend fun createChallenge(deviceId: String): AuthChallengeResult = withContext(Dispatchers.IO) {
        val json = requestJson(
            method = "POST",
            path = "/v0/auth/challenge",
            body = JSONObject().put("device_id", deviceId).toString(),
        )
        AuthChallengeResult(
            challengeId = json.getString("challenge_id"),
            challengeB64 = json.getString("challenge_b64"),
            expiresAtUnix = json.getLong("expires_at_unix"),
        )
    }

    suspend fun createSession(
        deviceId: String,
        challengeId: String,
        signatureB64: String,
    ): AuthSessionResult = withContext(Dispatchers.IO) {
        val json = requestJson(
            method = "POST",
            path = "/v0/auth/session",
            body = JSONObject().apply {
                put("device_id", deviceId)
                put("challenge_id", challengeId)
                put("signature_b64", signatureB64)
            }.toString(),
        )
        AuthSessionResult(
            accessToken = json.getString("access_token"),
            expiresAtUnix = json.getLong("expires_at_unix"),
            accountId = json.getString("account_id"),
            deviceStatus = json.getString("device_status"),
        )
    }

    suspend fun getCurrentAccount(accessToken: String): AccountProfile = withContext(Dispatchers.IO) {
        val json = requestJson(
            method = "GET",
            path = "/v0/accounts/me",
            accessToken = accessToken,
        )
        AccountProfile(
            accountId = json.getString("account_id"),
            handle = json.optNullableString("handle"),
            profileName = json.getString("profile_name"),
            profileBio = json.optNullableString("profile_bio"),
            deviceId = json.getString("device_id"),
            deviceStatus = json.getString("device_status"),
        )
    }

    private fun requestJson(
        method: String,
        path: String,
        body: String? = null,
        accessToken: String? = null,
    ): JSONObject {
        val connection = (URL("$normalizedBaseUrl$path").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 5_000
            readTimeout = 5_000
            setRequestProperty("Accept", "application/json")
            if (accessToken != null) {
                setRequestProperty("Authorization", "Bearer $accessToken")
            }
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }

        return try {
            if (body != null) {
                connection.outputStream.bufferedWriter().use { writer ->
                    writer.write(body)
                }
            }

            val statusCode = connection.responseCode
            val responseText = connection.readResponseBody(statusCode)
            if (statusCode !in 200..299) {
                throw IOException(parseErrorMessage(responseText, statusCode))
            }
            JSONObject(responseText)
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

    private fun parseErrorMessage(responseText: String, statusCode: Int): String {
        if (responseText.isBlank()) {
            return "HTTP $statusCode"
        }

        return try {
            val json = JSONObject(responseText)
            json.optString("message").ifBlank { "HTTP $statusCode" }
        } catch (_: JSONException) {
            responseText
        }
    }

    companion object {
        private fun JSONObject.optNullableString(key: String): String? {
            val value = opt(key)
            return if (value is String && value.isNotBlank()) value else null
        }
    }
}

data class CreateAccountPayload(
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceDisplayName: String,
    val platform: String,
    val credentialIdentityB64: String,
    val accountRootPubkeyB64: String,
    val accountRootSignatureB64: String,
    val transportPubkeyB64: String,
)

data class CreateAccountResult(
    val accountId: String,
    val deviceId: String,
)

data class AuthChallengeResult(
    val challengeId: String,
    val challengeB64: String,
    val expiresAtUnix: Long,
)

data class AuthSessionResult(
    val accessToken: String,
    val expiresAtUnix: Long,
    val accountId: String,
    val deviceStatus: String,
)

data class AccountProfile(
    val accountId: String,
    val handle: String?,
    val profileName: String,
    val profileBio: String?,
    val deviceId: String,
    val deviceStatus: String,
)
