package chat.trix.android.feature.chats

import chat.trix.android.core.chat.ChatConversation
import chat.trix.android.core.chat.ChatConversationMember
import chat.trix.android.core.chat.ChatTimelineMessage
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiContentType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatsScreenStateTest {
    @Test
    fun `passive conversation reload preserves in flight send state`() {
        val result = applyPassiveConversationReload(
            currentDetailState = ChatsDetailState(
                conversation = sampleConversation(),
                isLoading = true,
                errorMessage = "stale",
            ),
            currentSendState = ChatSendState(
                isSending = true,
                sendErrorMessage = "Keep me",
            ),
            conversation = sampleConversation(title = "Refreshed"),
            errorMessage = null,
        )

        assertEquals("Refreshed", result.detailState.conversation?.title)
        assertFalse(result.detailState.isLoading)
        assertEquals(null, result.detailState.errorMessage)
        assertTrue(result.sendState.isSending)
        assertEquals("Keep me", result.sendState.sendErrorMessage)
    }

    @Test
    fun `passive reload failure does not unlock send state`() {
        val result = applyPassiveConversationReload(
            currentDetailState = ChatsDetailState(
                conversation = sampleConversation(),
                isLoading = true,
            ),
            currentSendState = ChatSendState(isSending = true),
            conversation = sampleConversation(),
            errorMessage = "Failed to load conversation",
        )

        assertTrue(result.sendState.isSending)
        assertEquals("Failed to load conversation", result.detailState.errorMessage)
    }

    private fun sampleConversation(
        chatId: String = "chat-1",
        title: String = "Design review",
    ): ChatConversation {
        return ChatConversation(
            chatId = chatId,
            chatType = FfiChatType.GROUP,
            title = title,
            participantsLabel = "Alex, Sam",
            timelineLabel = "Projected timeline",
            isAccountSyncChat = false,
            canSend = true,
            canManageMembers = true,
            composerHint = "Send through the local MLS state already present on this device.",
            members = listOf(
                ChatConversationMember(
                    accountId = "self",
                    displayName = "You",
                    role = "owner",
                    membershipStatus = "active",
                    isSelf = true,
                ),
            ),
            messages = listOf(
                ChatTimelineMessage(
                    id = "message-1",
                    author = "You",
                    body = "hello",
                    timestampLabel = "10:42",
                    isMine = true,
                    note = null,
                    contentType = FfiContentType.TEXT,
                ),
            ),
        )
    }
}
