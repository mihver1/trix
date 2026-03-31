package chat.trix.android.core.runtime

import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.chat.AndroidMessengerClient
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.ffi.FfiMessengerException
import chat.trix.android.core.ffi.FfiRealtimeEventKind
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiServerWebSocketClient
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.notifications.TrixNotificationRouter
import chat.trix.android.core.system.AppTelemetry
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class RealtimeSessionManager(
    context: Context,
    private val session: AuthenticatedSession,
    private val observeProcessLifecycle: Boolean = true,
    private val onSessionReplaced: (String) -> Unit,
    private val onChatsChanged: (Set<String>) -> Unit = {},
) : DefaultLifecycleObserver, AutoCloseable {
    private val appContext = context.applicationContext
    private val telemetry = AppTelemetry(appContext)
    private val notificationRouter = TrixNotificationRouter(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycle = ProcessLifecycleOwner.get().lifecycle
    private var loopJob: kotlinx.coroutines.Job? = null
    private var stopJob: kotlinx.coroutines.Job? = null
    private var websocket: FfiServerWebSocketClient? = null
    private var checkpoint: String? = null

    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl).apply {
            setAccessToken(session.accessToken)
        }
    }
    private val messengerDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidMessengerClient(appContext, session)
    }

    fun start() {
        ensureLoopRunning()
    }

    fun startObserving() {
        if (!observeProcessLifecycle) {
            ensureLoopRunning()
            return
        }
        lifecycle.addObserver(this)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            ensureLoopRunning()
        }
    }

    override fun onStart(owner: LifecycleOwner) {
        stopJob?.cancel()
        stopJob = null
        ensureLoopRunning()
    }

    override fun onStop(owner: LifecycleOwner) {
        stopJob?.cancel()
        stopJob = scope.launch {
            delay(STOP_GRACE_PERIOD_MS)
            shutdownRealtimeLoop()
        }
    }

    suspend fun stop() {
        shutdownRealtimeLoop()
    }

    suspend fun sendPresencePing(nonce: String? = null) = withContext(Dispatchers.IO) {
        ensureWebSocket().sendPresencePing(nonce)
    }

    suspend fun sendTypingUpdate(chatId: String, isTyping: Boolean) = withContext(Dispatchers.IO) {
        messenger().setTyping(chatId, isTyping)
    }

    suspend fun sendHistorySyncProgress(
        jobId: String,
        cursorJson: String? = null,
        completedChunks: ULong? = null,
    ) = withContext(Dispatchers.IO) {
        ensureWebSocket().sendHistorySyncProgress(jobId, cursorJson, completedChunks)
    }

    override fun close() {
        if (observeProcessLifecycle) {
            lifecycle.removeObserver(this)
        }
        runBlocking {
            shutdownRealtimeLoop()
        }
        if (messengerDelegate.isInitialized()) {
            messengerDelegate.value.close()
        }
        if (clientDelegate.isInitialized()) {
            clientDelegate.value.close()
        }
        scope.cancel()
    }

    private fun ensureLoopRunning() {
        if (loopJob?.isActive == true) {
            return
        }
        loopJob = scope.launch {
            telemetry.info(TAG, "starting foreground realtime loop")
            runRealtimeLoop()
        }
    }

    private suspend fun shutdownRealtimeLoop() {
        closeSocketQuietly()
        loopJob?.cancelAndJoin()
        loopJob = null
    }

    private suspend fun runRealtimeLoop() {
        while (scope.isActive) {
            try {
                initializeCheckpoint()
                val batch = messenger().getNewEvents(checkpoint)
                checkpoint = batch.checkpoint

                if (batch.changedChatIds.isNotEmpty() || batch.hasDeviceChanges) {
                    telemetry.info(
                        TAG,
                        "messenger poll changed=${batch.changedChatIds.size} deviceChanges=${batch.hasDeviceChanges}",
                    )
                    publishUnreadSummary()
                }
                if (batch.changedChatIds.isNotEmpty()) {
                    withContext(Dispatchers.Main) {
                        onChatsChanged(batch.changedChatIds)
                    }
                }
                delay(POLL_INTERVAL_MS)
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                telemetry.warn(TAG, "foreground realtime loop failed", error)
                closeSocketQuietly()
                delay(WEBSOCKET_RETRY_DELAY_MS)
            }
        }
        telemetry.info(TAG, "foreground realtime loop stopped")
    }

    private suspend fun initializeCheckpoint() {
        if (checkpoint != null) {
            return
        }
        val snapshot = messenger().loadSnapshot()
        checkpoint = snapshot.checkpoint
        publishUnreadSummary()
    }

    private suspend fun publishUnreadSummary() {
        runCatching {
            val repository = ChatRepository(appContext, session)
            try {
                notificationRouter.publishUnreadSummary(session, repository.loadOverview())
            } finally {
                repository.close()
            }
        }.onFailure { error ->
            telemetry.warn(TAG, "failed to publish realtime unread summary", error)
        }
    }

    private fun ensureWebSocket(): FfiServerWebSocketClient {
        val existing = websocket
        if (existing != null) {
            return existing
        }
        val created = client().connectWebsocket()
        websocket = created
        telemetry.info(TAG, "websocket connected")
        return created
    }

    private fun closeSocketQuietly() {
        websocket?.let { current ->
            runCatching { current.closeSocket() }
        }
        websocket = null
    }

    private fun client(): FfiServerApiClient = clientDelegate.value

    private fun messenger(): AndroidMessengerClient = messengerDelegate.value

    companion object {
        private const val TAG = "TrixRealtime"
        private const val POLL_INTERVAL_MS = 750L
        private const val WEBSOCKET_RETRY_DELAY_MS = 3_000L
        private const val STOP_GRACE_PERIOD_MS = 2_500L
    }
}

private fun Throwable.asIoException(fallbackMessage: String): IOException {
    return when (this) {
        is IOException -> this
        is FfiMessengerException -> IOException(chat.trix.android.core.chat.ffiMessengerMessage(this), this)
        is TrixFfiException -> IOException(message ?: fallbackMessage, this)
        is UnsatisfiedLinkError -> IOException("Rust FFI library is not available in the Android app bundle", this)
        else -> IOException(fallbackMessage, this)
    }
}

internal fun isRecoverableSessionReplacement(reason: String?): Boolean {
    return reason in RECOVERABLE_SESSION_REPLACEMENT_REASONS
}

internal fun shouldDispatchChatRefresh(
    eventKind: FfiRealtimeEventKind,
    changedChatIds: Set<String>,
): Boolean {
    return when (eventKind) {
        FfiRealtimeEventKind.ACKED,
        FfiRealtimeEventKind.INBOX_ITEMS,
        -> changedChatIds.isNotEmpty()
        else -> false
    }
}

private val RECOVERABLE_SESSION_REPLACEMENT_REASONS = setOf(
    "replaced by a newer websocket session",
    "server shutting down",
)
