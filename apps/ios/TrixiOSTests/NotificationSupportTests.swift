import XCTest
@testable import Trix

final class NotificationSupportTests: XCTestCase {
    func testMakeMessageNotificationPayloadsReturnsPayloadForForegroundDifferentChat() {
        let payloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5)],
            currentAccountId: "self-account",
            applicationIsActive: true,
            visibleChatID: "chat-2"
        )

        XCTAssertEqual(
            payloads,
            [
                MessageNotificationPayload(
                    identifier: "chat-chat-1-5",
                    title: "Chat chat-1: New message",
                    body: "Preview for chat-1"
                )
            ]
        )
    }

    func testMakeMessageNotificationPayloadsSuppressesForegroundVisibleChat() {
        let payloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5)],
            currentAccountId: "self-account",
            applicationIsActive: true,
            visibleChatID: "chat-1"
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func testMakeMessageNotificationPayloadsStillReturnsPayloadWhenAppIsBackgrounded() {
        let payloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5)],
            currentAccountId: "self-account",
            applicationIsActive: false,
            visibleChatID: "chat-1"
        )

        XCTAssertEqual(payloads.count, 1)
    }

    func testMakeMessageNotificationPayloadsSkipsOwnMessagesAndNonMessageChanges() {
        let ownMessagePayloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5, previewSenderAccountId: "self-account")],
            currentAccountId: "self-account",
            applicationIsActive: false,
            visibleChatID: nil
        )
        XCTAssertTrue(ownMessagePayloads.isEmpty)

        let unchangedPayloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5)],
            currentAccountId: "self-account",
            applicationIsActive: false,
            visibleChatID: nil
        )
        XCTAssertTrue(unchangedPayloads.isEmpty)
    }

    func testMakeMessageNotificationPayloadsSkipsLastServerSeqBumpsWithoutNewPreview() {
        let payloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 4, previewServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "chat-1", lastServerSeq: 5, previewServerSeq: 4)],
            currentAccountId: "self-account",
            applicationIsActive: false,
            visibleChatID: nil
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    func testMakeMessageNotificationPayloadsSkipsAccountSyncChats() {
        let payloads = makeMessageNotificationPayloads(
            previousItems: [makeChatListItem(chatId: "sync-chat", chatType: .accountSync, lastServerSeq: 4)],
            currentItems: [makeChatListItem(chatId: "sync-chat", chatType: .accountSync, lastServerSeq: 5)],
            currentAccountId: "self-account",
            applicationIsActive: false,
            visibleChatID: nil
        )

        XCTAssertTrue(payloads.isEmpty)
    }

    private func makeChatListItem(
        chatId: String,
        chatType: ChatType = .dm,
        lastServerSeq: UInt64,
        previewSenderAccountId: String? = "other-account",
        previewServerSeq: UInt64? = nil
    ) -> LocalChatListItemSnapshot {
        LocalChatListItemSnapshot(
            chatId: chatId,
            chatType: chatType,
            title: nil,
            displayTitle: "Chat \(chatId)",
            lastServerSeq: lastServerSeq,
            epoch: 1,
            pendingMessageCount: 0,
            unreadCount: 0,
            previewText: "Preview for \(chatId)",
            previewSenderAccountId: previewSenderAccountId,
            previewSenderDisplayName: "Other",
            previewIsOutgoing: false,
            previewServerSeq: previewServerSeq ?? lastServerSeq,
            previewCreatedAtUnix: 1,
            participantProfiles: []
        )
    }
}
