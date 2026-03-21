package chat.trix.android.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.core.auth.AccountProfile
import chat.trix.android.core.auth.AuthApiClient
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.auth.UpdateAccountProfilePayload
import chat.trix.android.core.system.AppTelemetry
import chat.trix.android.core.system.ServiceStatus
import chat.trix.android.core.system.SystemApiClient
import chat.trix.android.core.system.SystemSnapshot
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import java.io.IOException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val telemetry = remember(context) { AppTelemetry(context) }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(stringResource(R.string.screen_settings)) },
            )
        },
    ) { innerPadding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 260.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                SessionCard(session = session)
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                AccountProfileCard(
                    session = session,
                    onPersistAccountProfile = onPersistAccountProfile,
                )
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                BackendDiagnosticsCard(baseUrl = session.baseUrl)
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                SafeClientLogsCard(telemetry = telemetry)
            }
        }
    }
}

@Composable
private fun SessionCard(session: AuthenticatedSession) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.primaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "Active session",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "${session.accountProfile.profileName} on ${session.localState.deviceDisplayName}",
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = buildString {
                    append("Account ${session.accountProfile.accountId}\n")
                    append("Device ${session.accountProfile.deviceId}")
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}

@Composable
private fun AccountProfileCard(
    session: AuthenticatedSession,
    onPersistAccountProfile: suspend (AccountProfile) -> Unit,
) {
    val authApiClient = remember(session.baseUrl) { AuthApiClient(session.baseUrl) }
    val coroutineScope = rememberCoroutineScope()
    var handleInput by rememberSaveable(session.localState.deviceId) {
        mutableStateOf(session.accountProfile.handle.orEmpty())
    }
    var profileNameInput by rememberSaveable(session.localState.deviceId) {
        mutableStateOf(session.accountProfile.profileName)
    }
    var profileBioInput by rememberSaveable(session.localState.deviceId) {
        mutableStateOf(session.accountProfile.profileBio.orEmpty())
    }
    var isSaving by remember { mutableStateOf(false) }
    var saveErrorMessage by remember { mutableStateOf<String?>(null) }
    var saveNotice by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(
        session.accountProfile.handle,
        session.accountProfile.profileName,
        session.accountProfile.profileBio,
    ) {
        handleInput = session.accountProfile.handle.orEmpty()
        profileNameInput = session.accountProfile.profileName
        profileBioInput = session.accountProfile.profileBio.orEmpty()
    }

    val normalizedHandle = normalizeHandle(handleInput)
    val normalizedProfileName = profileNameInput.trim()
    val normalizedProfileBio = profileBioInput.trim().takeIf(String::isNotEmpty)
    val isDirty = normalizedHandle != session.accountProfile.handle ||
        normalizedProfileName != session.accountProfile.profileName ||
        normalizedProfileBio != session.accountProfile.profileBio
    val canSave = normalizedProfileName.isNotEmpty() && isDirty && !isSaving

    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Account profile",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "This writes directly to the live backend and then refreshes the locally stored device profile.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = handleInput,
                onValueChange = {
                    handleInput = it
                    saveErrorMessage = null
                    saveNotice = null
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !isSaving,
                singleLine = true,
                label = { Text("Handle") },
                placeholder = { Text("alice") },
                prefix = { Text("@") },
            )
            OutlinedTextField(
                value = profileNameInput,
                onValueChange = {
                    profileNameInput = it
                    saveErrorMessage = null
                    saveNotice = null
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !isSaving,
                singleLine = true,
                label = { Text("Profile name") },
                placeholder = { Text("Alice Example") },
            )
            OutlinedTextField(
                value = profileBioInput,
                onValueChange = {
                    profileBioInput = it
                    saveErrorMessage = null
                    saveNotice = null
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !isSaving,
                minLines = 3,
                maxLines = 5,
                label = { Text("Bio") },
                placeholder = { Text("Short status or intro") },
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = if (isDirty) {
                            "Unsaved profile changes"
                        } else {
                            "Profile is in sync with local session state"
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (saveNotice != null) {
                        Text(
                            text = saveNotice!!,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                    if (saveErrorMessage != null) {
                        Text(
                            text = saveErrorMessage!!,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
                Button(
                    onClick = {
                        coroutineScope.launch {
                            isSaving = true
                            saveErrorMessage = null
                            saveNotice = null
                            try {
                                val updatedProfile = authApiClient.updateCurrentAccount(
                                    accessToken = session.accessToken,
                                    request = UpdateAccountProfilePayload(
                                        handle = normalizedHandle,
                                        profileName = normalizedProfileName,
                                        profileBio = normalizedProfileBio,
                                    ),
                                )
                                onPersistAccountProfile(updatedProfile)
                                saveNotice = "Profile updated"
                            } catch (error: IOException) {
                                saveErrorMessage = error.message ?: "Failed to update profile"
                            } finally {
                                isSaving = false
                            }
                        }
                    },
                    enabled = canSave,
                ) {
                    if (isSaving) {
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            modifier = Modifier.padding(vertical = 2.dp),
                        )
                    } else {
                        Text("Save")
                    }
                }
            }
        }
    }
}

@Composable
private fun BackendDiagnosticsCard(baseUrl: String) {
    val apiClient = remember(baseUrl) { SystemApiClient(baseUrl) }
    var refreshTick by rememberSaveable { mutableIntStateOf(0) }
    val probeState by produceState<BackendProbeState>(
        initialValue = BackendProbeState.Loading,
        key1 = apiClient,
        key2 = refreshTick,
    ) {
        value = BackendProbeState.Loading
        value = try {
            BackendProbeState.Ready(apiClient.fetchSnapshot())
        } catch (error: IOException) {
            BackendProbeState.Failed(error.message ?: "Unknown network error")
        }
    }

    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(
                    modifier = Modifier.widthIn(max = 560.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "Backend diagnostics",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "The app is currently bound to $baseUrl. In the emulator that should point at host `trixd` through `10.0.2.2`.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Button(onClick = { refreshTick += 1 }) {
                    Text(text = "Refresh")
                }
            }

            when (val state = probeState) {
                BackendProbeState.Loading -> {
                    ElevatedAssistChip(
                        onClick = {},
                        label = { Text("Checking backend health and version") },
                    )
                }

                is BackendProbeState.Failed -> {
                    Text(
                        text = "Connection failed: ${state.message}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                    Text(
                        text = "If the backend runs on your host machine, keep `trixd` on port 8080 and launch the Android Emulator, not a physical device.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                is BackendProbeState.Ready -> {
                    BackendSnapshotContent(snapshot = state.snapshot)
                }
            }
        }
    }
}

@Composable
private fun SafeClientLogsCard(telemetry: AppTelemetry) {
    var refreshTick by rememberSaveable { mutableIntStateOf(0) }
    val logLines by produceState(
        initialValue = emptyList<String>(),
        key1 = telemetry,
        key2 = refreshTick,
    ) {
        value = telemetry.readRecentLines()
    }

    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(
                    modifier = Modifier.widthIn(max = 560.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "Client logs",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Only safe diagnostics are stored here: lifecycle, sync, memberships, device actions, short IDs, counters, and failures. No decrypted payloads or message plaintext are written.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Text(
                text = telemetry.activeLogPath(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { refreshTick += 1 }) {
                    Text("Reload")
                }
                Button(onClick = {
                    telemetry.clear()
                    refreshTick += 1
                }) {
                    Text("Clear")
                }
            }

            if (logLines.isEmpty()) {
                Text(
                    text = "No safe client logs yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    logLines.asReversed().forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BackendSnapshotContent(snapshot: SystemSnapshot) {
    val statusColor = when (snapshot.health.status) {
        ServiceStatus.Ok -> MaterialTheme.colorScheme.primaryContainer
        ServiceStatus.Degraded -> MaterialTheme.colorScheme.errorContainer
    }
    val onStatusColor = when (snapshot.health.status) {
        ServiceStatus.Ok -> MaterialTheme.colorScheme.onPrimaryContainer
        ServiceStatus.Degraded -> MaterialTheme.colorScheme.onErrorContainer
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ElevatedAssistChip(
            onClick = {},
            label = {
                Text(
                    text = "Status: ${snapshot.health.status.name.lowercase()}",
                    color = onStatusColor,
                )
            },
            colors = AssistChipDefaults.elevatedAssistChipColors(
                containerColor = statusColor,
                labelColor = onStatusColor,
            ),
        )
        Text(
            text = "Service ${snapshot.health.service} is answering. Version ${snapshot.version.version}${snapshot.version.gitSha?.let { " ($it)" }.orEmpty()}",
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            text = "Uptime: ${formatUptime(snapshot.health.uptimeMs)}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = "Base URL: ${snapshot.baseUrl}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SettingsCard(
    title: String,
    body: String,
) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private sealed interface BackendProbeState {
    data object Loading : BackendProbeState

    data class Ready(val snapshot: SystemSnapshot) : BackendProbeState

    data class Failed(val message: String) : BackendProbeState
}

private fun normalizeHandle(value: String): String? {
    return value
        .trim()
        .removePrefix("@")
        .trim()
        .takeIf(String::isNotEmpty)
}

private fun formatUptime(uptimeMs: Long): String {
    val totalSeconds = uptimeMs / 1_000
    val hours = totalSeconds / 3_600
    val minutes = (totalSeconds % 3_600) / 60
    val seconds = totalSeconds % 60
    return buildString {
        if (hours > 0) {
            append(hours)
            append("h ")
        }
        if (hours > 0 || minutes > 0) {
            append(minutes)
            append("m ")
        }
        append(seconds)
        append("s")
    }
}
