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
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.system.ServiceStatus
import chat.trix.android.core.system.SystemApiClient
import chat.trix.android.core.system.SystemSnapshot
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import java.io.IOException

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    modifier: Modifier = Modifier,
) {
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
                BackendDiagnosticsCard(baseUrl = session.baseUrl)
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                SettingsCard(
                    title = "Android direction",
                    body = "Kotlin + Compose first, canonical adaptive layouts, fold-aware posture handling, and no shared FFI until trix-core becomes meaningful on the client side.",
                )
            }
            item {
                SettingsCard(
                    title = "Current window",
                    body = "Width ${windowInfo.widthClass.name.lowercase()}, height ${windowInfo.heightClass.name.lowercase()}, nav ${windowInfo.navigationLayout.name.lowercase()}, posture ${windowInfo.foldPosture.name.lowercase()}.",
                )
            }
            item {
                SettingsCard(
                    title = "Security posture",
                    body = "Bootstrap state is encrypted at rest with Android Keystore-backed AES-GCM. Ed25519 bootstrap material stays local to the device.",
                )
            }
            item {
                SettingsCard(
                    title = "Backend wiring",
                    body = "The Android client now runs through create account, auth challenge, auth session, and accounts/me against the live backend.",
                )
            }
            item {
                SettingsCard(
                    title = "Universal UX",
                    body = "Compact windows use a focused single-pane flow. Medium windows add rail navigation and can switch to list-detail. Expanded windows pin navigation and keep more context visible.",
                )
            }
            item {
                SettingsCard(
                    title = "Next build-out",
                    body = "Move MLS persistence and device linking onto the new Rust surface, then layer thread caching and inbox-driven sync on top.",
                )
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
                text = "Account ${session.accountProfile.accountId}\nDevice ${session.accountProfile.deviceId}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
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
                        label = { Text("Checking /v0/system/*") },
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
