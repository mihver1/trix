package chat.trix.android.core.chat

import chat.trix.android.core.ffi.FfiContentType

internal data class TimedChatTimelineMessage(
    val sortUnix: Long,
    val sourcePriority: Int,
    val sourceOrder: Int,
    val message: ChatTimelineMessage,
    val receiptTargetMessageId: String? = null,
    val receiptStatus: ChatReceiptStatus? = null,
)

internal fun mergeChatTimelineMessages(
    messages: List<TimedChatTimelineMessage>,
): List<ChatTimelineMessage> {
    val receiptStatusByMessageId = mutableMapOf<String, ChatReceiptStatus>()
    val visibleMessages = messages
        .sortedWith(
            compareBy<TimedChatTimelineMessage> { it.sortUnix }
                .thenBy { it.sourcePriority }
                .thenBy { it.sourceOrder }
                .thenBy { it.message.id },
        )
        .mapNotNull { timedMessage ->
            if (
                timedMessage.message.contentType == FfiContentType.RECEIPT ||
                (timedMessage.receiptTargetMessageId != null && timedMessage.receiptStatus != null)
            ) {
                val targetMessageId = timedMessage.receiptTargetMessageId
                val receiptStatus = timedMessage.receiptStatus
                if (targetMessageId != null && receiptStatus != null) {
                    val currentStatus = receiptStatusByMessageId[targetMessageId]
                    receiptStatusByMessageId[targetMessageId] = when {
                        currentStatus == null -> receiptStatus
                        currentStatus.ordinal >= receiptStatus.ordinal -> currentStatus
                        else -> receiptStatus
                    }
                }
                null
            } else {
                timedMessage.message
            }
        }

    return visibleMessages.map { message ->
        message.copy(receiptStatus = receiptStatusByMessageId[message.id])
    }
}
