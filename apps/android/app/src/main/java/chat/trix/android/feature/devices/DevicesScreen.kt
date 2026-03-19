package chat.trix.android.feature.devices

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Pending
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.TabletAndroid
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
    windowInfo: TrixAdaptiveInfo,
    modifier: Modifier = Modifier,
) {
    val devices = remember { sampleDevices() }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(stringResource(R.string.screen_devices)) },
            )
        },
    ) { innerPadding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 280.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Surface(
                    shape = MaterialTheme.shapes.extraLarge,
                    color = MaterialTheme.colorScheme.secondaryContainer,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    androidx.compose.foundation.layout.Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = "Multi-device baseline",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "The Android client is structured for trusted-device approval and device revocation from day one.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                        )
                        AssistChip(
                            onClick = {},
                            label = {
                                Text(
                                    text = "Layout: ${windowInfo.widthClass.name.lowercase()} / ${windowInfo.foldPosture.name.lowercase()}",
                                )
                            },
                        )
                    }
                }
            }

            items(devices, key = { it.id }) { device ->
                Surface(
                    shape = MaterialTheme.shapes.extraLarge,
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    androidx.compose.foundation.layout.Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Icon(
                            imageVector = device.formFactor.icon,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            text = device.name,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = device.subtitle,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        AssistChip(
                            onClick = {},
                            label = { Text(device.state.label) },
                            leadingIcon = {
                                Icon(
                                    imageVector = device.state.icon,
                                    contentDescription = null,
                                )
                            },
                        )
                        Text(
                            text = "Last seen ${device.lastSeen}",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

private data class DeviceUiModel(
    val id: String,
    val name: String,
    val subtitle: String,
    val formFactor: DeviceFormFactor,
    val state: DeviceState,
    val lastSeen: String,
)

private enum class DeviceFormFactor(val icon: ImageVector) {
    Phone(Icons.Rounded.PhoneAndroid),
    Tablet(Icons.Rounded.TabletAndroid),
}

private enum class DeviceState(
    val label: String,
    val icon: ImageVector,
) {
    Active("Active", Icons.Rounded.CheckCircle),
    Pending("Pending approval", Icons.Rounded.Pending),
    Revoked("Revoked", Icons.Rounded.Warning),
}

private fun sampleDevices(): List<DeviceUiModel> = listOf(
    DeviceUiModel(
        id = "pixel",
        name = "Pixel Fold",
        subtitle = "Primary Android device for phone and tabletop testing",
        formFactor = DeviceFormFactor.Phone,
        state = DeviceState.Active,
        lastSeen = "5 min ago",
    ),
    DeviceUiModel(
        id = "tablet",
        name = "Pixel Tablet",
        subtitle = "Expanded-width reference for dual-pane chat and settings cards",
        formFactor = DeviceFormFactor.Tablet,
        state = DeviceState.Active,
        lastSeen = "32 min ago",
    ),
    DeviceUiModel(
        id = "spare",
        name = "Galaxy S24",
        subtitle = "Pending link intent waiting for trusted-device approval",
        formFactor = DeviceFormFactor.Phone,
        state = DeviceState.Pending,
        lastSeen = "Today",
    ),
)
