package chat.trix.android.feature.chats

import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.widget.ImageView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Photo
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import chat.trix.android.core.chat.ChatAttachment
import chat.trix.android.core.chat.ChatRepository
import chat.trix.android.core.chat.LocalImagePreviewAttachment
import chat.trix.android.core.chat.supportsLocalImagePreview
import java.io.File

@Composable
internal fun InlineAttachmentPreview(
    attachment: ChatAttachment,
    repository: ChatRepository,
    enabled: Boolean,
    onOpenAttachment: (ChatAttachment) -> Unit,
    modifier: Modifier = Modifier,
) {
    val previewAttachment by produceState<LocalImagePreviewAttachment?>(initialValue = null, key1 = attachment.messageId, key2 = attachment.attachmentRef, key3 = attachment.blobId) {
        if (!attachment.supportsLocalImagePreview()) {
            return@produceState
        }

        value = runCatching {
            repository.loadImagePreviewAttachment(attachment)
        }.getOrNull()
    }

    Box(
        modifier = modifier
            .widthIn(max = 260.dp)
            .heightIn(min = 132.dp, max = 280.dp)
            .aspectRatio(previewAspectRatio(attachment), matchHeightConstraintsFirst = false)
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(enabled = enabled) { onOpenAttachment(attachment) },
        contentAlignment = Alignment.Center,
    ) {
        when {
            previewAttachment != null -> {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { context ->
                        ImageView(context).apply {
                            adjustViewBounds = true
                            scaleType = ImageView.ScaleType.FIT_CENTER
                        }
                    },
                    update = { imageView ->
                        bindAttachmentPreviewDrawable(
                            imageView = imageView,
                            filePath = previewAttachment!!.filePath,
                        )
                    },
                )
            }

            attachment.supportsLocalImagePreview() -> {
                CircularProgressIndicator(strokeWidth = 2.dp)
            }

            else -> {
                Icon(
                    imageVector = Icons.Rounded.Photo,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

private fun previewAspectRatio(attachment: ChatAttachment): Float {
    val width = attachment.widthPx
    val height = attachment.heightPx
    if (width == null || height == null || width <= 0 || height <= 0) {
        return 4f / 3f
    }

    return (width.toFloat() / height.toFloat()).coerceIn(0.5f, 1.8f)
}

private fun bindAttachmentPreviewDrawable(
    imageView: ImageView,
    filePath: String,
) {
    if (imageView.tag == filePath) {
        (imageView.drawable as? AnimatedImageDrawable)?.start()
        return
    }

    (imageView.drawable as? AnimatedImageDrawable)?.stop()

    val decoded = runCatching {
        ImageDecoder.decodeDrawable(ImageDecoder.createSource(File(filePath)))
    }.getOrNull()

    imageView.tag = filePath
    imageView.setImageDrawable(decoded)
    (decoded as? AnimatedImageDrawable)?.start()
}
