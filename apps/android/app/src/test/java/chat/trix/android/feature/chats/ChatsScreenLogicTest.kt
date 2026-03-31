package chat.trix.android.feature.chats

import chat.trix.android.core.chat.ChatConversation
import chat.trix.android.core.ffi.FfiChatType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChatsScreenLogicTest {
    @Test
    fun resolveQuickReactionEmojisUsesFfiValuesWhenAvailable() {
        val resolved = resolveQuickReactionEmojis(
            loadFromFfi = { listOf("🧪", "✅") },
        )

        assertEquals(listOf("🧪", "✅"), resolved)
    }

    @Test
    fun resolveQuickReactionEmojisFallsBackWhenFfiReturnsEmpty() {
        val resolved = resolveQuickReactionEmojis(
            loadFromFfi = { emptyList() },
            fallback = listOf("👍", "❤️"),
        )

        assertEquals(listOf("👍", "❤️"), resolved)
    }

    @Test
    fun resolveQuickReactionEmojisFallsBackWhenFfiThrows() {
        val resolved = resolveQuickReactionEmojis(
            loadFromFfi = { error("ffi unavailable") },
            fallback = listOf("👍", "❤️"),
        )

        assertEquals(listOf("👍", "❤️"), resolved)
    }

    @Test
    fun reactionSendBlockReasonReturnsComposerHintWhenConversationCannotSend() {
        val reason = reactionSendBlockReason(
            conversation = sampleConversation(canSend = false, composerHint = "Read-only chat"),
            isSending = false,
        )

        assertEquals("Read-only chat", reason)
    }

    @Test
    fun reactionSendBlockReasonReturnsInFlightMessageWhenSending() {
        val reason = reactionSendBlockReason(
            conversation = sampleConversation(canSend = true, composerHint = "Type here"),
            isSending = true,
        )

        assertEquals("Finish the current send before adding a reaction.", reason)
    }

    @Test
    fun reactionSendBlockReasonReturnsNullWhenReactionCanProceed() {
        val reason = reactionSendBlockReason(
            conversation = sampleConversation(canSend = true, composerHint = "Type here"),
            isSending = false,
        )

        assertNull(reason)
    }

    private fun sampleConversation(
        canSend: Boolean,
        composerHint: String,
    ): ChatConversation {
        return ChatConversation(
            chatId = "chat-1",
            chatType = FfiChatType.GROUP,
            title = "Test chat",
            participantsLabel = "Alex",
            timelineLabel = "Timeline",
            isAccountSyncChat = false,
            canSend = canSend,
            canManageMembers = false,
            composerHint = composerHint,
            members = emptyList(),
            messages = emptyList(),
        )
    }
}
