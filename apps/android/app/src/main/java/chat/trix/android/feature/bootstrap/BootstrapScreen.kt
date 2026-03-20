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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.core.auth.BootstrapInput
import chat.trix.android.core.auth.StoredDeviceSummary

@Composable
fun BootstrapScreen(
    baseUrl: String,
    storedDevice: StoredDeviceSummary?,
    busyMessage: String?,
    errorMessage: String?,
    backendErrorMessage: String?,
    onUpdateBaseUrl: (String) -> Unit,
    onCreateAccount: (BootstrapInput) -> Unit,
    onReconnectStoredDevice: (() -> Unit)?,
    onForgetStoredDevice: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    var profileName by rememberSaveable { mutableStateOf("") }
    var handle by rememberSaveable { mutableStateOf("") }
    var profileBio by rememberSaveable { mutableStateOf("") }
    var deviceDisplayName by rememberSaveable { mutableStateOf(defaultDeviceName()) }
    var editableBaseUrl by rememberSaveable(baseUrl) { mutableStateOf(baseUrl) }
    val isBusy = busyMessage != null

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
                        text = "This client now performs a real account bootstrap and device session handshake against `trixd`, while keeping device state encrypted at rest through Android Keystore.",
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
                    errorMessage = errorMessage,
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
                        text = "Create account, challenge the transport key, open a device session, and persist bootstrap state locally. Device linking and MLS stay out of this slice.",
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
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Stored device found",
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
            if (!errorMessage.isNullOrBlank()) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = { onReconnectStoredDevice?.invoke() },
                    enabled = !isBusy && onReconnectStoredDevice != null,
                ) {
                    Text("Reconnect")
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
    errorMessage: String?,
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
            if (!errorMessage.isNullOrBlank()) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
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

private fun defaultDeviceName(): String {
    val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
    val model = Build.MODEL?.trim().orEmpty()
    return listOf(manufacturer, model)
        .filter { it.isNotBlank() }
        .joinToString(separator = " ")
        .ifBlank { "Android device" }
}
