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
