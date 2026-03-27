package chat.trix.android.core.chat

import chat.trix.android.core.ffi.FfiContentType
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatTimelineOrderingTest {
    @Test
    fun `older queued outbox item is inserted before newer projected messages`() {
        val ordered = mergeChatTimelineMessages(
            listOf(
                timedMessage(id = "timeline-newer", sortUnix = 200, sourcePriority = 0, sourceOrder = 0),
                timedMessage(id = "outbox-older", sortUnix = 100, sourcePriority = 1, sourceOrder = 0),
                timedMessage(id = "timeline-newest", sortUnix = 300, sourcePriority = 0, sourceOrder = 1),
            ),
        )

        assertEquals(
            listOf("outbox-older", "timeline-newer", "timeline-newest"),
            ordered.map(ChatTimelineMessage::id),
        )
    }

    @Test
    fun `same timestamp keeps projected messages ahead of outbox items`() {
        val ordered = mergeChatTimelineMessages(
            listOf(
                timedMessage(id = "timeline", sortUnix = 200, sourcePriority = 0, sourceOrder = 0),
                timedMessage(id = "outbox", sortUnix = 200, sourcePriority = 1, sourceOrder = 0),
            ),
        )

        assertEquals(
            listOf("timeline", "outbox"),
            ordered.map(ChatTimelineMessage::id),
        )
    }

    @Test
    fun `receipt metadata suppresses message even when content type is stale`() {
        val ordered = mergeChatTimelineMessages(
            listOf(
                timedMessage(id = "target", sortUnix = 100, sourcePriority = 0, sourceOrder = 0),
                timedMessage(
                    id = "receipt",
                    sortUnix = 200,
                    sourcePriority = 0,
                    sourceOrder = 1,
                    receiptTargetMessageId = "target",
                    receiptStatus = ChatReceiptStatus.READ,
                ),
            ),
        )

        assertEquals(listOf("target"), ordered.map(ChatTimelineMessage::id))
        assertEquals(ChatReceiptStatus.READ, ordered.single().receiptStatus)
    }

    private fun timedMessage(
        id: String,
        sortUnix: Long,
        sourcePriority: Int,
        sourceOrder: Int,
        receiptTargetMessageId: String? = null,
        receiptStatus: ChatReceiptStatus? = null,
    ): TimedChatTimelineMessage {
        return TimedChatTimelineMessage(
            sortUnix = sortUnix,
            sourcePriority = sourcePriority,
            sourceOrder = sourceOrder,
            message = ChatTimelineMessage(
                id = id,
                author = "You",
                body = id,
                timestampLabel = "10:42",
                isMine = true,
                note = null,
                contentType = FfiContentType.TEXT,
            ),
            receiptTargetMessageId = receiptTargetMessageId,
            receiptStatus = receiptStatus,
        )
    }
}
