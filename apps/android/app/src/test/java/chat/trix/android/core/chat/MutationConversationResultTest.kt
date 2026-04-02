package chat.trix.android.core.chat

import chat.trix.android.core.ffi.FfiChatType
import org.junit.Assert.assertEquals
import org.junit.Test

class MutationConversationResultTest {
    @Test
    fun sendResultBuildsFromMessengerOverviewAndConversation() {
        val overview = sampleOverview()
        val conversation = sampleConversation()

        val result = buildMutationConversationResult(
            unavailableMessage = "Conversation chat-1 is no longer available",
            buildOverview = { overview },
            buildConversation = { conversation },
            createResult = ::ChatSendResult,
        )

        assertEquals(ChatSendResult(overview, conversation), result)
    }

    private fun sampleOverview(): ChatOverview {
        return ChatOverview(
            conversations = emptyList(),
            diagnostics = ChatDiagnostics(
                cachedChatCount = 1,
                cachedMessageCount = 1,
                projectedChatCount = 1,
                pendingOutboxCount = 0,
                lastAckedInboxId = null,
                leaseOwner = "lease-owner",
                historyStorePath = "/tmp/history.db",
                syncStatePath = "/tmp/sync.db",
            ),
        )
    }

    private fun sampleConversation(): ChatConversation {
        return ChatConversation(
            chatId = "chat-1",
            chatType = FfiChatType.DM,
            title = "Recovered conversation",
            participantsLabel = "Alice",
            timelineLabel = "Now",
            isAccountSyncChat = false,
            canSend = true,
            canManageMembers = false,
            composerHint = "Send through the local MLS state already present on this device.",
            members = emptyList(),
            messages = emptyList(),
        )
    }
}
