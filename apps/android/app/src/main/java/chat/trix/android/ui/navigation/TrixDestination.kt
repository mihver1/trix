package chat.trix.android.ui.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChatBubble
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import chat.trix.android.R

enum class TrixDestination(
    @StringRes val titleRes: Int,
    val icon: ImageVector,
) {
    Chats(
        titleRes = R.string.nav_chats,
        icon = Icons.Rounded.ChatBubble,
    ),
    Devices(
        titleRes = R.string.nav_devices,
        icon = Icons.Rounded.Devices,
    ),
    Settings(
        titleRes = R.string.nav_settings,
        icon = Icons.Rounded.Settings,
    ),
}
