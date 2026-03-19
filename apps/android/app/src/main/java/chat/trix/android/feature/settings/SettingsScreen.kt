package chat.trix.android.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.item
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import chat.trix.android.R
import chat.trix.android.ui.adaptive.TrixAdaptiveInfo

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    windowInfo: TrixAdaptiveInfo,
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
                    body = "Android backup is disabled in the manifest so keystore material and encrypted local state are not pushed into cloud backup by default.",
                )
            }
            item {
                SettingsCard(
                    title = "Backend wiring",
                    body = "The scaffold is ready for a thin server layer. First endpoint pass should target system health/version, account bootstrap, and device session flows.",
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
                    body = "Add a small repository layer, secure token storage via Android Keystore, and offline thread caching before touching MLS state sync.",
                )
            }
        }
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
        androidx.compose.foundation.layout.Column(
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
