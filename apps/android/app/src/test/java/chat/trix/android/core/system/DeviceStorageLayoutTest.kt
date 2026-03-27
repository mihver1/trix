package chat.trix.android.core.system

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceStorageLayoutTest {
    @Test
    fun `uses canonical state-v1 device paths`() {
        val filesDir = Files.createTempDirectory("trix-device-layout").toFile()
        try {
            val layout = deviceStorageLayout(
                filesDir = filesDir,
                accountId = "account-123",
                deviceId = "device-456",
            )

            assertTrue(layout.sessionRoot.path.endsWith("trix/accounts/account-123/devices/device-456"))
            assertEquals("state-v1.db", layout.stateDatabasePath.name)
            assertEquals("attachments", layout.attachmentCacheRoot.name)
            assertEquals("decrypted", layout.decryptedAttachmentRoot.name)
            assertEquals("secure", layout.secureRoot.name)
            assertEquals("store-key-v1.bin", layout.storeKeyPath.name)
            assertEquals("auth-state-v1.bin", layout.deviceAuthStatePath.name)
            assertEquals("mls", layout.mlsStorageRoot.name)
        } finally {
            filesDir.deleteRecursively()
        }
    }

    @Test
    fun `prepares canonical roots without mutating legacy persistence paths`() {
        val filesDir = Files.createTempDirectory("trix-device-layout-prepare").toFile()
        try {
            val layout = deviceStorageLayout(
                filesDir = filesDir,
                accountId = "account-123",
                deviceId = "device-456",
            )
            layout.legacyHistoryStorePath.parentFile?.mkdirs()
            layout.legacySyncStatePath.parentFile?.mkdirs()
            layout.legacyHistoryStorePath.writeText("legacy-history")
            layout.legacySyncStatePath.writeText("legacy-sync")
            layout.legacyHistoryDatabasePath.writeText("legacy-history-sqlite")
            layout.legacySyncDatabasePath.writeText("legacy-sync-sqlite")

            layout.prepareCorePersistenceMigration()

            assertTrue(layout.sessionRoot.isDirectory)
            assertTrue(layout.attachmentCacheRoot.isDirectory)
            assertTrue(layout.decryptedAttachmentRoot.isDirectory)
            assertTrue(layout.secureRoot.isDirectory)
            assertTrue(layout.mlsStorageRoot.isDirectory)
            assertEquals("legacy-history", layout.legacyHistoryStorePath.readText())
            assertEquals("legacy-sync", layout.legacySyncStatePath.readText())
            assertEquals("legacy-history-sqlite", layout.legacyHistoryDatabasePath.readText())
            assertEquals("legacy-sync-sqlite", layout.legacySyncDatabasePath.readText())
        } finally {
            filesDir.deleteRecursively()
        }
    }
}
