package chat.trix.android.core.runtime

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import chat.trix.android.BuildConfig
import chat.trix.android.core.auth.AuthBootstrapCoordinator
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.notifications.TrixNotificationRouter
import chat.trix.android.core.system.BackendConfigStore
import java.io.IOException

class SyncWorker(
    appContext: Context,
    workerParameters: WorkerParameters,
) : CoroutineWorker(appContext, workerParameters) {
    override suspend fun doWork(): Result {
        val notificationRouter = TrixNotificationRouter(applicationContext)
        notificationRouter.ensureChannels()

        val backendConfigStore = BackendConfigStore(applicationContext)
        val baseUrl = backendConfigStore.readBaseUrl() ?: BuildConfig.TRIX_BASE_URL
        val authCoordinator = AuthBootstrapCoordinator(applicationContext, baseUrl)
        val storedDevice = authCoordinator.peekStoredDevice() ?: return Result.success()

        val session = try {
            authCoordinator.restoreSession()
        } catch (error: IOException) {
            if (isActionableSessionError(storedDevice.deviceStatus, error)) {
                notificationRouter.publishDeviceStatusIssue(
                    title = "Trix device needs attention",
                    body = error.message ?: "This Android device cannot restore its Trix session right now.",
                )
                return Result.success()
            }
            return Result.retry()
        }

        var repository: ChatRepository? = null
        return try {
            repository = ChatRepository(applicationContext, session)
            val refreshResult = repository.refresh()
            notificationRouter.publishUnreadSummary(session, refreshResult.overview)
            Result.success()
        } catch (_: IOException) {
            Result.retry()
        } finally {
            repository?.close()
        }
    }

    private fun isActionableSessionError(
        storedDeviceStatus: String?,
        error: IOException,
    ): Boolean {
        val message = error.message.orEmpty()
        return storedDeviceStatus == "pending" ||
            message.contains("pending approval", ignoreCase = true) ||
            message.contains("device is not active", ignoreCase = true) ||
            message.contains("revoked", ignoreCase = true)
    }
}
