package chat.trix.android.core.system

import android.content.Context
import java.io.File
import java.io.IOException

data class DeviceStorageLayout(
    val sessionRoot: File,
    val stateDatabasePath: File,
    val mlsStorageRoot: File,
    val attachmentCacheRoot: File,
    val decryptedAttachmentRoot: File,
    val secureRoot: File,
    val storeKeyPath: File,
    val deviceAuthStatePath: File,
    val legacyHistoryDatabasePath: File,
    val legacySyncDatabasePath: File,
    val legacyHistoryStorePath: File,
    val legacySyncStatePath: File,
) {
    @Throws(IOException::class)
    fun prepareCorePersistenceMigration() {
        ensureDirectory(sessionRoot)
        ensureDirectory(attachmentCacheRoot)
        ensureDirectory(decryptedAttachmentRoot)
        ensureDirectory(secureRoot)
        ensureDirectory(mlsStorageRoot)
    }
}

fun deviceStorageLayout(
    context: Context,
    accountId: String,
    deviceId: String,
): DeviceStorageLayout {
    return deviceStorageLayout(
        filesDir = context.applicationContext.filesDir,
        accountId = accountId,
        deviceId = deviceId,
    )
}

fun deviceStorageLayout(
    filesDir: File,
    accountId: String,
    deviceId: String,
): DeviceStorageLayout {
    val sessionRoot = File(
        filesDir,
        "trix/accounts/$accountId/devices/$deviceId",
    )
    val attachmentCacheRoot = File(sessionRoot, "attachments")
    val secureRoot = File(sessionRoot, "secure")
    return DeviceStorageLayout(
        sessionRoot = sessionRoot,
        stateDatabasePath = File(sessionRoot, "state-v1.db"),
        mlsStorageRoot = File(sessionRoot, "mls"),
        attachmentCacheRoot = attachmentCacheRoot,
        decryptedAttachmentRoot = File(attachmentCacheRoot, "decrypted"),
        secureRoot = secureRoot,
        storeKeyPath = File(secureRoot, "store-key-v1.bin"),
        deviceAuthStatePath = File(secureRoot, "auth-state-v1.bin"),
        legacyHistoryDatabasePath = File(sessionRoot, "trix-client.db"),
        legacySyncDatabasePath = File(sessionRoot, "sync-state.sqlite"),
        legacyHistoryStorePath = File(sessionRoot, "history/local-history-v1.json"),
        legacySyncStatePath = File(sessionRoot, "sync/sync-state-v1.json"),
    )
}

@Throws(IOException::class)
private fun ensureDirectory(path: File) {
    if (path.exists()) {
        if (!path.isDirectory) {
            throw IOException("Expected directory at ${path.absolutePath}")
        }
        return
    }
    if (!path.mkdirs() && !path.isDirectory) {
        throw IOException("Failed to create directory ${path.absolutePath}")
    }
}
