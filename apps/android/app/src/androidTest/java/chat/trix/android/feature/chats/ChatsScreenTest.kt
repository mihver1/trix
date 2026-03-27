package chat.trix.android.feature.chats

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import chat.trix.android.core.chat.ChatAttachment
import chat.trix.android.core.chat.ChatConversation
import chat.trix.android.core.chat.ChatConversationMember
import chat.trix.android.core.chat.ChatConversationSummary
import chat.trix.android.core.chat.ChatDiagnostics
import chat.trix.android.core.chat.ChatOverview
import chat.trix.android.core.chat.ChatTimelineMessage
import chat.trix.android.core.ffi.FfiChatType
import chat.trix.android.core.ffi.FfiContentType
import chat.trix.android.core.ffi.FfiMessageBody
import chat.trix.android.core.ffi.FfiMessageBodyKind
import chat.trix.android.designsystem.theme.TrixTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ChatsScreenTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun conversationListPaneShowsUnreadAndConversationMetadata() {
        composeRule.setContent {
            TrixTheme {
                ConversationListPaneForTesting(
                    overview = sampleOverview(),
                    selectedConversationId = "chat-group-1",
                )
            }
        }

        composeRule.onNodeWithText("Design review").assertIsDisplayed()
        composeRule.onNodeWithText("Alex, Sam +1").assertIsDisplayed()
        composeRule.onNodeWithText("3").assertIsDisplayed()
        composeRule.onNodeWithText("Queued attachment").assertIsDisplayed()
    }

    @Test
    fun conversationDetailPaneShowsQueuedAttachmentAndManageMembersActions() {
        var manageClicks = 0
        var openClicks = 0
        var shareClicks = 0

        composeRule.setContent {
            TrixTheme {
                ConversationDetailPaneForTesting(
                    conversation = sampleConversation(),
                    onManageMembers = { manageClicks += 1 },
                    onOpenAttachment = { openClicks += 1 },
                    onShareAttachment = { shareClicks += 1 },
                )
            }
        }

        composeRule.onNodeWithText("Group members").assertIsDisplayed()
        composeRule.onNodeWithText("Queued for delivery").assertIsDisplayed()
        composeRule.onNodeWithText("Manage members").performClick()
        composeRule.onNodeWithText("Open").performClick()
        composeRule.onNodeWithText("Share").performClick()

        assertEquals(1, manageClicks)
        assertEquals(1, openClicks)
        assertEquals(1, shareClicks)
    }

    @Test
    fun conversationDetailPaneHidesManageMembersWhenActionUnavailable() {
        composeRule.setContent {
            TrixTheme {
                ConversationDetailPaneForTesting(
                    conversation = sampleConversation(title = "Mobile group"),
                    onManageMembers = null,
                )
            }
        }

        composeRule.onNodeWithText("Mobile group").assertIsDisplayed()
        composeRule.onAllNodesWithText("Manage members").assertCountEquals(0)
        composeRule.onNodeWithText("Queued for delivery").assertIsDisplayed()
    }

    @Test
    fun newChatActionsShowDirectAndGroupButtons() {
        var directMessageClicks = 0
        var groupChatClicks = 0

        composeRule.setContent {
            TrixTheme {
                NewChatActionsForTesting(
                    onOpenDirectMessages = { directMessageClicks += 1 },
                    onOpenGroupChats = { groupChatClicks += 1 },
                )
            }
        }

        composeRule.onNodeWithContentDescription("Start direct message").performClick()
        composeRule.onNodeWithContentDescription("Create group chat").performClick()

        assertEquals(1, directMessageClicks)
        assertEquals(1, groupChatClicks)
    }

    private fun sampleOverview(): ChatOverview {
        return ChatOverview(
            conversations = listOf(
                ChatConversationSummary(
                    chatId = "chat-group-1",
                    chatType = FfiChatType.GROUP,
                    title = "Design review",
                    participantsLabel = "Alex, Sam +1",
                    lastMessagePreview = "Queued attachment",
                    timestampLabel = "10:42",
                    messageCount = 12,
                    unreadCount = 3,
                    hasProjectedTimeline = true,
                    isAccountSyncChat = false,
                ),
            ),
            diagnostics = ChatDiagnostics(
                cachedChatCount = 1,
                cachedMessageCount = 12,
                projectedChatCount = 1,
                pendingOutboxCount = 1,
                lastAckedInboxId = 24,
                leaseOwner = "lease-owner-1",
                historyStorePath = "/tmp/state-v1.db",
                syncStatePath = "/tmp/state-v1.db",
            ),
        )
    }

    private fun sampleConversation(
        title: String = "Group members",
    ): ChatConversation {
        return ChatConversation(
            chatId = "chat-group-1",
            chatType = FfiChatType.GROUP,
            title = title,
            participantsLabel = "Alex, Sam +1",
            timelineLabel = "Projected timeline + queued outbox",
            isAccountSyncChat = false,
            canSend = true,
            canManageMembers = true,
            composerHint = "Send through the local MLS state already present on this device.",
            members = listOf(
                ChatConversationMember(
                    accountId = "self-account",
                    displayName = "You",
                    role = "owner",
                    membershipStatus = "active",
                    isSelf = true,
                ),
                ChatConversationMember(
                    accountId = "member-1",
                    displayName = "Alex",
                    role = "participant",
                    membershipStatus = "active",
                    isSelf = false,
                ),
            ),
            messages = listOf(
                ChatTimelineMessage(
                    id = "message-1",
                    author = "You",
                    body = "roadmap.pdf",
                    timestampLabel = "10:42",
                    isMine = true,
                    note = "Queued for delivery",
                    contentType = FfiContentType.ATTACHMENT,
                    attachment = ChatAttachment(
                        messageId = "message-1",
                        blobId = "attachment-ref-1",
                        mimeType = "application/pdf",
                        fileName = "roadmap.pdf",
                        sizeBytes = 1024,
                        widthPx = null,
                        heightPx = null,
                        body = FfiMessageBody(
                            kind = FfiMessageBodyKind.ATTACHMENT,
                            text = null,
                            targetMessageId = null,
                            emoji = null,
                            reactionAction = null,
                            receiptType = null,
                            receiptAtUnix = null,
                            blobId = "attachment-ref-1",
                            mimeType = "application/pdf",
                            sizeBytes = 1024u,
                            sha256 = null,
                            fileName = "roadmap.pdf",
                            widthPx = null,
                            heightPx = null,
                            fileKey = null,
                            nonce = null,
                            eventType = null,
                            eventJson = null,
                        ),
                    ),
                ),
            ),
        )
    }
}
