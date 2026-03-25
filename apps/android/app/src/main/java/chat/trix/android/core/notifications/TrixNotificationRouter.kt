package chat.trix.android.core.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import chat.trix.android.core.auth.AuthenticatedSession
import chat.trix.android.core.chat.ChatOverview
import chat.trix.android.core.system.chatLaunchPendingIntent

class TrixNotificationRouter(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val manager = NotificationManagerCompat.from(appContext)

    fun ensureChannels() {
        val notificationManager = appContext.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channels = listOf(
            NotificationChannel(
                CHANNEL_MESSAGES,
                "Messages",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Unread message updates from Trix background sync"
            },
            NotificationChannel(
                CHANNEL_SYSTEM,
                "Device status",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Device approval, revocation, and session status updates"
            },
            NotificationChannel(
                CHANNEL_REALTIME,
                "Realtime sync",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Persistent notification that keeps Trix realtime delivery running"
            },
        )
        notificationManager.createNotificationChannels(channels)
    }

    fun buildRealtimeServiceNotification(
        title: String,
        body: String,
    ) = NotificationCompat.Builder(appContext, CHANNEL_REALTIME)
        .setSmallIcon(android.R.drawable.stat_notify_sync)
        .setContentTitle(title)
        .setContentText(body)
        .setStyle(NotificationCompat.BigTextStyle().bigText(body))
        .setContentIntent(chatLaunchPendingIntent(appContext, null))
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .build()

    fun publishUnreadSummary(
        session: AuthenticatedSession,
        overview: ChatOverview,
    ) {
        if (!canPostNotifications()) {
            return
        }

        val unreadConversations = overview.conversations.filter { it.unreadCount > 0 }
        if (unreadConversations.isEmpty()) {
            manager.cancel(TAG_MESSAGES, NOTIFICATION_UNREAD_SUMMARY)
            return
        }

        val focus = unreadConversations.first()
        val totalUnread = unreadConversations.sumOf { it.unreadCount }
        val contentTitle = if (unreadConversations.size == 1) {
            focus.title
        } else {
            "${unreadConversations.size} chats with unread messages"
        }
        val contentText = if (unreadConversations.size == 1) {
            focus.lastMessagePreview
        } else {
            "${session.accountProfile.profileName}, you have $totalUnread unread messages"
        }

        val notification = NotificationCompat.Builder(appContext, CHANNEL_MESSAGES)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(contentTitle)
            .setContentText(contentText)
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(contentText),
            )
            .setContentIntent(
                chatLaunchPendingIntent(
                    context = appContext,
                    chatId = focus.chatId,
                ),
            )
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setNumber(totalUnread)
            .build()

        manager.notify(TAG_MESSAGES, NOTIFICATION_UNREAD_SUMMARY, notification)
    }

    fun publishDeviceStatusIssue(
        title: String,
        body: String,
    ) {
        if (!canPostNotifications()) {
            return
        }

        val notification = NotificationCompat.Builder(appContext, CHANNEL_SYSTEM)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(chatLaunchPendingIntent(appContext, null))
            .setAutoCancel(true)
            .build()

        manager.notify(TAG_SYSTEM, NOTIFICATION_DEVICE_STATUS, notification)
    }

    private fun canPostNotifications(): Boolean {
        if (!manager.areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        private const val CHANNEL_MESSAGES = "messages"
        private const val CHANNEL_SYSTEM = "system"
        private const val CHANNEL_REALTIME = "realtime"
        private const val TAG_MESSAGES = "trix.messages"
        private const val TAG_SYSTEM = "trix.system"
        private const val NOTIFICATION_UNREAD_SUMMARY = 1001
        private const val NOTIFICATION_DEVICE_STATUS = 1002
    }
}
