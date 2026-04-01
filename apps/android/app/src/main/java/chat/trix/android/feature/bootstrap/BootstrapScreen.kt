package chat.trix.android.feature.bootstrap

import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedAssistChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.core.auth.BootstrapInput
import chat.trix.android.core.auth.LinkExistingAccountInput
import chat.trix.android.core.auth.StoredDeviceStatus
import chat.trix.android.core.auth.StoredDeviceSummary
import chat.trix.android.core.auth.parseLinkIntentPayload
import chat.trix.android.core.auth.parseStoredDeviceStatus
import chat.trix.android.core.auth.storedDevicePresentation
import chat.trix.android.core.system.ServiceStatus
import chat.trix.android.core.system.SystemApiClient
import chat.trix.android.core.system.SystemSnapshot
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import java.io.IOException
import kotlinx.coroutines.launch

@Composable
fun BootstrapScreen(
    baseUrl: String,
    defaultBaseUrl: String,
    storedDevice: StoredDeviceSummary?,
    busyMessage: String?,
    errorMessage: String?,
    backendErrorMessage: String?,
    onCreateAccount: (String, BootstrapInput) -> Unit,
    onCompleteLinkIntent: (String, LinkExistingAccountInput) -> Unit,
    onReconnectStoredDevice: ((String) -> Unit)?,
    onForgetStoredDevice: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val coroutineScope = rememberCoroutineScope()

    var mode by rememberSaveable { mutableStateOf(BootstrapMode.Create) }
    var profileName by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var deviceDisplayName by rememberSaveable { mutableStateOf(defaultDeviceName()) }
    var linkPayload by rememberSaveable { mutableStateOf("") }
    var linkDeviceDisplayName by rememberSaveable { mutableStateOf(defaultDeviceName()) }
    var editableBaseUrl by rememberSaveable(baseUrl) { mutableStateOf(baseUrl) }
    var linkImportStatusMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var linkImportHasError by rememberSaveable { mutableStateOf(false) }
    var serverProbeState by remember { mutableStateOf<BootstrapBackendProbeState>(BootstrapBackendProbeState.Idle) }

    val isBusy = busyMessage != null
    val parsedLinkBaseUrl = remember(linkPayload, editableBaseUrl) {
        runCatching {
            parseLinkIntentPayload(
                rawPayload = linkPayload,
                fallbackBaseUrl = editableBaseUrl,
            ).baseUrl
        }.getOrNull()
    }
    val effectiveBaseUrl = if (mode == BootstrapMode.Link && parsedLinkBaseUrl != null) {
        parsedLinkBaseUrl
    } else {
        editableBaseUrl
    }
    val qrScanner = remember(context) {
        GmsBarcodeScanning.getClient(
            context,
            GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build(),
        )
    }

    fun clearServerProbe() {
        serverProbeState = BootstrapBackendProbeState.Idle
    }

    fun importLinkPayload(rawValue: String, sourceLabel: String) {
        val normalizedPayload = rawValue.trim()
        if (normalizedPayload.isBlank()) {
            linkImportStatusMessage = "$sourceLabel did not provide a link payload."
            linkImportHasError = true
            clearServerProbe()
            return
        }

        linkPayload = normalizedPayload
        linkImportStatusMessage = "Link code imported from $sourceLabel."
        linkImportHasError = false
        clearServerProbe()
    }

    fun importLinkPayloadFromClipboard() {
        val clipboardPayload = clipboard.getText()?.text.orEmpty()
        importLinkPayload(clipboardPayload, "clipboard")
    }

    fun startQrScan() {
        if (isBusy) {
            return
        }

        linkImportStatusMessage = null
        qrScanner.startScan()
            .addOnSuccessListener { barcode ->
                importLinkPayload(barcode.rawValue.orEmpty(), "QR scan")
            }
            .addOnFailureListener { error ->
                if (error is ApiException && error.statusCode == CommonStatusCodes.CANCELED) {
                    return@addOnFailureListener
                }
                linkImportStatusMessage = error.message ?: "QR scan failed"
                linkImportHasError = true
            }
    }

    fun checkServer() {
        if (isBusy) {
            return
        }

        coroutineScope.launch {
            serverProbeState = BootstrapBackendProbeState.Loading
            serverProbeState = try {
                val normalizedBaseUrl = normalizeBaseUrl(effectiveBaseUrl)
                BootstrapBackendProbeState.Ready(
                    SystemApiClient(normalizedBaseUrl).fetchSnapshot(),
                )
            } catch (error: IOException) {
                BootstrapBackendProbeState.Failed(
                    error.message ?: "Failed to check backend",
                )
            }
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .imePadding(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 24.dp)
                .widthIn(max = 720.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(32.dp),
                color = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(22.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        text = "Set up Trix",
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Choose a server, then create a user or link this device.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                }
            }

            BackendServerCard(
                editableBaseUrl = editableBaseUrl,
                defaultBaseUrl = defaultBaseUrl,
                effectiveBaseUrl = effectiveBaseUrl,
                linkOverrideBaseUrl = if (mode == BootstrapMode.Link) parsedLinkBaseUrl else null,
                probeState = serverProbeState,
                backendErrorMessage = backendErrorMessage,
                isBusy = isBusy,
                onEditableBaseUrlChange = {
                    editableBaseUrl = it
                    clearServerProbe()
                },
                onResetBaseUrl = {
                    editableBaseUrl = defaultBaseUrl
                    clearServerProbe()
                },
                onCheckServer = ::checkServer,
            )

            if (storedDevice != null) {
                StoredDeviceCard(
                    storedDevice = storedDevice,
                    isBusy = isBusy,
                    busyMessage = busyMessage,
                    errorMessage = errorMessage,
                    onReconnectStoredDevice = if (onReconnectStoredDevice != null) {
                        { onReconnectStoredDevice.invoke(editableBaseUrl) }
                    } else {
                        null
                    },
                    onForgetStoredDevice = onForgetStoredDevice,
                )
            } else {
                ModePicker(
                    mode = mode,
                    onModeSelected = {
                        mode = it
                        clearServerProbe()
                    },
                )

                when (mode) {
                    BootstrapMode.Create -> {
                        CreateAccountCard(
                            profileName = profileName,
                            onProfileNameChange = { profileName = it },
                            handle = handle,
                            onHandleChange = { handle = it },
                            deviceDisplayName = deviceDisplayName,
                            onDeviceDisplayNameChange = { deviceDisplayName = it },
                            isBusy = isBusy,
                            busyMessage = busyMessage,
                            onCreateAccount = {
                                onCreateAccount(
                                    editableBaseUrl,
                                    BootstrapInput(
                                        profileName = profileName,
                                        handle = handle,
                                        profileBio = "",
                                        deviceDisplayName = deviceDisplayName,
                                    ),
                                )
                            },
                        )
                    }

                    BootstrapMode.Link -> {
                        LinkExistingAccountCard(
                            linkPayload = linkPayload,
                            onLinkPayloadChange = {
                                linkPayload = it
                                linkImportStatusMessage = null
                                linkImportHasError = false
                                clearServerProbe()
                            },
                            deviceDisplayName = linkDeviceDisplayName,
                            onDeviceDisplayNameChange = { linkDeviceDisplayName = it },
                            isBusy = isBusy,
                            busyMessage = busyMessage,
                            importStatusMessage = linkImportStatusMessage,
                            importStatusIsError = linkImportHasError,
                            onScanQr = ::startQrScan,
                            onPasteFromClipboard = ::importLinkPayloadFromClipboard,
                            onCompleteLinkIntent = {
                                onCompleteLinkIntent(
                                    editableBaseUrl,
                                    LinkExistingAccountInput(
                                        rawPayload = linkPayload,
                                        deviceDisplayName = linkDeviceDisplayName,
                                    ),
                                )
                            },
                        )
                    }
                }

                if (!errorMessage.isNullOrBlank()) {
                    Surface(
                        shape = RoundedCornerShape(24.dp),
                        color = MaterialTheme.colorScheme.errorContainer,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = errorMessage,
                            modifier = Modifier.padding(horizontal = 18.dp, vertical = 14.dp),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                        )
                    }
                }
            }
        }
    }
}

private enum class BootstrapMode {
    Create,
    Link,
}

@Composable
private fun ModePicker(
    mode: BootstrapMode,
    onModeSelected: (BootstrapMode) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ModeButton(
            label = "Create user",
            selected = mode == BootstrapMode.Create,
            onClick = { onModeSelected(BootstrapMode.Create) },
            modifier = Modifier.weight(1f),
        )
        ModeButton(
            label = "Link device",
            selected = mode == BootstrapMode.Link,
            onClick = { onModeSelected(BootstrapMode.Link) },
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun ModeButton(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (selected) {
        Button(
            onClick = onClick,
            modifier = modifier,
        ) {
            Text(label)
        }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = modifier,
        ) {
            Text(label)
        }
    }
}

@Composable
private fun BackendServerCard(
    editableBaseUrl: String,
    defaultBaseUrl: String,
    effectiveBaseUrl: String,
    linkOverrideBaseUrl: String?,
    probeState: BootstrapBackendProbeState,
    backendErrorMessage: String?,
    isBusy: Boolean,
    onEditableBaseUrlChange: (String) -> Unit,
    onResetBaseUrl: () -> Unit,
    onCheckServer: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Server",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )

            Text(
                text = "Current target: ${describeBaseUrl(effectiveBaseUrl)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            if (linkOverrideBaseUrl != null) {
                Text(
                    text = "The link code overrides the server URL: ${describeBaseUrl(linkOverrideBaseUrl)}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            OutlinedTextField(
                value = editableBaseUrl,
                onValueChange = onEditableBaseUrlChange,
                label = { Text("Server URL") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:base-url-field"),
                singleLine = true,
                enabled = !isBusy,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(
                    onClick = onResetBaseUrl,
                    enabled = !isBusy && editableBaseUrl.trim().trimEnd('/') != defaultBaseUrl.trim().trimEnd('/'),
                ) {
                    Text("Reset")
                }
                Button(
                    onClick = onCheckServer,
                    enabled = !isBusy,
                    modifier = Modifier.testTag("bootstrap:check-server-button"),
                ) {
                    Text("Check server")
                }
            }

            when (probeState) {
                BootstrapBackendProbeState.Idle -> Unit
                BootstrapBackendProbeState.Loading -> {
                    ElevatedAssistChip(
                        onClick = {},
                        label = { Text("Checking backend") },
                    )
                }

                is BootstrapBackendProbeState.Failed -> {
                    Text(
                        text = probeState.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }

                is BootstrapBackendProbeState.Ready -> {
                    BackendSnapshotSummary(snapshot = probeState.snapshot)
                }
            }

            if (!backendErrorMessage.isNullOrBlank()) {
                Text(
                    text = backendErrorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

private fun describeBaseUrl(value: String): String {
    val normalized = value.trim().trimEnd('/')
    val withoutScheme = normalized.substringAfter("://", missingDelimiterValue = normalized)
    val scheme = normalized.substringBefore("://", missingDelimiterValue = "http")
    return "$scheme://$withoutScheme"
}

@Composable
private fun BackendSnapshotSummary(snapshot: SystemSnapshot) {
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
                    text = when (snapshot.health.status) {
                        ServiceStatus.Ok -> "Connected"
                        ServiceStatus.Degraded -> "Degraded"
                    },
                    color = onStatusColor,
                )
            },
            colors = AssistChipDefaults.elevatedAssistChipColors(
                containerColor = statusColor,
                labelColor = onStatusColor,
            ),
        )
        Text(
            text = "Service ${snapshot.health.service} responded. Version ${snapshot.version.version}${snapshot.version.gitSha?.let { " ($it)" }.orEmpty()}",
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            text = "Base URL: ${snapshot.baseUrl}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun StoredDeviceCard(
    storedDevice: StoredDeviceSummary,
    isBusy: Boolean,
    busyMessage: String?,
    errorMessage: String?,
    onReconnectStoredDevice: (() -> Unit)?,
    onForgetStoredDevice: (() -> Unit)?,
) {
    val devicePresentation = storedDevicePresentation(storedDevice)
    val storedDeviceStatus = parseStoredDeviceStatus(storedDevice.deviceStatus)
    val cardColor = when (storedDeviceStatus) {
        StoredDeviceStatus.Pending -> MaterialTheme.colorScheme.tertiaryContainer
        StoredDeviceStatus.Revoked -> MaterialTheme.colorScheme.errorContainer
        StoredDeviceStatus.Active,
        StoredDeviceStatus.Unknown,
        -> MaterialTheme.colorScheme.surfaceContainerHigh
    }

    Surface(
        shape = RoundedCornerShape(28.dp),
        color = cardColor,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = devicePresentation.title,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "${storedDevice.profileName} on ${storedDevice.deviceDisplayName}",
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = "Account ${storedDevice.accountId}\nDevice ${storedDevice.deviceId}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            storedDevice.deviceStatus?.let { deviceStatus ->
                ElevatedAssistChip(
                    onClick = {},
                    label = { Text("Status ${deviceStatus.labelForBootstrap()}") },
                )
            }
            Text(
                text = devicePresentation.body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!errorMessage.isNullOrBlank()) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (devicePresentation.primaryActionLabel != null) {
                    Button(
                        onClick = { onReconnectStoredDevice?.invoke() },
                        enabled = !isBusy && onReconnectStoredDevice != null && devicePresentation.canReconnect,
                    ) {
                        Text(devicePresentation.primaryActionLabel)
                    }
                }
                TextButton(
                    onClick = { onForgetStoredDevice?.invoke() },
                    enabled = !isBusy && onForgetStoredDevice != null,
                ) {
                    Text("Forget Local Device")
                }
            }
            if (isBusy) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator()
                    Text(text = busyMessage ?: "Re-establishing session")
                }
            }
        }
    }
}

@Composable
private fun CreateAccountCard(
    profileName: String,
    onProfileNameChange: (String) -> Unit,
    handle: String,
    onHandleChange: (String) -> Unit,
    deviceDisplayName: String,
    onDeviceDisplayNameChange: (String) -> Unit,
    isBusy: Boolean,
    busyMessage: String?,
    onCreateAccount: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text = "Create user",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            OutlinedTextField(
                value = profileName,
                onValueChange = onProfileNameChange,
                label = { Text("Profile name") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:profile-name-field"),
                singleLine = true,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = handle,
                onValueChange = onHandleChange,
                label = { Text("Handle (public, optional)") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:handle-field"),
                singleLine = true,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = deviceDisplayName,
                onValueChange = onDeviceDisplayNameChange,
                label = { Text("Device name") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:create-device-name-field"),
                singleLine = true,
                enabled = !isBusy,
            )
            Button(
                onClick = onCreateAccount,
                enabled = !isBusy && profileName.isNotBlank() && deviceDisplayName.isNotBlank(),
            ) {
                if (isBusy) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        CircularProgressIndicator()
                        Text(busyMessage ?: "Creating")
                    }
                } else {
                    Text("Create user")
                }
            }
        }
    }
}

@Composable
private fun LinkExistingAccountCard(
    linkPayload: String,
    onLinkPayloadChange: (String) -> Unit,
    deviceDisplayName: String,
    onDeviceDisplayNameChange: (String) -> Unit,
    isBusy: Boolean,
    busyMessage: String?,
    importStatusMessage: String?,
    importStatusIsError: Boolean,
    onScanQr: () -> Unit,
    onPasteFromClipboard: () -> Unit,
    onCompleteLinkIntent: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text = "Link device",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "After linking, approve this device from another trusted device.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = onScanQr,
                    enabled = !isBusy,
                ) {
                    Text("Scan QR")
                }
                OutlinedButton(
                    onClick = onPasteFromClipboard,
                    enabled = !isBusy,
                ) {
                    Text("Paste")
                }
            }
            if (!importStatusMessage.isNullOrBlank()) {
                Text(
                    text = importStatusMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (importStatusIsError) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                )
            }
            OutlinedTextField(
                value = linkPayload,
                onValueChange = onLinkPayloadChange,
                label = { Text("Link code") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:link-code-field"),
                minLines = 4,
                maxLines = 8,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = deviceDisplayName,
                onValueChange = onDeviceDisplayNameChange,
                label = { Text("Device name") },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("bootstrap:link-device-name-field"),
                singleLine = true,
                enabled = !isBusy,
            )
            Button(
                onClick = onCompleteLinkIntent,
                enabled = !isBusy && linkPayload.isNotBlank() && deviceDisplayName.isNotBlank(),
            ) {
                if (isBusy) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        CircularProgressIndicator()
                        Text(busyMessage ?: "Linking")
                    }
                } else {
                    Text("Link device")
                }
            }
        }
    }
}

private fun defaultDeviceName(): String {
    val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
    val model = Build.MODEL?.trim().orEmpty()
    return listOf(manufacturer, model)
        .filter { it.isNotBlank() }
        .joinToString(separator = " ")
        .ifBlank { "Android device" }
}

private fun normalizeBaseUrl(value: String): String {
    val normalized = value.trim().trimEnd('/')
    if (normalized.isEmpty()) {
        throw IOException("Backend URL cannot be empty")
    }
    if (!normalized.startsWith("http://") && !normalized.startsWith("https://")) {
        throw IOException("Backend URL must start with http:// or https://")
    }

    return normalized
}

private fun String.labelForBootstrap(): String {
    return when (this.lowercase()) {
        "pending" -> "Pending approval"
        "active" -> "Active"
        "revoked" -> "Revoked"
        else -> this
    }
}

private sealed interface BootstrapBackendProbeState {
    data object Idle : BootstrapBackendProbeState

    data object Loading : BootstrapBackendProbeState

    data class Ready(val snapshot: SystemSnapshot) : BootstrapBackendProbeState

    data class Failed(val message: String) : BootstrapBackendProbeState
}
