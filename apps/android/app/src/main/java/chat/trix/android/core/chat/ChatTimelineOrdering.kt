package chat.trix.android.core.chat

internal data class TimedChatTimelineMessage(
    val sortUnix: Long,
    val sourcePriority: Int,
    val sourceOrder: Int,
    val message: ChatTimelineMessage,
    val isVisibleInTimeline: Boolean = true,
)

internal fun mergeChatTimelineMessages(
    messages: List<TimedChatTimelineMessage>,
): List<ChatTimelineMessage> {
    return messages
        .sortedWith(
            compareBy<TimedChatTimelineMessage> { it.sortUnix }
                .thenBy { it.sourcePriority }
                .thenBy { it.sourceOrder }
                .thenBy { it.message.id },
        )
        .filter(TimedChatTimelineMessage::isVisibleInTimeline)
        .map(TimedChatTimelineMessage::message)
}
