package chat.trix.android.core.auth

import java.io.IOException

enum class StoredDeviceStatus {
    Active,
    Pending,
    Revoked,
    Unknown,
}

data class StoredDevicePresentation(
    val title: String,
    val body: String,
    val primaryActionLabel: String?,
    val canReconnect: Boolean,
)

data class StoredDeviceIssueNotification(
    val title: String,
    val body: String,
)

fun parseStoredDeviceStatus(rawStatus: String?): StoredDeviceStatus {
    return when (rawStatus?.trim()?.lowercase()) {
        "active" -> StoredDeviceStatus.Active
        "pending" -> StoredDeviceStatus.Pending
        "revoked" -> StoredDeviceStatus.Revoked
        else -> StoredDeviceStatus.Unknown
    }
}

fun storedDevicePresentation(storedDevice: StoredDeviceSummary): StoredDevicePresentation {
    return when (parseStoredDeviceStatus(storedDevice.deviceStatus)) {
        StoredDeviceStatus.Pending -> StoredDevicePresentation(
            title = "Approval pending",
            body = "This device finished the link handshake and is waiting for approval from a trusted device. After approval, use Check Approval to open the real session.",
            primaryActionLabel = "Check Approval",
            canReconnect = true,
        )

        StoredDeviceStatus.Revoked -> StoredDevicePresentation(
            title = "Device revoked",
            body = "This Android device was revoked on the account. It cannot reconnect and should be removed from local storage before linking or creating a new device state.",
            primaryActionLabel = null,
            canReconnect = false,
        )

        StoredDeviceStatus.Active -> StoredDevicePresentation(
            title = "Stored device found",
            body = "A locally encrypted device state already exists on this Android client. You can reconnect it or forget it and start over.",
            primaryActionLabel = "Reconnect",
            canReconnect = true,
        )

        StoredDeviceStatus.Unknown -> StoredDevicePresentation(
            title = "Stored device found",
            body = "A locally encrypted device state already exists on this Android client. You can attempt to reconnect it or forget it and start over.",
            primaryActionLabel = "Reconnect",
            canReconnect = true,
        )
    }
}

fun restoreSessionErrorMessage(
    storedDevice: StoredDeviceSummary,
    error: IOException,
): String {
    val status = parseStoredDeviceStatus(storedDevice.deviceStatus)
    val message = error.message.orEmpty()
    return when {
        status == StoredDeviceStatus.Pending ||
            message.contains("pending approval", ignoreCase = true) ||
            message.contains("device is not active", ignoreCase = true) ->
            "This device is still pending approval. Approve it from a trusted device, then tap Check Approval."

        status == StoredDeviceStatus.Revoked ||
            message.contains("revoked", ignoreCase = true) ->
            "This device has been revoked and cannot restore a session. Forget the local device state before linking or creating a new session."

        else -> error.message ?: "Session restore failed"
    }
}

fun isActionableSessionError(
    storedDeviceStatus: String?,
    error: IOException,
): Boolean {
    val status = parseStoredDeviceStatus(storedDeviceStatus)
    val message = error.message.orEmpty()
    return status == StoredDeviceStatus.Pending ||
        status == StoredDeviceStatus.Revoked ||
        message.contains("pending approval", ignoreCase = true) ||
        message.contains("device is not active", ignoreCase = true) ||
        message.contains("revoked", ignoreCase = true)
}

fun storedDeviceIssueNotification(
    storedDeviceStatus: String?,
    error: IOException,
): StoredDeviceIssueNotification {
    val status = parseStoredDeviceStatus(storedDeviceStatus)
    val message = error.message.orEmpty()
    return when {
        status == StoredDeviceStatus.Pending ||
            message.contains("pending approval", ignoreCase = true) ||
            message.contains("device is not active", ignoreCase = true) ->
            StoredDeviceIssueNotification(
                title = "Trix device is pending approval",
                body = "Approve this Android device from a trusted device, then return and tap Check Approval.",
            )

        status == StoredDeviceStatus.Revoked ||
            message.contains("revoked", ignoreCase = true) ->
            StoredDeviceIssueNotification(
                title = "Trix device was revoked",
                body = "This Android device can no longer restore a session. Forget the local device state before linking again.",
            )

        else -> StoredDeviceIssueNotification(
            title = "Trix device needs attention",
            body = error.message ?: "This Android device cannot restore its Trix session right now.",
        )
    }
}
