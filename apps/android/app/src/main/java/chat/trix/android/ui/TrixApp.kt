package chat.trix.android.ui

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.BuildConfig
import chat.trix.android.R
import chat.trix.android.core.auth.AuthBootstrapCoordinator
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.BootstrapInput
import chat.trix.android.core.auth.AccountProfile
import chat.trix.android.core.auth.LinkDeviceInput
import chat.trix.android.core.auth.LinkExistingAccountInput
import chat.trix.android.core.auth.LocalAuthStateStore
import chat.trix.android.core.auth.parseLinkIntentPayload
import chat.trix.android.core.auth.StoredDeviceSummary
import chat.trix.android.core.auth.restoreSessionErrorMessage
import chat.trix.android.core.notifications.TrixNotificationRouter
import chat.trix.android.core.runtime.BackgroundSyncScheduler
import chat.trix.android.core.runtime.RealtimeForegroundService
import chat.trix.android.core.system.BackendConfigStore
import chat.trix.android.core.system.DESTINATION_CHATS
import chat.trix.android.core.system.EXTRA_OPEN_CHAT_ID
import chat.trix.android.core.system.EXTRA_OPEN_DESTINATION
import chat.trix.android.designsystem.theme.TrixTheme
import chat.trix.android.feature.bootstrap.BootstrapScreen
import chat.trix.android.feature.chats.ChatsScreen
import chat.trix.android.feature.devices.DevicesScreen
import chat.trix.android.feature.settings.SettingsScreen
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixNavigationLayout
import chat.trix.android.ui.adaptive.rememberTrixAdaptiveInfo
import chat.trix.android.ui.interop.TrixInteropLaunchCoordinator
import chat.trix.android.ui.navigation.TrixDestination
import java.io.File
import java.io.IOException
import java.net.URI
import org.json.JSONObject
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun TrixApp(
    launchIntent: Intent? = null,
    launchBaseUrlOverride: String? = null,
    interopActionJson: String? = null,
    interopResultFileName: String? = null,
) {
    TrixTheme {
        val context = LocalContext.current.applicationContext
        val windowInfo = rememberTrixAdaptiveInfo()
        val backendConfigStore = remember(context) { BackendConfigStore(context) }
        val localAuthStateStore = remember(context) { LocalAuthStateStore(context) }
        val notificationRouter = remember(context) { TrixNotificationRouter(context) }
        val notificationPermissionLauncher = rememberLauncherForActivityResult(
            contract = ActivityResultContracts.RequestPermission(),
            onResult = {},
        )
        val defaultBaseUrl = launchBaseUrlOverride ?: BuildConfig.TRIX_BASE_URL
        var configuredBaseUrl by rememberSaveable(launchBaseUrlOverride) {
            mutableStateOf(launchBaseUrlOverride ?: backendConfigStore.readBaseUrl() ?: BuildConfig.TRIX_BASE_URL)
        }
        val authCoordinator = remember(context, configuredBaseUrl) {
            AuthBootstrapCoordinator(
                context = context,
                baseUrl = configuredBaseUrl,
            )
        }
        val coroutineScope = rememberCoroutineScope()
        var destination by rememberSaveable { mutableStateOf(TrixDestination.Chats) }
        var requestedConversationId by rememberSaveable { mutableStateOf<String?>(null) }
        var reloadSignal by rememberSaveable { mutableIntStateOf(0) }
        var realtimeChangeSignal by rememberSaveable { mutableIntStateOf(0) }
        var realtimeChangedChatIds by remember { mutableStateOf(emptySet<String>()) }
        var authState by remember { mutableStateOf<TrixAuthState>(TrixAuthState.Loading("Restoring local device")) }
        var backendConfigError by remember { mutableStateOf<String?>(null) }
        var notificationPermissionRequested by rememberSaveable { mutableStateOf(false) }

        val interopStableKey = remember(interopActionJson, interopResultFileName) {
            TrixInteropLaunchCoordinator.stableInteropRequestKey(interopActionJson, interopResultFileName)
        }
        val hasInteropRequest = TrixInteropLaunchCoordinator.hasInteropRequest(interopStableKey)

        var interopBridgeFinished by rememberSaveable(interopStableKey) {
            mutableStateOf(TrixInteropLaunchCoordinator.initialBridgeFinished(hasInteropRequest))
        }

        var interopWriteAttempt by remember(interopStableKey) {
            mutableIntStateOf(0)
        }

        LaunchedEffect(authCoordinator, reloadSignal, interopStableKey, interopBridgeFinished, hasInteropRequest) {
            if (TrixInteropLaunchCoordinator.shouldDeferAuthBootstrap(hasInteropRequest, interopBridgeFinished)) {
                return@LaunchedEffect
            }
            authState = TrixAuthState.Loading("Restoring local device")
            authState = loadInitialAuthState(authCoordinator)
        }

        LaunchedEffect(launchIntent) {
            val requestedDestination = launchIntent?.getStringExtra(EXTRA_OPEN_DESTINATION)
            val requestedChatId = launchIntent?.getStringExtra(EXTRA_OPEN_CHAT_ID)
            if (requestedDestination == DESTINATION_CHATS || !requestedChatId.isNullOrBlank()) {
                destination = TrixDestination.Chats
            }
            if (!requestedChatId.isNullOrBlank()) {
                requestedConversationId = requestedChatId
            }
        }

        LaunchedEffect(
            interopStableKey,
            interopActionJson,
            interopResultFileName,
            configuredBaseUrl,
            interopBridgeFinished,
            interopWriteAttempt,
            hasInteropRequest,
        ) {
            if (!hasInteropRequest) return@LaunchedEffect
            if (interopBridgeFinished) return@LaunchedEffect

            val actionJson = interopActionJson?.trim()?.takeIf(String::isNotEmpty) ?: return@LaunchedEffect
            val resultFileName = interopResultFileName?.trim()?.takeIf(String::isNotEmpty) ?: return@LaunchedEffect

            val outcome = withContext(Dispatchers.IO) {
                invokeAndroidInteropBridge(
                    context = context,
                    actionJson = actionJson,
                    resultFileName = resultFileName,
                    baseUrl = configuredBaseUrl,
                )
            }

            when (outcome) {
                AndroidInteropInvocationOutcome.WroteTerminalResult -> {
                    interopBridgeFinished = true
                    reloadSignal += 1
                }

                is AndroidInteropInvocationOutcome.DidNotWrite -> {
                    if (interopWriteAttempt < MAX_INTEROP_RESULT_WRITE_ATTEMPTS - 1) {
                        interopWriteAttempt += 1
                    } else {
                        withContext(Dispatchers.IO) {
                            writeInteropFailureResultStub(
                                context = context,
                                resultFileName = resultFileName,
                                detail = outcome.reason,
                            )
                        }
                        interopBridgeFinished = true
                        reloadSignal += 1
                    }
                }
            }
        }

        LaunchedEffect(authState) {
            notificationRouter.ensureChannels()
            when (authState) {
                is TrixAuthState.SignedIn -> {
                    BackgroundSyncScheduler.schedule(context)
                    RealtimeForegroundService.start(context)
                    if (
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        !notificationPermissionRequested &&
                        ContextCompat.checkSelfPermission(
                            context,
                            Manifest.permission.POST_NOTIFICATIONS,
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        notificationPermissionRequested = true
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }

                is TrixAuthState.SignedOut -> {
                    BackgroundSyncScheduler.cancel(context)
                    RealtimeForegroundService.stop(context)
                }

                is TrixAuthState.Loading -> Unit
            }
        }

        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            when (val state = authState) {
                is TrixAuthState.Loading -> {
                    val loadingMessage = if (
                        TrixInteropLaunchCoordinator.shouldDeferAuthBootstrap(hasInteropRequest, interopBridgeFinished)
                    ) {
                        TrixInteropLaunchCoordinator.loadingMessageWhileDeferred(
                            hasInteropRequest = hasInteropRequest,
                            bridgeFinished = interopBridgeFinished,
                        )
                    } else {
                        state.message
                    }
                    LoadingScreen(message = loadingMessage)
                }
                is TrixAuthState.SignedOut -> BootstrapScreen(
                    baseUrl = configuredBaseUrl,
                    defaultBaseUrl = defaultBaseUrl,
                    storedDevice = state.storedDevice,
                    busyMessage = null,
                    errorMessage = state.errorMessage,
                    backendErrorMessage = backendConfigError,
                    onUpdateBaseUrl = { candidateBaseUrl ->
                        coroutineScope.launch {
                            try {
                                val normalizedBaseUrl = normalizeBaseUrl(candidateBaseUrl)
                                if (normalizedBaseUrl == configuredBaseUrl) {
                                    return@launch
                                }
                                backendConfigStore.writeBaseUrl(normalizedBaseUrl)
                                backendConfigError = null
                                authState = TrixAuthState.Loading("Switching backend")
                                configuredBaseUrl = normalizedBaseUrl
                            } catch (error: IOException) {
                                backendConfigError = error.message ?: "Failed to update backend URL"
                            }
                        }
                    },
                    onResetBaseUrl = {
                        coroutineScope.launch {
                            backendConfigStore.writeBaseUrl(defaultBaseUrl)
                            backendConfigError = null
                            authState = TrixAuthState.Loading("Switching backend")
                            configuredBaseUrl = defaultBaseUrl
                        }
                    },
                    onCreateAccount = { input ->
                        coroutineScope.launch {
                            backendConfigError = null
                            authState = TrixAuthState.Loading("Creating account")
                            authState = createAccountState(authCoordinator, input)
                        }
                    },
                    onCompleteLinkIntent = { input ->
                        coroutineScope.launch {
                            backendConfigError = null
                            authState = TrixAuthState.Loading("Linking device")
                            val outcome = completeLinkState(
                                context = context,
                                fallbackBaseUrl = configuredBaseUrl,
                                backendConfigStore = backendConfigStore,
                                input = input,
                            )
                            if (outcome.configuredBaseUrl != null) {
                                configuredBaseUrl = outcome.configuredBaseUrl
                            }
                            authState = outcome.authState
                        }
                    },
                    onReconnectStoredDevice = if (state.storedDevice != null) {
                        {
                            coroutineScope.launch {
                                backendConfigError = null
                                authState = TrixAuthState.Loading("Restoring device session")
                                authState = restoreSessionState(authCoordinator, state.storedDevice)
                            }
                        }
                    } else {
                        null
                    },
                    onForgetStoredDevice = if (state.storedDevice != null) {
                        {
                            coroutineScope.launch {
                                backendConfigError = null
                                authCoordinator.clearStoredDevice()
                                reloadSignal += 1
                            }
                        }
                    } else {
                        null
                    },
                )
                is TrixAuthState.SignedIn -> {
                    val session = state.session
                    DisposableEffect(
                        context,
                        session.localState.deviceId,
                    ) {
                        val receiver = object : BroadcastReceiver() {
                            override fun onReceive(
                                receiverContext: Context?,
                                intent: Intent?,
                            ) {
                                when (intent?.action) {
                                    RealtimeForegroundService.ACTION_CHATS_CHANGED -> {
                                        realtimeChangedChatIds = intent
                                            .getStringArrayListExtra(
                                                RealtimeForegroundService.EXTRA_CHANGED_CHAT_IDS,
                                            )
                                            .orEmpty()
                                            .toSet()
                                        realtimeChangeSignal += 1
                                    }

                                    RealtimeForegroundService.ACTION_SESSION_ENDED -> {
                                        val reason = intent.getStringExtra(
                                            RealtimeForegroundService.EXTRA_SESSION_REASON,
                                        ) ?: "Realtime session ended"
                                        coroutineScope.launch {
                                            authState = TrixAuthState.SignedOut(
                                                storedDevice = session.localState.toSummary(),
                                                errorMessage = "Realtime session ended: $reason",
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        val filter = IntentFilter().apply {
                            addAction(RealtimeForegroundService.ACTION_CHATS_CHANGED)
                            addAction(RealtimeForegroundService.ACTION_SESSION_ENDED)
                        }
                        ContextCompat.registerReceiver(
                            context,
                            receiver,
                            filter,
                            ContextCompat.RECEIVER_NOT_EXPORTED,
                        )
                        onDispose {
                            context.unregisterReceiver(receiver)
                        }
                    }
                    when (windowInfo.navigationLayout) {
                        TrixNavigationLayout.BottomBar -> BottomBarLayout(
                            destination = destination,
                            onDestinationChange = { destination = it },
                            windowInfo = windowInfo,
                            session = session,
                            realtimeChangeSignal = realtimeChangeSignal,
                            realtimeChangedChatIds = realtimeChangedChatIds,
                            requestedConversationId = requestedConversationId,
                            onConversationRequestConsumed = { consumedChatId ->
                                if (requestedConversationId == consumedChatId) {
                                    requestedConversationId = null
                                }
                            },
                            onPersistAccountProfile = { updatedProfile ->
                                val updatedLocalState = session.localState.copy(
                                    handle = updatedProfile.handle,
                                    profileName = updatedProfile.profileName,
                                    profileBio = updatedProfile.profileBio,
                                )
                                localAuthStateStore.write(updatedLocalState)
                                authState = TrixAuthState.SignedIn(
                                    session.copy(
                                        localState = updatedLocalState,
                                        accountProfile = updatedProfile,
                                    ),
                                )
                            },
                        )
                        TrixNavigationLayout.NavigationRail -> RailLayout(
                            destination = destination,
                            onDestinationChange = { destination = it },
                            windowInfo = windowInfo,
                            session = session,
                            realtimeChangeSignal = realtimeChangeSignal,
                            realtimeChangedChatIds = realtimeChangedChatIds,
                            requestedConversationId = requestedConversationId,
                            onConversationRequestConsumed = { consumedChatId ->
                                if (requestedConversationId == consumedChatId) {
                                    requestedConversationId = null
                                }
                            },
                            onPersistAccountProfile = { updatedProfile ->
                                val updatedLocalState = session.localState.copy(
                                    handle = updatedProfile.handle,
                                    profileName = updatedProfile.profileName,
                                    profileBio = updatedProfile.profileBio,
                                )
                                localAuthStateStore.write(updatedLocalState)
                                authState = TrixAuthState.SignedIn(
                                    session.copy(
                                        localState = updatedLocalState,
                                        accountProfile = updatedProfile,
                                    ),
                                )
                            },
                        )
                        TrixNavigationLayout.PermanentDrawer -> DrawerLayout(
                            destination = destination,
                            onDestinationChange = { destination = it },
                            windowInfo = windowInfo,
                            session = session,
                            realtimeChangeSignal = realtimeChangeSignal,
                            realtimeChangedChatIds = realtimeChangedChatIds,
                            requestedConversationId = requestedConversationId,
                            onConversationRequestConsumed = { consumedChatId ->
                                if (requestedConversationId == consumedChatId) {
                                    requestedConversationId = null
                                }
                            },
                            onPersistAccountProfile = { updatedProfile ->
                                val updatedLocalState = session.localState.copy(
                                    handle = updatedProfile.handle,
                                    profileName = updatedProfile.profileName,
                                    profileBio = updatedProfile.profileBio,
                                )
                                localAuthStateStore.write(updatedLocalState)
                                authState = TrixAuthState.SignedIn(
                                    session.copy(
                                        localState = updatedLocalState,
                                        accountProfile = updatedProfile,
                                    ),
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

private suspend fun createAccountState(
    authCoordinator: AuthBootstrapCoordinator,
    input: BootstrapInput,
): TrixAuthState {
    return try {
        TrixAuthState.SignedIn(authCoordinator.createAccount(input))
    } catch (error: IOException) {
        TrixAuthState.SignedOut(
            storedDevice = safePeekStoredDevice(authCoordinator),
            errorMessage = error.message ?: "Account bootstrap failed",
        )
    }
}

private suspend fun restoreSessionState(
    authCoordinator: AuthBootstrapCoordinator,
    storedDevice: StoredDeviceSummary,
): TrixAuthState {
    return try {
        TrixAuthState.SignedIn(authCoordinator.restoreSession())
    } catch (error: IOException) {
        TrixAuthState.SignedOut(
            storedDevice = storedDevice,
            errorMessage = restoreSessionErrorMessage(storedDevice, error),
        )
    }
}

private suspend fun completeLinkState(
    context: Context,
    fallbackBaseUrl: String,
    backendConfigStore: BackendConfigStore,
    input: LinkExistingAccountInput,
): LinkCompletionOutcome {
    return try {
        val parsedPayload = parseLinkIntentPayload(
            rawPayload = input.rawPayload,
            fallbackBaseUrl = fallbackBaseUrl,
        )
        val authCoordinator = AuthBootstrapCoordinator(
            context = context,
            baseUrl = parsedPayload.baseUrl,
        )
        val storedDevice = authCoordinator.completeLinkDevice(
            LinkDeviceInput(
                linkIntent = parsedPayload,
                deviceDisplayName = input.deviceDisplayName,
            ),
        )
        backendConfigStore.writeBaseUrl(parsedPayload.baseUrl)
        LinkCompletionOutcome(
            authState = TrixAuthState.SignedOut(
                storedDevice = storedDevice,
                errorMessage = null,
            ),
            configuredBaseUrl = parsedPayload.baseUrl,
        )
    } catch (error: IOException) {
        LinkCompletionOutcome(
            authState = TrixAuthState.SignedOut(
                storedDevice = null,
                errorMessage = error.message ?: "Device link failed",
            ),
            configuredBaseUrl = null,
        )
    }
}

private suspend fun loadInitialAuthState(
    authCoordinator: AuthBootstrapCoordinator,
): TrixAuthState {
    val storedDevice = safePeekStoredDevice(authCoordinator)
    if (storedDevice == null) {
        return TrixAuthState.SignedOut(
            storedDevice = null,
            errorMessage = null,
        )
    }

    return restoreSessionState(authCoordinator, storedDevice)
}

private suspend fun safePeekStoredDevice(
    authCoordinator: AuthBootstrapCoordinator,
): StoredDeviceSummary? {
    return try {
        authCoordinator.peekStoredDevice()
    } catch (_: IOException) {
        null
    }
}

private fun normalizeBaseUrl(value: String): String {
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

private const val MAX_INTEROP_RESULT_WRITE_ATTEMPTS = 3

private sealed class AndroidInteropInvocationOutcome {
    object WroteTerminalResult : AndroidInteropInvocationOutcome()

    data class DidNotWrite(
        val reason: String,
    ) : AndroidInteropInvocationOutcome()
}

private fun invokeAndroidInteropBridge(
    context: Context,
    actionJson: String,
    resultFileName: String,
    baseUrl: String,
): AndroidInteropInvocationOutcome {
    return runCatching {
        val bridgeClass = Class.forName("chat.trix.android.interop.AndroidInteropActionBridge")
        val performMethod = bridgeClass.getMethod(
            "perform",
            Context::class.java,
            String::class.java,
            String::class.java,
            String::class.java,
        )
        when (
            val raw = performMethod.invoke(
                null,
                context,
                actionJson,
                resultFileName,
                baseUrl,
            )
        ) {
            is Boolean ->
                if (raw) {
                    AndroidInteropInvocationOutcome.WroteTerminalResult
                } else {
                    AndroidInteropInvocationOutcome.DidNotWrite(
                        "Android interop bridge did not write a result file.",
                    )
                }

            else -> AndroidInteropInvocationOutcome.DidNotWrite(
                "Unexpected Android interop bridge return type: ${raw?.javaClass?.name}",
            )
        }
    }.getOrElse { error ->
        Log.e("TrixApp", "Android interop bridge invocation failed", error)
        AndroidInteropInvocationOutcome.DidNotWrite(
            error.message ?: "Android interop bridge invocation failed.",
        )
    }
}

private fun writeInteropFailureResultStub(
    context: Context,
    resultFileName: String,
    detail: String,
) {
    runCatching {
        val dir = File(context.filesDir, "interop").apply { mkdirs() }
        val file = File(dir, File(resultFileName).name)
        val json = JSONObject().apply {
            put("status", "failed")
            put("detail", detail)
        }
        file.writeText(json.toString())
    }
}

@Composable
private fun LoadingScreen(message: String) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CircularProgressIndicator()
            Text(
                text = message,
                style = MaterialTheme.typography.titleMedium,
            )
        }
    }
}

private sealed interface TrixAuthState {
    data class Loading(val message: String) : TrixAuthState

    data class SignedOut(
        val storedDevice: StoredDeviceSummary?,
        val errorMessage: String?,
    ) : TrixAuthState

    data class SignedIn(val session: AuthenticatedSession) : TrixAuthState
}

private data class LinkCompletionOutcome(
    val authState: TrixAuthState,
    val configuredBaseUrl: String?,
)

@Composable
private fun BottomBarLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    realtimeChangeSignal: Int,
    realtimeChangedChatIds: Set<String>,
    requestedConversationId: String?,
    onConversationRequestConsumed: (String) -> Unit,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
) {
    androidx.compose.material3.Scaffold(
        modifier = Modifier.fillMaxSize(),
        bottomBar = {
            NavigationBar {
                TrixDestination.entries.forEach { item ->
                    NavigationBarItem(
                        selected = item == destination,
                        onClick = { onDestinationChange(item) },
                        icon = {
                            androidx.compose.material3.Icon(
                                imageVector = item.icon,
                                contentDescription = null,
                            )
                        },
                        label = { Text(stringResource(item.titleRes)) },
                    )
                }
            }
        },
    ) { innerPadding ->
        DestinationContent(
            destination = destination,
            windowInfo = windowInfo,
            session = session,
            realtimeChangeSignal = realtimeChangeSignal,
            realtimeChangedChatIds = realtimeChangedChatIds,
            requestedConversationId = requestedConversationId,
            onConversationRequestConsumed = onConversationRequestConsumed,
            onPersistAccountProfile = onPersistAccountProfile,
            modifier = Modifier.padding(innerPadding),
        )
    }
}

@Composable
private fun RailLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    realtimeChangeSignal: Int,
    realtimeChangedChatIds: Set<String>,
    requestedConversationId: String?,
    onConversationRequestConsumed: (String) -> Unit,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxSize()
            .safeDrawingPadding(),
    ) {
        NavigationRail {
            Spacer(Modifier.height(12.dp))
            TrixDestination.entries.forEach { item ->
                NavigationRailItem(
                    selected = item == destination,
                    onClick = { onDestinationChange(item) },
                    icon = {
                        androidx.compose.material3.Icon(
                            imageVector = item.icon,
                            contentDescription = null,
                        )
                    },
                    label = { Text(stringResource(item.titleRes)) },
                )
            }
        }
        VerticalDivider()
        DestinationContent(
            destination = destination,
            windowInfo = windowInfo,
            session = session,
            realtimeChangeSignal = realtimeChangeSignal,
            realtimeChangedChatIds = realtimeChangedChatIds,
            requestedConversationId = requestedConversationId,
            onConversationRequestConsumed = onConversationRequestConsumed,
            onPersistAccountProfile = onPersistAccountProfile,
            modifier = Modifier
                .weight(1f)
                .fillMaxSize(),
        )
    }
}

@Composable
private fun DrawerLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    realtimeChangeSignal: Int,
    realtimeChangedChatIds: Set<String>,
    requestedConversationId: String?,
    onConversationRequestConsumed: (String) -> Unit,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
) {
    PermanentNavigationDrawer(
        drawerContent = {
            PermanentDrawerSheet(
                modifier = Modifier
                    .width(280.dp)
                    .safeDrawingPadding(),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = stringResource(R.string.app_name),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "${session.accountProfile.profileName} on ${session.localState.deviceDisplayName}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TrixDestination.entries.forEach { item ->
                    NavigationDrawerItem(
                        selected = item == destination,
                        onClick = { onDestinationChange(item) },
                        icon = {
                            androidx.compose.material3.Icon(
                                imageVector = item.icon,
                                contentDescription = null,
                            )
                        },
                        label = { Text(stringResource(item.titleRes)) },
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                    )
                }
            }
        },
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .safeDrawingPadding(),
        ) {
            DestinationContent(
                destination = destination,
                windowInfo = windowInfo,
                session = session,
                realtimeChangeSignal = realtimeChangeSignal,
                realtimeChangedChatIds = realtimeChangedChatIds,
                requestedConversationId = requestedConversationId,
                onConversationRequestConsumed = onConversationRequestConsumed,
                onPersistAccountProfile = onPersistAccountProfile,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun DestinationContent(
    destination: TrixDestination,
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    realtimeChangeSignal: Int,
    realtimeChangedChatIds: Set<String>,
    requestedConversationId: String?,
    onConversationRequestConsumed: (String) -> Unit,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (destination) {
        TrixDestination.Chats -> ChatsScreen(
            windowInfo = windowInfo,
            session = session,
            realtimeChangeSignal = realtimeChangeSignal,
            realtimeChangedChatIds = realtimeChangedChatIds,
            requestedConversationId = requestedConversationId,
            onConversationRequestConsumed = onConversationRequestConsumed,
            modifier = modifier,
        )
        TrixDestination.Devices -> DevicesScreen(
            windowInfo = windowInfo,
            session = session,
            modifier = modifier,
        )
        TrixDestination.Settings -> SettingsScreen(
            windowInfo = windowInfo,
            session = session,
            onPersistAccountProfile = onPersistAccountProfile,
            modifier = modifier,
        )
    }
}
