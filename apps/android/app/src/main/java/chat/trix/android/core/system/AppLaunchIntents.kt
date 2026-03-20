package chat.trix.android.core.system

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import chat.trix.android.MainActivity

const val EXTRA_OPEN_DESTINATION = "chat.trix.android.extra.OPEN_DESTINATION"
const val EXTRA_OPEN_CHAT_ID = "chat.trix.android.extra.OPEN_CHAT_ID"
const val DESTINATION_CHATS = "chats"
const val ACTION_OPEN_CHAT = "chat.trix.android.action.OPEN_CHAT"

fun chatLaunchPendingIntent(
    context: Context,
    chatId: String?,
): PendingIntent {
    val intent = Intent(context, MainActivity::class.java)
        .setAction(ACTION_OPEN_CHAT)
        .putExtra(EXTRA_OPEN_DESTINATION, DESTINATION_CHATS)
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    if (!chatId.isNullOrBlank()) {
        intent.putExtra(EXTRA_OPEN_CHAT_ID, chatId)
    }

    return PendingIntent.getActivity(
        context,
        chatId?.hashCode() ?: 0,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
