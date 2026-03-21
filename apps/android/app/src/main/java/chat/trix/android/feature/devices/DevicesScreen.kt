package chat.trix.android.feature.devices

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Pending
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.TabletAndroid
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.devices.AccountDevice
import chat.trix.android.core.devices.AccountDeviceStatus
import chat.trix.android.core.devices.DeviceInventory
import chat.trix.android.core.devices.DeviceLinkIntent
import chat.trix.android.core.devices.DeviceRepository
import chat.trix.android.core.devices.formatLinkExpiry
import chat.trix.android.core.devices.prettyPrintJsonOrRaw
import chat.trix.android.core.devices.shortDeviceIdentifier
import chat.trix.android.core.system.renderQrCodeBitmap
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import java.io.IOException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
    windowInfo: TrixAdaptiveInfo,
    session: AuthenticatedSession,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val clipboard = LocalClipboardManager.current
    val canManageTrust = session.localState.hasAccountRootMaterial
    val repository = remember(
        context,
        session.localState.accountId,
        session.localState.deviceId,
        session.accessToken,
        session.baseUrl,
    ) {
        DeviceRepository(
            context = context,
            session = session,
        )
    }
    val coroutineScope = rememberCoroutineScope()

    var uiState by remember(repository) {
        mutableStateOf(
            DevicesUiState(isLoading = true),
        )
    }
    var revokeDialogState by remember {
        mutableStateOf<RevokeDialogState?>(null)
    }

    suspend fun refreshDevices(initialLoad: Boolean = false) {
        uiState = uiState.copy(
            isLoading = initialLoad && uiState.inventory == null,
            isRefreshing = !initialLoad,
            errorMessage = null,
        )

        try {
            val inventory = repository.loadInventory()
            uiState = uiState.copy(
                inventory = inventory,
                isLoading = false,
                isRefreshing = false,
                errorMessage = null,
            )
        } catch (error: IOException) {
            uiState = uiState.copy(
                isLoading = false,
                isRefreshing = false,
                errorMessage = error.message ?: "Failed to load devices",
            )
        }
    }

    suspend fun createLinkIntent() {
        uiState = uiState.copy(
            isCreatingLinkIntent = true,
            errorMessage = null,
            lastActionMessage = null,
        )

        try {
            val linkIntent = repository.createLinkIntent()
            uiState = uiState.copy(
                linkIntent = linkIntent,
                isCreatingLinkIntent = false,
                errorMessage = null,
                lastActionMessage = "New link intent created. Share the raw payload with the device you want to add.",
            )
        } catch (error: IOException) {
            uiState = uiState.copy(
                isCreatingLinkIntent = false,
                errorMessage = error.message ?: "Failed to create link intent",
            )
        }
    }

    suspend fun approveDevice(device: AccountDevice) {
        uiState = uiState.copy(
            actingDeviceId = device.deviceId,
            errorMessage = null,
            lastActionMessage = null,
        )

        try {
            val inventory = repository.approveDevice(device.deviceId)
            uiState = uiState.copy(
                inventory = inventory,
                actingDeviceId = null,
                errorMessage = null,
                lastActionMessage = "${device.displayName} is now active.",
            )
        } catch (error: IOException) {
            uiState = uiState.copy(
                actingDeviceId = null,
                errorMessage = error.message ?: "Failed to approve device",
            )
        }
    }

    suspend fun revokeDevice(device: AccountDevice, reason: String) {
        uiState = uiState.copy(
            actingDeviceId = device.deviceId,
            errorMessage = null,
            lastActionMessage = null,
        )

        try {
            val inventory = repository.revokeDevice(device.deviceId, reason)
            revokeDialogState = null
            uiState = uiState.copy(
                inventory = inventory,
                actingDeviceId = null,
                errorMessage = null,
                lastActionMessage = "${device.displayName} has been revoked.",
            )
        } catch (error: IOException) {
            uiState = uiState.copy(
                actingDeviceId = null,
                errorMessage = error.message ?: "Failed to revoke device",
            )
        }
    }

    DisposableEffect(repository) {
        onDispose {
            repository.close()
        }
    }

    LaunchedEffect(repository) {
        refreshDevices(initialLoad = true)
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(stringResource(R.string.screen_devices)) },
                actions = {
                    IconButton(
                        onClick = {
                            coroutineScope.launch {
                                refreshDevices()
                            }
                        },
                        enabled = !uiState.isBusy,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Sync,
                            contentDescription = "Refresh devices",
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        when {
            uiState.isLoading && uiState.inventory == null -> {
                LoadingDevicesPane(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
                )
            }

            else -> {
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(minSize = 300.dp),
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        DevicesSummaryCard(
                            windowInfo = windowInfo,
                            inventory = uiState.inventory,
                            canManageTrust = canManageTrust,
                            isRefreshing = uiState.isRefreshing,
                            errorMessage = uiState.errorMessage,
                            lastActionMessage = uiState.lastActionMessage,
                        )
                    }

                    item(span = { GridItemSpan(maxLineSpan) }) {
                        LinkIntentCard(
                            linkIntent = uiState.linkIntent,
                            isBusy = uiState.isBusy,
                            onCreateLinkIntent = {
                                coroutineScope.launch {
                                    createLinkIntent()
                                }
                            },
                            onCopyPayload = { payload ->
                                clipboard.setText(AnnotatedString(payload))
                                uiState = uiState.copy(
                                    lastActionMessage = "Link payload copied to the clipboard.",
                                )
                            },
                            onSharePayload = { payload ->
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND).apply {
                                            type = "text/plain"
                                            putExtra(Intent.EXTRA_TEXT, payload)
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        },
                                        "Share link payload",
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                                uiState = uiState.copy(
                                    lastActionMessage = "Link payload sent to the system share sheet.",
                                )
                            },
                        )
                    }

                    val inventory = uiState.inventory
                    if (inventory == null || inventory.devices.isEmpty()) {
                        item(span = { GridItemSpan(maxLineSpan) }) {
                            EmptyDevicesCard()
                        }
                    } else {
                        items(inventory.devices, key = { it.deviceId }) { device ->
                            DeviceCard(
                                device = device,
                                canManageTrust = canManageTrust,
                                isActing = uiState.actingDeviceId == device.deviceId,
                                onApprove = {
                                    coroutineScope.launch {
                                        approveDevice(device)
                                    }
                                },
                                onRevoke = {
                                    revokeDialogState = RevokeDialogState(
                                        device = device,
                                        reason = "revoked-from-android",
                                    )
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    val dialogState = revokeDialogState
    if (dialogState != null) {
        RevokeDeviceDialog(
            state = dialogState,
            isBusy = uiState.actingDeviceId == dialogState.device.deviceId,
            onReasonChange = { reason ->
                revokeDialogState = dialogState.copy(reason = reason)
            },
            onDismiss = {
                if (uiState.actingDeviceId == null) {
                    revokeDialogState = null
                }
            },
            onConfirm = {
                coroutineScope.launch {
                    revokeDevice(dialogState.device, dialogState.reason)
                }
            },
        )
    }
}

@Composable
private fun LoadingDevicesPane(
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier,
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CircularProgressIndicator()
            Text(
                text = "Loading device inventory",
                style = MaterialTheme.typography.titleMedium,
            )
        }
    }
}

@Composable
private fun DevicesSummaryCard(
    windowInfo: TrixAdaptiveInfo,
    inventory: DeviceInventory?,
    canManageTrust: Boolean,
    isRefreshing: Boolean,
    errorMessage: String?,
    lastActionMessage: String?,
) {
    val devices = inventory?.devices.orEmpty()
    val activeCount = devices.count { it.status == AccountDeviceStatus.Active }
    val pendingCount = devices.count { it.status == AccountDeviceStatus.Pending }
    val revokedCount = devices.count { it.status == AccountDeviceStatus.Revoked }

    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "Trusted devices",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Approve pending devices, revoke old ones, and generate a fresh link payload for a new client.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
            if (!canManageTrust) {
                Text(
                    text = "This linked device does not have local account-root material yet. Listing devices still works, but approve/revoke actions must come from an older trusted device until transfer-bundle import lands.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                AssistChip(
                    onClick = {},
                    label = { Text("Active $activeCount") },
                )
                AssistChip(
                    onClick = {},
                    label = { Text("Pending $pendingCount") },
                )
                AssistChip(
                    onClick = {},
                    label = { Text("Revoked $revokedCount") },
                )
            }
            if (isRefreshing) {
                Text(
                    text = "Refreshing device inventory…",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            if (!errorMessage.isNullOrBlank()) {
                Text(
                    text = errorMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            } else if (!lastActionMessage.isNullOrBlank()) {
                Text(
                    text = lastActionMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
        }
    }
}

@Composable
private fun LinkIntentCard(
    linkIntent: DeviceLinkIntent?,
    isBusy: Boolean,
    onCreateLinkIntent: () -> Unit,
    onCopyPayload: (String) -> Unit,
    onSharePayload: (String) -> Unit,
) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Link,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Link a new device",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Generate a fresh link intent from this trusted device, render it as a QR code, and keep the raw JSON as a copy/share fallback.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            FilledTonalButton(
                onClick = onCreateLinkIntent,
                enabled = !isBusy,
            ) {
                if (isBusy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text("Create Link Intent")
                }
            }

            if (linkIntent != null) {
                val qrBitmap = remember(linkIntent.qrPayload) {
                    runCatching { renderQrCodeBitmap(linkIntent.qrPayload) }.getOrNull()
                }
                HorizontalDivider()

                AssistChip(
                    onClick = {},
                    label = { Text("Expires ${formatLinkExpiry(linkIntent.expiresAtUnix)}") },
                )

                Text(
                    text = "Intent ${linkIntent.linkIntentId}",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                if (qrBitmap != null) {
                    Surface(
                        shape = MaterialTheme.shapes.large,
                        color = MaterialTheme.colorScheme.surface,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Image(
                                bitmap = qrBitmap.asImageBitmap(),
                                contentDescription = "Device link QR code",
                                modifier = Modifier.size(240.dp),
                            )
                            Text(
                                text = "Scan this QR from the new Android device.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }

                SelectionContainer {
                    Surface(
                        shape = MaterialTheme.shapes.large,
                        color = MaterialTheme.colorScheme.surfaceContainerHighest,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = prettyPrintJsonOrRaw(linkIntent.qrPayload),
                            modifier = Modifier.padding(16.dp),
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                            ),
                        )
                    }
                }

                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    OutlinedButton(
                        onClick = { onCopyPayload(linkIntent.qrPayload) },
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.ContentCopy,
                            contentDescription = null,
                        )
                        Spacer(Modifier.size(8.dp))
                        Text("Copy Payload")
                    }
                    OutlinedButton(
                        onClick = { onSharePayload(linkIntent.qrPayload) },
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Share,
                            contentDescription = null,
                        )
                        Spacer(Modifier.size(8.dp))
                        Text("Share")
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyDevicesCard() {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = "No devices returned",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "The authenticated account has no device records yet, or the backend has not returned them.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DeviceCard(
    device: AccountDevice,
    canManageTrust: Boolean,
    isActing: Boolean,
    onApprove: () -> Unit,
    onRevoke: () -> Unit,
) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Icon(
                imageVector = device.icon(),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
            Text(
                text = device.displayName.ifBlank { "Unnamed device" },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = "${device.platform.ifBlank { "unknown platform" }} · ${shortDeviceIdentifier(device.deviceId)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                AssistChip(
                    onClick = {},
                    label = { Text(device.status.label()) },
                    leadingIcon = {
                        Icon(
                            imageVector = device.status.icon(),
                            contentDescription = null,
                        )
                    },
                )
                if (device.isCurrentDevice) {
                    AssistChip(
                        onClick = {},
                        label = { Text("This device") },
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (device.status == AccountDeviceStatus.Pending && !device.isCurrentDevice) {
                    Button(
                        onClick = onApprove,
                        enabled = !isActing && canManageTrust,
                        modifier = Modifier.weight(1f),
                    ) {
                        if (isActing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Text("Approve")
                        }
                    }
                }

                if (!device.isCurrentDevice && device.status != AccountDeviceStatus.Revoked) {
                    OutlinedButton(
                        onClick = onRevoke,
                        enabled = !isActing && canManageTrust,
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Revoke")
                    }
                }
            }
        }
    }
}

@Composable
private fun RevokeDeviceDialog(
    state: RevokeDialogState,
    isBusy: Boolean,
    onReasonChange: (String) -> Unit,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text("Revoke ${state.device.displayName}")
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = "This will revoke the device immediately. It will lose access to all conversations.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedTextField(
                    value = state.reason,
                    onValueChange = onReasonChange,
                    label = { Text("Reason") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(min = 280.dp),
                    enabled = !isBusy,
                    minLines = 2,
                    maxLines = 4,
                )
            }
        },
        confirmButton = {
            Button(
                onClick = onConfirm,
                enabled = !isBusy && state.reason.isNotBlank(),
            ) {
                if (isBusy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text("Revoke")
                }
            }
        },
        dismissButton = {
            TextButton(
                onClick = onDismiss,
                enabled = !isBusy,
            ) {
                Text("Cancel")
            }
        },
    )
}

private data class DevicesUiState(
    val inventory: DeviceInventory? = null,
    val linkIntent: DeviceLinkIntent? = null,
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val isCreatingLinkIntent: Boolean = false,
    val actingDeviceId: String? = null,
    val errorMessage: String? = null,
    val lastActionMessage: String? = null,
) {
    val isBusy: Boolean
        get() = isLoading || isRefreshing || isCreatingLinkIntent || actingDeviceId != null
}

private data class RevokeDialogState(
    val device: AccountDevice,
    val reason: String,
)

private fun AccountDevice.icon(): ImageVector {
    val normalized = "${displayName.lowercase()} ${platform.lowercase()}"
    return if ("tablet" in normalized || "ipad" in normalized) {
        Icons.Rounded.TabletAndroid
    } else {
        Icons.Rounded.PhoneAndroid
    }
}

private fun AccountDeviceStatus.label(): String {
    return when (this) {
        AccountDeviceStatus.Pending -> "Pending approval"
        AccountDeviceStatus.Active -> "Active"
        AccountDeviceStatus.Revoked -> "Revoked"
    }
}

private fun AccountDeviceStatus.icon(): ImageVector {
    return when (this) {
        AccountDeviceStatus.Pending -> Icons.Rounded.Pending
        AccountDeviceStatus.Active -> Icons.Rounded.CheckCircle
        AccountDeviceStatus.Revoked -> Icons.Rounded.Warning
    }
}
