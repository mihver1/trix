package chat.trix.android.ui

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
import chat.trix.android.core.auth.LocalAuthStateStore
import chat.trix.android.core.auth.StoredDeviceSummary
import chat.trix.android.core.system.BackendConfigStore
import chat.trix.android.designsystem.theme.TrixTheme
import chat.trix.android.feature.bootstrap.BootstrapScreen
import chat.trix.android.feature.chats.ChatsScreen
import chat.trix.android.feature.devices.DevicesScreen
import chat.trix.android.feature.settings.SettingsScreen
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixNavigationLayout
import chat.trix.android.ui.adaptive.rememberTrixAdaptiveInfo
import chat.trix.android.ui.navigation.TrixDestination
import java.io.IOException
import java.net.URI
import kotlinx.coroutines.launch

@Composable
fun TrixApp() {
    TrixTheme {
        val context = LocalContext.current.applicationContext
        val windowInfo = rememberTrixAdaptiveInfo()
        val backendConfigStore = remember(context) { BackendConfigStore(context) }
        val localAuthStateStore = remember(context) { LocalAuthStateStore(context) }
        var configuredBaseUrl by rememberSaveable {
            mutableStateOf(backendConfigStore.readBaseUrl() ?: BuildConfig.TRIX_BASE_URL)
        }
        val authCoordinator = remember(context, configuredBaseUrl) {
            AuthBootstrapCoordinator(
                context = context,
                baseUrl = configuredBaseUrl,
            )
        }
        val coroutineScope = rememberCoroutineScope()
        var destination by rememberSaveable { mutableStateOf(TrixDestination.Chats) }
        var reloadSignal by rememberSaveable { mutableIntStateOf(0) }
        var authState by remember { mutableStateOf<TrixAuthState>(TrixAuthState.Loading("Restoring local device")) }
        var backendConfigError by remember { mutableStateOf<String?>(null) }

        LaunchedEffect(authCoordinator, reloadSignal) {
            authState = TrixAuthState.Loading("Restoring local device")
            authState = loadInitialAuthState(authCoordinator)
        }

        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            when (val state = authState) {
                is TrixAuthState.Loading -> LoadingScreen(message = state.message)
                is TrixAuthState.SignedOut -> BootstrapScreen(
                    baseUrl = configuredBaseUrl,
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
                    onCreateAccount = { input ->
                        coroutineScope.launch {
                            backendConfigError = null
                            authState = TrixAuthState.Loading("Creating account")
                            authState = createAccountState(authCoordinator, input)
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
                    when (windowInfo.navigationLayout) {
                        TrixNavigationLayout.BottomBar -> BottomBarLayout(
                            destination = destination,
                            onDestinationChange = { destination = it },
                            windowInfo = windowInfo,
                            session = session,
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
            errorMessage = error.message ?: "Session restore failed",
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

@Composable
private fun BottomBarLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
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
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (destination) {
        TrixDestination.Chats -> ChatsScreen(
            windowInfo = windowInfo,
            session = session,
            modifier = modifier,
        )
        TrixDestination.Devices -> DevicesScreen(
            windowInfo = windowInfo,
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
