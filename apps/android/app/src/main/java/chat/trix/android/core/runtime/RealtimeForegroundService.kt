package chat.trix.android.core.runtime

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import chat.trix.android.BuildConfig
import chat.trix.android.core.auth.AuthBootstrapCoordinator
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.isActionableSessionError
import chat.trix.android.core.auth.storedDeviceIssueNotification
import chat.trix.android.core.notifications.TrixNotificationRouter
import chat.trix.android.core.system.BackendConfigStore
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import androidx.core.content.ContextCompat

class RealtimeForegroundService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var notificationRouter: TrixNotificationRouter
    private var bootJob: Job? = null
    private var realtimeManager: RealtimeSessionManager? = null

    override fun onCreate() {
        super.onCreate()
        notificationRouter = TrixNotificationRouter(applicationContext)
        notificationRouter.ensureChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        promoteToForeground(
            title = "Trix realtime sync",
            body = "Connecting background delivery for this device.",
        )

        if (bootJob?.isActive == true || realtimeManager != null) {
            return START_STICKY
        }

        bootJob = serviceScope.launch {
            establishRealtimeLoop()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        bootJob?.cancel()
        bootJob = null
        runBlocking {
            realtimeManager?.close()
            realtimeManager = null
        }
        serviceScope.cancel()
        super.onDestroy()
    }

    private suspend fun establishRealtimeLoop() {
        while (serviceScope.isActive && realtimeManager == null) {
            when (val outcome = restoreSession()) {
                SessionRestoreOutcome.None -> {
                    stopSelf()
                    return
                }

                is SessionRestoreOutcome.Ready -> {
                    startRealtimeManager(outcome.session)
                    return
                }

                is SessionRestoreOutcome.Fatal -> {
                    notificationRouter.publishDeviceStatusIssue(
                        title = outcome.title,
                        body = outcome.body,
                    )
                    sendSessionEnded(outcome.body)
                    stopSelf()
                    return
                }

                is SessionRestoreOutcome.Retry -> {
                    promoteToForeground(
                        title = "Trix realtime reconnecting",
                        body = outcome.reason,
                    )
                    delay(RESTORE_RETRY_DELAY_MS)
                }
            }
        }
    }

    private suspend fun startRealtimeManager(session: AuthenticatedSession) {
        promoteToForeground(
            title = "Trix realtime connected",
            body = "Background delivery is active for ${session.accountProfile.profileName}.",
        )

        val manager = RealtimeSessionManager(
            context = applicationContext,
            session = session,
            observeProcessLifecycle = false,
            onSessionReplaced = { reason ->
                serviceScope.launch {
                    notificationRouter.publishDeviceStatusIssue(
                        title = "Trix session ended",
                        body = reason,
                    )
                    sendSessionEnded(reason)
                    shutdownService()
                }
            },
            onChatsChanged = { changedChatIds ->
                sendChatsChanged(changedChatIds)
            },
        )
        realtimeManager = manager
        manager.start()
    }

    private suspend fun restoreSession(): SessionRestoreOutcome {
        val backendConfigStore = BackendConfigStore(applicationContext)
        val baseUrl = backendConfigStore.readBaseUrl() ?: BuildConfig.TRIX_BASE_URL
        val authCoordinator = AuthBootstrapCoordinator(applicationContext, baseUrl)
        val storedDevice = authCoordinator.peekStoredDevice() ?: return SessionRestoreOutcome.None

        return try {
            SessionRestoreOutcome.Ready(authCoordinator.restoreSession())
        } catch (error: IOException) {
            if (isActionableSessionError(storedDevice.deviceStatus, error)) {
                val issue = storedDeviceIssueNotification(storedDevice.deviceStatus, error)
                SessionRestoreOutcome.Fatal(
                    title = issue.title,
                    body = issue.body,
                )
            } else {
                SessionRestoreOutcome.Retry(
                    reason = error.message ?: "Waiting to restore the background realtime session.",
                )
            }
        }
    }

    private suspend fun shutdownService() {
        bootJob?.cancel()
        bootJob = null
        realtimeManager?.close()
        realtimeManager = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun promoteToForeground(title: String, body: String) {
        val notification = notificationRouter.buildRealtimeServiceNotification(
            title = title,
            body = body,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun sendChatsChanged(changedChatIds: Set<String>) {
        val intent = Intent(ACTION_CHATS_CHANGED).apply {
            setPackage(packageName)
            putStringArrayListExtra(EXTRA_CHANGED_CHAT_IDS, ArrayList(changedChatIds.sorted()))
            putExtra(EXTRA_FORCE_REFRESH, true)
        }
        sendBroadcast(intent)
    }

    private fun sendSessionEnded(reason: String) {
        val intent = Intent(ACTION_SESSION_ENDED).apply {
            setPackage(packageName)
            putExtra(EXTRA_SESSION_REASON, reason)
        }
        sendBroadcast(intent)
    }

    companion object {
        const val ACTION_CHATS_CHANGED =
            "chat.trix.android.core.runtime.action.REALTIME_CHATS_CHANGED"
        const val ACTION_SESSION_ENDED =
            "chat.trix.android.core.runtime.action.REALTIME_SESSION_ENDED"
        const val EXTRA_CHANGED_CHAT_IDS = "changed_chat_ids"
        const val EXTRA_FORCE_REFRESH = "force_refresh"
        const val EXTRA_SESSION_REASON = "session_reason"

        private const val ACTION_START = "chat.trix.android.core.runtime.action.START"
        private const val NOTIFICATION_ID = 2001
        private const val RESTORE_RETRY_DELAY_MS = 5_000L

        fun start(context: Context) {
            val intent = Intent(context, RealtimeForegroundService::class.java).apply {
                action = ACTION_START
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RealtimeForegroundService::class.java))
        }
    }
}

private sealed interface SessionRestoreOutcome {
    data object None : SessionRestoreOutcome

    data class Ready(val session: AuthenticatedSession) : SessionRestoreOutcome

    data class Retry(val reason: String) : SessionRestoreOutcome

    data class Fatal(
        val title: String,
        val body: String,
    ) : SessionRestoreOutcome
}
