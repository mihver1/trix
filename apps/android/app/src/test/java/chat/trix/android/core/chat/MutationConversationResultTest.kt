package chat.trix.android.core.chat

import chat.trix.android.core.ffi.FfiChatType
import org.junit.Assert.assertEquals
import org.junit.Test

class MutationConversationResultTest {
    @Test
    fun sendResultStillBuildsWhenConversationRecoveryFallsBackBestEffort() {
        val overview = sampleOverview()
        val conversation = sampleConversation()
        var refreshAttempts = 0

        val result = buildMutationConversationResult(
            unavailableMessage = "Conversation chat-1 is no longer available",
            buildOverview = { overview },
            buildConversation = {
                recoverConversationProjectionBestEffort(
                    projectLocally = {
                        throw IllegalStateException("missing local projection")
                    },
                    repairHistoryLocally = {
                        throw AssertionError("local repair should not run after the first projection failure")
                    },
                    refreshFromServer = {
                        refreshAttempts += 1
                        throw IllegalStateException("network offline")
                    },
                )
                conversation
            },
            createResult = ::ChatSendResult,
        )

        assertEquals(ChatSendResult(overview, conversation), result)
        assertEquals(1, refreshAttempts)
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
