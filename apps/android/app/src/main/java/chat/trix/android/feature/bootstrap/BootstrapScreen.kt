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
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.core.auth.BootstrapInput
import chat.trix.android.core.auth.LinkExistingAccountInput
import chat.trix.android.core.auth.parseStoredDeviceStatus
import chat.trix.android.core.auth.StoredDeviceSummary
import chat.trix.android.core.auth.StoredDeviceStatus
import chat.trix.android.core.auth.storedDevicePresentation
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

@Composable
fun BootstrapScreen(
    baseUrl: String,
    storedDevice: StoredDeviceSummary?,
    busyMessage: String?,
    errorMessage: String?,
    backendErrorMessage: String?,
    onUpdateBaseUrl: (String) -> Unit,
    onCreateAccount: (BootstrapInput) -> Unit,
    onCompleteLinkIntent: (LinkExistingAccountInput) -> Unit,
    onReconnectStoredDevice: (() -> Unit)?,
    onForgetStoredDevice: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var profileName by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var profileBio by rememberSaveable { mutableStateOf("") }
    var deviceDisplayName by rememberSaveable { mutableStateOf(defaultDeviceName()) }
    var linkPayload by rememberSaveable { mutableStateOf("") }
    var linkDeviceDisplayName by rememberSaveable { mutableStateOf(defaultDeviceName()) }
    var editableBaseUrl by rememberSaveable(baseUrl) { mutableStateOf(baseUrl) }
    var linkImportStatusMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var linkImportHasError by rememberSaveable { mutableStateOf(false) }
    val isBusy = busyMessage != null
    val qrScanner = remember(context) {
        GmsBarcodeScanning.getClient(
            context,
            GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build(),
        )
    }

    fun importLinkPayload(rawValue: String, sourceLabel: String) {
        val normalizedPayload = rawValue.trim()
        if (normalizedPayload.isBlank()) {
            linkImportStatusMessage = "$sourceLabel did not provide a link payload."
            linkImportHasError = true
            return
        }
        linkPayload = normalizedPayload
        linkImportStatusMessage = "Link payload imported from $sourceLabel."
        linkImportHasError = false
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
                        text = "Android bootstrap",
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "This client now performs real account bootstrap, linked-device onboarding, and device session handshakes against `trixd`, while keeping local state encrypted at rest through Android Keystore.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                    )
                }
            }

            BackendServerCard(
                baseUrl = baseUrl,
                editableBaseUrl = editableBaseUrl,
                onEditableBaseUrlChange = { editableBaseUrl = it },
                errorMessage = backendErrorMessage,
                isBusy = isBusy,
                onApplyBaseUrl = { onUpdateBaseUrl(editableBaseUrl) },
            )

            if (storedDevice != null) {
                StoredDeviceCard(
                    storedDevice = storedDevice,
                    isBusy = isBusy,
                    busyMessage = busyMessage,
                    errorMessage = errorMessage,
                    onReconnectStoredDevice = onReconnectStoredDevice,
                    onForgetStoredDevice = onForgetStoredDevice,
                )
            } else {
                CreateAccountCard(
                    profileName = profileName,
                    onProfileNameChange = { profileName = it },
                    handle = handle,
                    onHandleChange = { handle = it },
                    profileBio = profileBio,
                    onProfileBioChange = { profileBio = it },
                    deviceDisplayName = deviceDisplayName,
                    onDeviceDisplayNameChange = { deviceDisplayName = it },
                    isBusy = isBusy,
                    busyMessage = busyMessage,
                    onCreateAccount = {
                        onCreateAccount(
                            BootstrapInput(
                                profileName = profileName,
                                handle = handle,
                                profileBio = profileBio,
                                deviceDisplayName = deviceDisplayName,
                            ),
                        )
                    },
                )

                LinkExistingAccountCard(
                    linkPayload = linkPayload,
                    onLinkPayloadChange = {
                        linkPayload = it
                        linkImportStatusMessage = null
                        linkImportHasError = false
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
                            LinkExistingAccountInput(
                                rawPayload = linkPayload,
                                deviceDisplayName = linkDeviceDisplayName,
                            ),
                        )
                    },
                )

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

            Surface(
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = "Current scope",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Create a fresh account, import a raw device-link payload from another client, persist local bootstrap state, and reconnect once the trusted device approves the link.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun BackendServerCard(
    baseUrl: String,
    editableBaseUrl: String,
    onEditableBaseUrlChange: (String) -> Unit,
    errorMessage: String?,
    isBusy: Boolean,
    onApplyBaseUrl: () -> Unit,
) {
    val hasPendingChange = editableBaseUrl.trim().trimEnd('/') != baseUrl.trim().trimEnd('/')

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
                text = "Backend server",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "You can switch the test server directly from Android. In the emulator, your host machine is usually `http://10.0.2.2:8080`.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = editableBaseUrl,
                onValueChange = onEditableBaseUrlChange,
                label = { Text("Base URL") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                enabled = !isBusy,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ElevatedAssistChip(
                    onClick = {},
                    label = { Text("Current: $baseUrl") },
                )
                Button(
                    onClick = onApplyBaseUrl,
                    enabled = !isBusy && hasPendingChange && editableBaseUrl.isNotBlank(),
                ) {
                    Text("Apply")
                }
            }
            if (!errorMessage.isNullOrBlank()) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
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
    profileBio: String,
    onProfileBioChange: (String) -> Unit,
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
                text = "Create account",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            OutlinedTextField(
                value = profileName,
                onValueChange = onProfileNameChange,
                label = { Text("Profile name") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = handle,
                onValueChange = onHandleChange,
                label = { Text("Handle (optional)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = profileBio,
                onValueChange = onProfileBioChange,
                label = { Text("Bio (optional)") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
                maxLines = 4,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = deviceDisplayName,
                onValueChange = onDeviceDisplayNameChange,
                label = { Text("Device name") },
                modifier = Modifier.fillMaxWidth(),
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
                    Text("Create Account")
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
                text = "Link existing account",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Scan the QR code from a trusted device first. Raw JSON paste stays available as a fallback, and Android will adopt the payload's backend URL after a successful import.",
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
                    Text("Paste Clipboard")
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
                label = { Text("Raw link payload JSON") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                maxLines = 8,
                enabled = !isBusy,
            )
            OutlinedTextField(
                value = deviceDisplayName,
                onValueChange = onDeviceDisplayNameChange,
                label = { Text("Device name") },
                modifier = Modifier.fillMaxWidth(),
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
                    Text("Link Existing Account")
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

private fun String.labelForBootstrap(): String {
    return when (this.lowercase()) {
        "pending" -> "Pending approval"
        "active" -> "Active"
        "revoked" -> "Revoked"
        else -> this
    }
}
