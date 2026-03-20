package chat.trix.android.core.chat

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.ffi.FfiAttachmentUploadParams
import chat.trix.android.core.ffi.FfiDownloadedAttachment
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiServerApiClient
import chat.trix.android.core.ffi.FfiUploadedAttachment
import chat.trix.android.core.ffi.TrixFfiException
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AttachmentRepository(
    context: Context,
    private val session: AuthenticatedSession,
) {
    private val appContext = context.applicationContext
    private val sessionRoot = File(
        appContext.filesDir,
        "trix/accounts/${session.localState.accountId}/devices/${session.localState.deviceId}",
    )
    private val decryptedAttachmentRoot = File(sessionRoot, "attachments/decrypted")
    private val clientDelegate = lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        FfiServerApiClient(session.baseUrl)
    }

    suspend fun uploadAttachment(
        chatId: String,
        contentUri: Uri,
    ): FfiUploadedAttachment = withContext(Dispatchers.IO) {
        runFfi("Failed to upload attachment") {
            val contentResolver = appContext.contentResolver
            val payload = contentResolver.openInputStream(contentUri)?.use { stream ->
                stream.readBytes()
            } ?: throw IOException("Attachment content is no longer readable")
            val metadata = readAttachmentMetadata(contentUri, payload)
            authenticatedClient().uploadAttachment(
                chatId = chatId,
                payload = payload,
                params = FfiAttachmentUploadParams(
                    mimeType = metadata.mimeType,
                    fileName = metadata.fileName,
                    widthPx = metadata.widthPx?.toUInt(),
                    heightPx = metadata.heightPx?.toUInt(),
                ),
            )
        }
    }

    suspend fun openAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        val file = materializeAttachment(attachment)
        val contentUri = fileUriFor(file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(contentUri, attachment.mimeType)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            appContext.startActivity(Intent.createChooser(intent, "Open attachment").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (error: ActivityNotFoundException) {
            throw IOException("No Android app can open ${attachment.mimeType}", error)
        }
    }

    suspend fun shareAttachment(attachment: ChatAttachment) = withContext(Dispatchers.IO) {
        val file = materializeAttachment(attachment)
        val contentUri = fileUriFor(file)
        val intent = Intent(Intent.ACTION_SEND)
            .setType(attachment.mimeType)
            .putExtra(Intent.EXTRA_STREAM, contentUri)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        appContext.startActivity(Intent.createChooser(intent, "Share attachment").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun materializeAttachment(attachment: ChatAttachment): File {
        val targetFile = decryptedAttachmentFile(attachment)
        if (targetFile.exists() && targetFile.length() > 0L) {
            return targetFile
        }

        val download = authenticatedClient().downloadAttachment(attachment.body)
        writeDownloadedAttachment(targetFile, download)
        return targetFile
    }

    private fun writeDownloadedAttachment(
        targetFile: File,
        attachment: FfiDownloadedAttachment,
    ) {
        targetFile.parentFile?.mkdirs()
        targetFile.writeBytes(attachment.plaintext)
    }

    private fun readAttachmentMetadata(
        contentUri: Uri,
        payload: ByteArray,
    ): AttachmentUploadMetadata {
        val contentResolver = appContext.contentResolver
        val mimeType = contentResolver.getType(contentUri)
            ?.takeIf(String::isNotBlank)
            ?: "application/octet-stream"
        val (fileName, _) = queryDisplayMetadata(contentUri)
        val dimensions = if (mimeType.startsWith("image/")) {
            BitmapFactory.Options().run {
                inJustDecodeBounds = true
                BitmapFactory.decodeByteArray(payload, 0, payload.size, this)
                outWidth.takeIf { it > 0 } to outHeight.takeIf { it > 0 }
            }
        } else {
            null to null
        }

        return AttachmentUploadMetadata(
            mimeType = mimeType,
            fileName = fileName ?: fallbackFileName(contentUri, mimeType),
            widthPx = dimensions.first,
            heightPx = dimensions.second,
        )
    }

    private fun queryDisplayMetadata(contentUri: Uri): Pair<String?, Long?> {
        val cursor = appContext.contentResolver.query(
            contentUri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        ) ?: return null to null

        cursor.use {
            if (!it.moveToFirst()) {
                return null to null
            }
            val displayName = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                .takeIf { index -> index >= 0 }
                ?.let(it::getString)
                ?.trim()
                ?.takeIf(String::isNotEmpty)
            val size = it.getColumnIndex(OpenableColumns.SIZE)
                .takeIf { index -> index >= 0 && !it.isNull(index) }
                ?.let(it::getLong)
            return displayName to size
        }
    }

    private fun fallbackFileName(
        contentUri: Uri,
        mimeType: String,
    ): String {
        val extension = MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mimeType)
            ?.takeIf(String::isNotBlank)
        val lastSegment = contentUri.lastPathSegment
            ?.substringAfterLast('/')
            ?.takeIf(String::isNotBlank)
        return when {
            lastSegment != null -> lastSegment
            extension != null -> "attachment.$extension"
            else -> "attachment.bin"
        }
    }

    private fun decryptedAttachmentFile(attachment: ChatAttachment): File {
        val safeName = sanitizeFileName(
            attachment.fileName ?: fallbackFileName(Uri.EMPTY, attachment.mimeType),
        )
        return File(
            decryptedAttachmentRoot,
            "${attachment.blobId}-$safeName",
        )
    }

    private fun fileUriFor(file: File): Uri {
        return FileProvider.getUriForFile(
            appContext,
            "${appContext.packageName}.fileprovider",
            file,
        )
    }

    private fun authenticatedClient(): FfiServerApiClient {
        return clientDelegate.value.apply {
            setAccessToken(session.accessToken)
        }
    }

    private inline fun <T> runFfi(
        fallbackMessage: String,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            throw error
        } catch (error: TrixFfiException) {
            throw IOException(error.message ?: fallbackMessage, error)
        } catch (error: UnsatisfiedLinkError) {
            throw IOException("Rust FFI library is not available in the Android app bundle", error)
        } catch (error: RuntimeException) {
            throw IOException(fallbackMessage, error)
        }
    }

    private fun sanitizeFileName(value: String): String {
        return value.replace(Regex("[^a-zA-Z0-9._-]"), "_")
    }
}

private data class AttachmentUploadMetadata(
    val mimeType: String,
    val fileName: String?,
    val widthPx: Int?,
    val heightPx: Int?,
)
