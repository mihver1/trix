import Foundation
import XCTest
@testable import Trix

final class TrixCoreMessageBridgeTests: XCTestCase {
    func testTextDraftProducesTrimmedTextBody() throws {
        var draft = DebugMessageDraft()
        draft.kind = .text
        draft.text = "  hello from ios  "

        let body = try TrixCoreMessageBridge.messageBody(for: draft)

        XCTAssertEqual(body.kind, .text)
        XCTAssertEqual(body.text, "hello from ios")
    }

    func testReceiptDraftRejectsInvalidUnixTimestamp() {
        var draft = DebugMessageDraft()
        draft.kind = .receipt
        draft.targetMessageId = "message-1"
        draft.receiptAtUnix = "not-a-timestamp"

        XCTAssertThrowsError(try TrixCoreMessageBridge.messageBody(for: draft)) { error in
            XCTAssertEqual(error as? TrixCoreMessageBridgeError, .invalidReceiptTimestamp)
        }
    }

    func testChatEventCanonicalizesJSONPayload() throws {
        var draft = DebugMessageDraft()
        draft.kind = .chatEvent
        draft.eventType = "chat.renamed"
        draft.eventJSON = """
        {
          "title": "Project Atlas",
          "metadata": {
            "pinned": true,
            "members": 3
          }
        }
        """

        let body = try TrixCoreMessageBridge.messageBody(for: draft)
        let eventJSON = try XCTUnwrap(body.eventJson)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(eventJSON.utf8))

        XCTAssertEqual(body.kind, .chatEvent)
        XCTAssertEqual(body.eventType, "chat.renamed")
        XCTAssertEqual(
            decoded,
            .object([
                "title": .string("Project Atlas"),
                "metadata": .object([
                    "pinned": .bool(true),
                    "members": .number(3),
                ]),
            ])
        )
    }

    func testCreateMessageRequestProducesParsableCiphertextAndAAD() throws {
        var draft = DebugMessageDraft()
        draft.kind = .text
        draft.text = "Smoke test"

        let request = try TrixCoreMessageBridge.makeCreateMessageRequest(
            epoch: 42,
            draft: draft
        )
        let ciphertext = try XCTUnwrap(Data(base64Encoded: request.ciphertextB64))
        let parsed = try ffiParseMessageBody(contentType: .text, payload: ciphertext)

        XCTAssertEqual(request.epoch, 42)
        XCTAssertEqual(request.messageKind, .application)
        XCTAssertEqual(request.contentType, .text)
        XCTAssertEqual(parsed.kind, .text)
        XCTAssertEqual(parsed.text, "Smoke test")

        guard case let .object(aad)? = request.aadJson else {
            return XCTFail("Expected object AAD")
        }
        XCTAssertEqual(aad["encoding"], .string("trix_core_message_body_v1"))
        XCTAssertEqual(aad["source"], .string("ios_poc"))
    }

    func testSuggestedAttachmentFileNameFallsBackToBlobIDAndMimeExtension() {
        let body = FfiMessageBody(
            kind: .attachment,
            text: nil,
            targetMessageId: nil,
            emoji: nil,
            reactionAction: nil,
            receiptType: nil,
            receiptAtUnix: nil,
            blobId: "blob-123",
            mimeType: "image/png",
            sizeBytes: 128,
            sha256: nil,
            fileName: "   ",
            widthPx: nil,
            heightPx: nil,
            fileKey: nil,
            nonce: nil,
            eventType: nil,
            eventJson: nil
        )

        XCTAssertEqual(
            TrixCoreMessageBridge.suggestedAttachmentFileName(for: body),
            "blob-123.png"
        )
    }

    func testSuggestedAttachmentFileNameSanitizesPathComponents() {
        let body = FfiMessageBody(
            kind: .attachment,
            text: nil,
            targetMessageId: nil,
            emoji: nil,
            reactionAction: nil,
            receiptType: nil,
            receiptAtUnix: nil,
            blobId: "blob-456",
            mimeType: "application/pdf",
            sizeBytes: 256,
            sha256: nil,
            fileName: "../exports/report.pdf",
            widthPx: nil,
            heightPx: nil,
            fileKey: nil,
            nonce: nil,
            eventType: nil,
            eventJson: nil
        )

        XCTAssertEqual(
            TrixCoreMessageBridge.suggestedAttachmentFileName(for: body),
            "report.pdf"
        )
    }
}

final class ConsumerConversationTimelineBuilderTests: XCTestCase {
    func testBuilderFoldsReceiptsIntoMessageStatusAndPreservesClusters() {
        let snapshot = makeSnapshot(
            messages: [
                makeTextMessage(
                    id: "message-1",
                    senderAccountId: "bob",
                    senderDeviceId: "bob-phone",
                    senderDisplayName: "Bob",
                    isOutgoing: false,
                    text: "Hey there",
                    serverSeq: 1,
                    createdAtUnix: 1_700_000_000
                ),
                makeReceiptMessage(
                    id: "receipt-1",
                    senderAccountId: "alice",
                    senderDeviceId: "alice-phone",
                    senderDisplayName: "Alice",
                    isOutgoing: true,
                    targetMessageId: "message-1",
                    receiptType: .read,
                    serverSeq: 2,
                    createdAtUnix: 1_700_000_001
                ),
                makeTextMessage(
                    id: "message-2",
                    senderAccountId: "bob",
                    senderDeviceId: "bob-phone",
                    senderDisplayName: "Bob",
                    isOutgoing: false,
                    text: "You there?",
                    serverSeq: 3,
                    createdAtUnix: 1_700_000_002
                ),
            ]
        )

        let renderPayload = ConsumerConversationTimelineBuilder.makeRenderPayload(
            for: snapshot,
            fixtureManifest: nil
        )
        let items = renderPayload.items

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(renderPayload.fixtureKindsByMessageId.isEmpty)

        guard case .daySeparator = items[0] else {
            return XCTFail("Expected the first timeline item to be a day separator")
        }

        guard case let .message(firstMessage) = items[1] else {
            return XCTFail("Expected the first rendered item to be a message")
        }
        XCTAssertEqual(firstMessage.id, "message-1")
        XCTAssertEqual(firstMessage.primaryText, "Hey there")
        XCTAssertEqual(firstMessage.senderName, "Bob")
        XCTAssertEqual(firstMessage.clusterPosition, ConsumerMessageClusterPosition.top)
        XCTAssertEqual(firstMessage.receiptStatus, ConsumerReceiptStatus.read)

        guard case let .message(secondMessage) = items[2] else {
            return XCTFail("Expected the second rendered item to be a message")
        }
        XCTAssertEqual(secondMessage.id, "message-2")
        XCTAssertEqual(secondMessage.primaryText, "You there?")
        XCTAssertNil(secondMessage.senderName)
        XCTAssertEqual(secondMessage.clusterPosition, ConsumerMessageClusterPosition.bottom)
    }

    func testLatestIncomingNonReceiptMessageIDSkipsOwnMessagesAndReceipts() {
        let snapshot = makeSnapshot(
            messages: [
                makeTextMessage(
                    id: "incoming-text",
                    senderAccountId: "bob",
                    senderDeviceId: "bob-phone",
                    senderDisplayName: "Bob",
                    isOutgoing: false,
                    text: "Latest incoming",
                    serverSeq: 1,
                    createdAtUnix: 1_700_000_000
                ),
                makeTextMessage(
                    id: "own-text",
                    senderAccountId: "alice",
                    senderDeviceId: "alice-phone",
                    senderDisplayName: "Alice",
                    isOutgoing: true,
                    text: "Reply",
                    serverSeq: 2,
                    createdAtUnix: 1_700_000_001
                ),
                makeReceiptMessage(
                    id: "incoming-receipt",
                    senderAccountId: "bob",
                    senderDeviceId: "bob-phone",
                    senderDisplayName: "Bob",
                    isOutgoing: false,
                    targetMessageId: "own-text",
                    receiptType: .read,
                    serverSeq: 3,
                    createdAtUnix: 1_700_000_002
                ),
            ]
        )

        XCTAssertEqual(
            ConsumerConversationTimelineBuilder.latestIncomingNonReceiptMessageID(
                in: snapshot,
                currentAccountId: "alice"
            ),
            "incoming-text"
        )
    }

    func testTimelineRenderStateEqualityTracksTimelineSpecificInputs() {
        let snapshot = makeSnapshot(
            messages: [
                makeTextMessage(
                    id: "message-1",
                    senderAccountId: "bob",
                    senderDeviceId: "bob-phone",
                    senderDisplayName: "Bob",
                    isOutgoing: false,
                    text: "Hey there",
                    serverSeq: 1,
                    createdAtUnix: 1_700_000_000
                ),
            ]
        )
        let renderPayload = ConsumerConversationTimelineBuilder.makeRenderPayload(
            for: snapshot,
            fixtureManifest: nil
        )
        let items = renderPayload.items
        let baseline = ConsumerConversationTimelineRenderState(
            latestTimelineAnchorId: "message-1",
            timelineItems: items,
            fixtureKindsByMessageId: renderPayload.fixtureKindsByMessageId,
            latestSentMessageId: nil,
            latestSentText: nil,
            downloadingAttachmentMessageId: nil
        )
        let sameInputs = ConsumerConversationTimelineRenderState(
            latestTimelineAnchorId: "message-1",
            timelineItems: items,
            fixtureKindsByMessageId: renderPayload.fixtureKindsByMessageId,
            latestSentMessageId: nil,
            latestSentText: nil,
            downloadingAttachmentMessageId: nil
        )
        let changedInputs = ConsumerConversationTimelineRenderState(
            latestTimelineAnchorId: "message-1",
            timelineItems: items,
            fixtureKindsByMessageId: renderPayload.fixtureKindsByMessageId,
            latestSentMessageId: nil,
            latestSentText: "different",
            downloadingAttachmentMessageId: nil
        )

        XCTAssertEqual(baseline, sameInputs)
        XCTAssertNotEqual(baseline, changedInputs)
    }

    private func makeSnapshot(messages: [SafeMessengerMessage]) -> SafeConversationSnapshot {
        SafeConversationSnapshot(
            detail: ChatDetailResponse(
                chatId: "chat-1",
                chatType: .group,
                title: "Test Chat",
                lastServerSeq: messages.last?.serverSeq ?? 0,
                pendingMessageCount: 0,
                epoch: 1,
                lastCommitMessageId: nil,
                lastMessage: nil,
                participantProfiles: [
                    ChatParticipantProfileSummary(
                        accountId: "alice",
                        handle: "alice",
                        profileName: "Alice",
                        profileBio: nil
                    ),
                    ChatParticipantProfileSummary(
                        accountId: "bob",
                        handle: "bob",
                        profileName: "Bob",
                        profileBio: nil
                    ),
                ],
                members: [],
                deviceMembers: []
            ),
            messages: messages,
            nextCursor: nil
        )
    }

    private func makeTextMessage(
        id: String,
        senderAccountId: String,
        senderDeviceId: String,
        senderDisplayName: String,
        isOutgoing: Bool,
        text: String,
        serverSeq: UInt64,
        createdAtUnix: UInt64
    ) -> SafeMessengerMessage {
        SafeMessengerMessage(
            conversationId: "chat-1",
            serverSeq: serverSeq,
            messageId: id,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            contentType: .text,
            body: SafeMessengerMessageBody(
                kind: .text,
                text: text,
                targetMessageId: nil,
                emoji: nil,
                reactionAction: nil,
                receiptType: nil,
                receiptAtUnix: nil,
                attachment: nil,
                eventType: nil,
                eventJSON: nil
            ),
            previewText: text,
            createdAtUnix: createdAtUnix
        )
    }

    private func makeReceiptMessage(
        id: String,
        senderAccountId: String,
        senderDeviceId: String,
        senderDisplayName: String,
        isOutgoing: Bool,
        targetMessageId: String,
        receiptType: SafeMessengerReceiptType,
        serverSeq: UInt64,
        createdAtUnix: UInt64
    ) -> SafeMessengerMessage {
        SafeMessengerMessage(
            conversationId: "chat-1",
            serverSeq: serverSeq,
            messageId: id,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            contentType: .receipt,
            body: SafeMessengerMessageBody(
                kind: .receipt,
                text: nil,
                targetMessageId: targetMessageId,
                emoji: nil,
                reactionAction: nil,
                receiptType: receiptType,
                receiptAtUnix: createdAtUnix,
                attachment: nil,
                eventType: nil,
                eventJSON: nil
            ),
            previewText: "Receipt",
            createdAtUnix: createdAtUnix
        )
    }
}
