package chat.trix.android.core.runtime

import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.DeviceDatabaseKeyStore
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.ffi.FfiClientStore
import chat.trix.android.core.ffi.FfiClientStoreConfig
import chat.trix.android.core.ffi.FfiLocalHistoryStore
import chat.trix.android.core.ffi.FfiRealtimeConfig
import chat.trix.android.core.ffi.FfiRealtimeDriver
import chat.trix.android.core.ffi.FfiRealtimeEvent
import chat.trix.android.core.ffi.FfiRealtimeEventKind
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiServerWebSocketClient
import chat.trix.android.core.ffi.FfiSyncCoordinator
import chat.trix.android.core.ffi.TrixFfiException
import chat.trix.android.core.notifications.TrixNotificationRouter
import chat.trix.android.core.system.AppTelemetry
import chat.trix.android.core.system.deviceStorageLayout
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
    private val onSessionReplaced: (String) -> Unit,
) : DefaultLifecycleObserver, AutoCloseable {
    private val appContext = context.applicationContext
    private val storageLayout = deviceStorageLayout(
        context = appContext,
        accountId = session.localState.accountId,
        deviceId = session.localState.deviceId,
    )
    private val telemetry = AppTelemetry(appContext)
    private val notificationRouter = TrixNotificationRouter(appContext)
    private val databaseKeyStore = DeviceDatabaseKeyStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycle = ProcessLifecycleOwner.get().lifecycle
    private var loopJob: kotlinx.coroutines.Job? = null
    private var stopJob: kotlinx.coroutines.Job? = null
    private var websocket: FfiServerWebSocketClient? = null

    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl).apply {
            setAccessToken(session.accessToken)
        }
    }
    private val clientStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        storageLayout.prepareCorePersistenceMigration()
        val databaseKey = runBlocking {
            databaseKeyStore.getOrCreate(storageLayout.storeKeyPath)
        }
        FfiClientStore.open(
            FfiClientStoreConfig(
                databasePath = storageLayout.stateDatabasePath.absolutePath,
                databaseKey = databaseKey,
                attachmentCacheRoot = storageLayout.attachmentCacheRoot.absolutePath,
            ),
        )
    }
    private val historyStoreDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        clientStore().historyStore()
    }
    private val syncCoordinatorDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        clientStore().syncCoordinator()
    }
    private val realtimeDriverDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiRealtimeDriver.withConfig(
            FfiRealtimeConfig(
                inboxLimit = 100u,
                inboxLeaseTtlSeconds = 30uL,
                pollIntervalMs = 750uL,
                websocketRetryDelayMs = WEBSOCKET_RETRY_DELAY_MS.toULong(),
            ),
        )
    }

    fun startObserving() {
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

    override fun close() {
        lifecycle.removeObserver(this)
        runBlocking {
            shutdownRealtimeLoop()
        }
        if (realtimeDriverDelegate.isInitialized()) {
            realtimeDriverDelegate.value.close()
        }
        if (historyStoreDelegate.isInitialized()) {
            historyStoreDelegate.value.close()
        }
        if (syncCoordinatorDelegate.isInitialized()) {
            syncCoordinatorDelegate.value.close()
        }
        if (clientStoreDelegate.isInitialized()) {
            clientStoreDelegate.value.close()
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
        websocket?.let { current ->
            runCatching { current.closeSocket() }
            websocket = null
        }
        loopJob?.cancelAndJoin()
        loopJob = null
    }

    private suspend fun runRealtimeLoop() {
        while (scope.isActive) {
            try {
                val event = withContext(Dispatchers.IO) {
                    val socket = ensureWebSocket()
                    realtimeDriver().nextWebsocketEvent(
                        websocket = socket,
                        coordinator = syncCoordinator(),
                        store = historyStore(),
                        autoAck = true,
                    )
                }

                if (event == null) {
                    telemetry.warn(TAG, "websocket event stream returned null")
                    closeSocketQuietly()
                    delay(WEBSOCKET_RETRY_DELAY_MS)
                    continue
                }

                val shouldContinue = handleEvent(event)
                if (!shouldContinue) {
                    break
                }
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

    private suspend fun handleEvent(event: FfiRealtimeEvent): Boolean {
        when (event.kind) {
            FfiRealtimeEventKind.HELLO -> {
                telemetry.info(TAG, "websocket hello received")
                flushPendingOutbox()
            }

            FfiRealtimeEventKind.INBOX_ITEMS,
            FfiRealtimeEventKind.ACKED,
            -> {
                telemetry.info(
                    TAG,
                    "realtime event=${event.kind.name.lowercase()} changed=${event.report?.changedChatIds?.size ?: 0}",
                )
                flushPendingOutbox()
                publishUnreadSummary()
            }

            FfiRealtimeEventKind.PONG -> {
                telemetry.info(TAG, "websocket pong received")
            }

            FfiRealtimeEventKind.ERROR -> {
                telemetry.warn(
                    TAG,
                    "websocket error ${event.errorCode.orEmpty()} ${event.errorMessage.orEmpty()}".trim(),
                )
            }

            FfiRealtimeEventKind.DISCONNECTED -> {
                telemetry.warn(TAG, "websocket disconnected")
                closeSocketQuietly()
                delay(WEBSOCKET_RETRY_DELAY_MS)
            }

            FfiRealtimeEventKind.SESSION_REPLACED -> {
                val reason = event.sessionReplacedReason ?: "session replaced by another client"
                telemetry.error(TAG, "session replaced: $reason")
                notificationRouter.publishDeviceStatusIssue(
                    title = "Trix session replaced",
                    body = reason,
                )
                withContext(Dispatchers.Main) {
                    onSessionReplaced(reason)
                }
                closeSocketQuietly()
                return false
            }
        }
        return true
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

    private suspend fun flushPendingOutbox() {
        runCatching {
            val repository = ChatRepository(appContext, session)
            try {
                val flushed = repository.flushPendingOutbox()
                if (flushed > 0) {
                    telemetry.info(TAG, "flushed $flushed outbox message(s)")
                }
            } finally {
                repository.close()
            }
        }.onFailure { error ->
            telemetry.warn(TAG, "failed to flush pending outbox", error)
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

    private fun clientStore(): FfiClientStore = clientStoreDelegate.value

    private fun historyStore(): FfiLocalHistoryStore = historyStoreDelegate.value

    private fun syncCoordinator(): FfiSyncCoordinator = syncCoordinatorDelegate.value

    private fun realtimeDriver(): FfiRealtimeDriver = realtimeDriverDelegate.value

    companion object {
        private const val TAG = "TrixRealtime"
        private const val WEBSOCKET_RETRY_DELAY_MS = 3_000L
        private const val STOP_GRACE_PERIOD_MS = 2_500L
    }
}

private fun Throwable.asIoException(fallbackMessage: String): IOException {
    return when (this) {
        is IOException -> this
        is TrixFfiException -> IOException(message ?: fallbackMessage, this)
        is UnsatisfiedLinkError -> IOException("Rust FFI library is not available in the Android app bundle", this)
        else -> IOException(fallbackMessage, this)
    }
}
