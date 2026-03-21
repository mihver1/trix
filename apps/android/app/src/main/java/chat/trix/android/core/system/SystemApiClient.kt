package chat.trix.android.core.system

import chat.trix.android.core.ffi.FfiHealthResponse
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiServiceStatus
import chat.trix.android.core.ffi.FfiVersionResponse
import chat.trix.android.core.ffi.TrixFfiException
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SystemApiClient(
    baseUrl: String,
) {
    private val normalizedBaseUrl = baseUrl.trimEnd('/')

    suspend fun fetchSnapshot(): SystemSnapshot = withContext(Dispatchers.IO) {
        runFfi("Failed to fetch backend diagnostics") {
            FfiServerApiClient(normalizedBaseUrl).use { client ->
                val health = client.getHealth().toHealthStatus()
                val version = client.getVersion().toVersionInfo()
                SystemSnapshot(
                    health = health,
                    version = version,
                    baseUrl = normalizedBaseUrl,
                )
            }
        }
    }

    private inline fun <T> runFfi(
        fallbackMessage: String,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: CancellationException) {
            throw error
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

    private fun FfiHealthResponse.toHealthStatus(): HealthStatus {
        return HealthStatus(
            service = service,
            status = status.toServiceStatus(),
            version = version,
            uptimeMs = uptimeMs.toLong(),
        )
    }

    private fun FfiVersionResponse.toVersionInfo(): VersionInfo {
        return VersionInfo(
            service = service,
            version = version,
            gitSha = gitSha,
        )
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
        fun fromFfi(raw: FfiServiceStatus): ServiceStatus = when (raw) {
            FfiServiceStatus.OK -> Ok
            FfiServiceStatus.DEGRADED -> Degraded
        }
    }
}

private fun FfiServiceStatus.toServiceStatus(): ServiceStatus {
    return ServiceStatus.fromFfi(this)
}
