package chat.trix.android.ui.adaptive

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Rect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

private const val COMPACT_WIDTH_UPPER_BOUND = 600
private const val MEDIUM_WIDTH_UPPER_BOUND = 840
private const val COMPACT_HEIGHT_UPPER_BOUND = 480
private const val MEDIUM_HEIGHT_UPPER_BOUND = 900

data class TrixAdaptiveInfo(
    val widthClass: TrixWidthClass,
    val heightClass: TrixHeightClass,
    val navigationLayout: TrixNavigationLayout,
    val foldPosture: TrixFoldPosture,
    val foldBounds: Rect?,
) {
    val prefersTwoPaneChat: Boolean
        get() = when {
            foldPosture == TrixFoldPosture.Tabletop -> false
            foldPosture == TrixFoldPosture.Book -> true
            widthClass == TrixWidthClass.Expanded -> true
            widthClass == TrixWidthClass.Medium && heightClass != TrixHeightClass.Compact -> true
            else -> false
        }
}

enum class TrixWidthClass {
    Compact,
    Medium,
    Expanded,
}

enum class TrixHeightClass {
    Compact,
    Medium,
    Expanded,
}

enum class TrixNavigationLayout {
    BottomBar,
    NavigationRail,
    PermanentDrawer,
}

enum class TrixFoldPosture {
    Flat,
    Book,
    Tabletop,
}

@Composable
fun rememberTrixAdaptiveInfo(): TrixAdaptiveInfo {
    val configuration = LocalConfiguration.current
    val activity = LocalContext.current.findActivity()
    val foldingFeature by produceState<FoldingFeature?>(initialValue = null, activity) {
        if (activity == null) {
            value = null
            return@produceState
        }

        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).collect { layoutInfo ->
            value = layoutInfo.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
        }
    }

    val widthClass = remember(configuration.screenWidthDp) {
        when {
            configuration.screenWidthDp < COMPACT_WIDTH_UPPER_BOUND -> TrixWidthClass.Compact
            configuration.screenWidthDp < MEDIUM_WIDTH_UPPER_BOUND -> TrixWidthClass.Medium
            else -> TrixWidthClass.Expanded
        }
    }
    val heightClass = remember(configuration.screenHeightDp) {
        when {
            configuration.screenHeightDp < COMPACT_HEIGHT_UPPER_BOUND -> TrixHeightClass.Compact
            configuration.screenHeightDp < MEDIUM_HEIGHT_UPPER_BOUND -> TrixHeightClass.Medium
            else -> TrixHeightClass.Expanded
        }
    }
    val navigationLayout = remember(widthClass) {
        when (widthClass) {
            TrixWidthClass.Compact -> TrixNavigationLayout.BottomBar
            TrixWidthClass.Medium -> TrixNavigationLayout.NavigationRail
            TrixWidthClass.Expanded -> TrixNavigationLayout.PermanentDrawer
        }
    }
    val foldPosture = remember(foldingFeature) { foldingFeature.toFoldPosture() }

    return remember(widthClass, heightClass, navigationLayout, foldPosture, foldingFeature) {
        TrixAdaptiveInfo(
            widthClass = widthClass,
            heightClass = heightClass,
            navigationLayout = navigationLayout,
            foldPosture = foldPosture,
            foldBounds = foldingFeature?.bounds,
        )
    }
}

private fun FoldingFeature?.toFoldPosture(): TrixFoldPosture {
    if (this == null) {
        return TrixFoldPosture.Flat
    }

    if (!isSeparating && state != FoldingFeature.State.HALF_OPENED) {
        return TrixFoldPosture.Flat
    }

    return when (orientation) {
        FoldingFeature.Orientation.VERTICAL -> TrixFoldPosture.Book
        FoldingFeature.Orientation.HORIZONTAL -> TrixFoldPosture.Tabletop
        else -> TrixFoldPosture.Flat
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
