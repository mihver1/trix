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
import androidx.compose.foundation.layout.weight
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.designsystem.theme.TrixTheme
import chat.trix.android.feature.chats.ChatsScreen
import chat.trix.android.feature.devices.DevicesScreen
import chat.trix.android.feature.settings.SettingsScreen
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo
import chat.trix.android.ui.adaptive.TrixNavigationLayout
import chat.trix.android.ui.adaptive.rememberTrixAdaptiveInfo
import chat.trix.android.ui.navigation.TrixDestination

@Composable
fun TrixApp() {
    TrixTheme {
        val windowInfo = rememberTrixAdaptiveInfo()
        var destination by rememberSaveable { mutableStateOf(TrixDestination.Chats) }

        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            when (windowInfo.navigationLayout) {
                TrixNavigationLayout.BottomBar -> BottomBarLayout(
                    destination = destination,
                    onDestinationChange = { destination = it },
                    windowInfo = windowInfo,
                )
                TrixNavigationLayout.NavigationRail -> RailLayout(
                    destination = destination,
                    onDestinationChange = { destination = it },
                    windowInfo = windowInfo,
                )
                TrixNavigationLayout.PermanentDrawer -> DrawerLayout(
                    destination = destination,
                    onDestinationChange = { destination = it },
                    windowInfo = windowInfo,
                )
            }
        }
    }
}

@Composable
private fun BottomBarLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
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
            modifier = Modifier.padding(innerPadding),
        )
    }
}

@Composable
private fun RailLayout(
    destination: TrixDestination,
    onDestinationChange: (TrixDestination) -> Unit,
    windowInfo: TrixAdaptiveInfo,
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
                        text = "Android adaptive client scaffold",
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
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun DestinationContent(
    destination: TrixDestination,
    windowInfo: TrixAdaptiveInfo,
    modifier: Modifier = Modifier,
) {
    when (destination) {
        TrixDestination.Chats -> ChatsScreen(
            windowInfo = windowInfo,
            modifier = modifier,
        )
        TrixDestination.Devices -> DevicesScreen(
            windowInfo = windowInfo,
            modifier = modifier,
        )
        TrixDestination.Settings -> SettingsScreen(
            windowInfo = windowInfo,
            modifier = modifier,
        )
    }
}
