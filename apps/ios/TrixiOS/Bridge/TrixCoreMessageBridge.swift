import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum DebugMessageDraftKind: String, CaseIterable, Identifiable {
    case text
    case attachment
    case reaction
    case receipt
    case chatEvent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .attachment:
            return "Attachment"
        case .reaction:
            return "Reaction"
        case .receipt:
            return "Receipt"
        case .chatEvent:
            return "Event"
        }
    }

    var contentType: ContentType {
        switch self {
        case .text:
            return .text
        case .attachment:
            return .attachment
        case .reaction:
            return .reaction
        case .receipt:
            return .receipt
        case .chatEvent:
            return .chatEvent
        }
    }
}

enum DebugReactionAction: String, CaseIterable, Identifiable {
    case add
    case remove

    var id: String { rawValue }
}

enum DebugReceiptKind: String, CaseIterable, Identifiable {
    case delivered
    case read

    var id: String { rawValue }
}

struct DebugMessageDraft {
    var kind: DebugMessageDraftKind = .text
    var text = ""
    var targetMessageId = ""
    var emoji = "👍"
    var reactionAction: DebugReactionAction = .add
    var receiptKind: DebugReceiptKind = .delivered
    var receiptAtUnix = ""
    var eventType = ""
    var eventJSON = "{}"

    var canSubmit: Bool {
        switch kind {
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .attachment:
            return false
        case .reaction:
            return !targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .receipt:
            return !targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .chatEvent:
            return !eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !eventJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct MessageBodyPreview {
    let title: String
    let detail: String?
}

struct PreparedAttachmentUpload {
    let fileName: String?
    let mimeType: String
    let encryptedPayload: Data
    let sizeBytes: UInt64
    let sha256: Data
    let fileKey: Data
    let nonce: Data
}

enum TrixCoreMessageBridge {
    static func makeCreateMessageRequest(
        epoch: UInt64,
        draft: DebugMessageDraft
    ) throws -> CreateMessageRequest {
        let body = try messageBody(for: draft)
        let payload = try ffiSerializeMessageBody(body: body)

        return CreateMessageRequest(
            messageId: UUID().uuidString.lowercased(),
            epoch: epoch,
            messageKind: .application,
            contentType: draft.kind.contentType,
            ciphertextB64: payload.base64EncodedString(),
            aadJson: .object([
                "encoding": .string("trix_core_message_body_v1"),
                "source": .string("ios_poc")
            ])
        )
    }

    static func prepareAttachmentUpload(fileURL: URL) throws -> PreparedAttachmentUpload {
        let didAccessScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let plaintext = try Data(contentsOf: fileURL)
        let fileKey = try Data.trix_random(count: 32)
        let nonce = try Data.trix_random(count: 12)
        let symmetricKey = SymmetricKey(data: fileKey)
        let aesNonce = try AES.GCM.Nonce(data: nonce)

        // The server stores encrypted blobs; the descriptor carries the symmetric key material.
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: aesNonce)
        let encryptedPayload = sealedBox.ciphertext + sealedBox.tag
        let sha256 = Data(SHA256.hash(data: encryptedPayload))
        let fileName = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)

        return PreparedAttachmentUpload(
            fileName: fileName.isEmpty ? nil : fileName,
            mimeType: attachmentMimeType(for: fileURL),
            encryptedPayload: encryptedPayload,
            sizeBytes: UInt64(encryptedPayload.count),
            sha256: sha256,
            fileKey: fileKey,
            nonce: nonce
        )
    }

    static func makeAttachmentCreateMessageRequest(
        epoch: UInt64,
        blobId: String,
        preparedUpload: PreparedAttachmentUpload
    ) throws -> CreateMessageRequest {
        let body = FfiMessageBody(
            kind: .attachment,
            text: nil,
            targetMessageId: nil,
            emoji: nil,
            reactionAction: nil,
            receiptType: nil,
            receiptAtUnix: nil,
            blobId: blobId,
            mimeType: preparedUpload.mimeType,
            sizeBytes: preparedUpload.sizeBytes,
            sha256: preparedUpload.sha256,
            fileName: preparedUpload.fileName,
            widthPx: nil,
            heightPx: nil,
            fileKey: preparedUpload.fileKey,
            nonce: preparedUpload.nonce,
            eventType: nil,
            eventJson: nil
        )
        let payload = try ffiSerializeMessageBody(body: body)

        return CreateMessageRequest(
            messageId: UUID().uuidString.lowercased(),
            epoch: epoch,
            messageKind: .application,
            contentType: .attachment,
            ciphertextB64: payload.base64EncodedString(),
            aadJson: .object([
                "encoding": .string("trix_core_message_body_v1"),
                "source": .string("ios_attachment_poc"),
                "blob_id": .string(blobId)
            ])
        )
    }

    static func preview(for message: MessageEnvelope) -> MessageBodyPreview? {
        guard let payload = Data(base64Encoded: message.ciphertextB64) else {
            return nil
        }

        guard let parsedBody = try? ffiParseMessageBody(
            contentType: message.contentType.trix_ffiContentType,
            payload: payload
        ) else {
            return nil
        }

        return parsedBody.trix_preview
    }

    private static func messageBody(for draft: DebugMessageDraft) throws -> FfiMessageBody {
        switch draft.kind {
        case .text:
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidTextBody
            }

            return FfiMessageBody(
                kind: .text,
                text: text,
                targetMessageId: nil,
                emoji: nil,
                reactionAction: nil,
                receiptType: nil,
                receiptAtUnix: nil,
                blobId: nil,
                mimeType: nil,
                sizeBytes: nil,
                sha256: nil,
                fileName: nil,
                widthPx: nil,
                heightPx: nil,
                fileKey: nil,
                nonce: nil,
                eventType: nil,
                eventJson: nil
            )
        case .attachment:
            throw TrixCoreMessageBridgeError.attachmentRequiresUploadFlow
        case .reaction:
            let targetMessageId = draft.targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = draft.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetMessageId.isEmpty, !emoji.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidReactionBody
            }

            return FfiMessageBody(
                kind: .reaction,
                text: nil,
                targetMessageId: targetMessageId,
                emoji: emoji,
                reactionAction: draft.reactionAction.trix_ffiReactionAction,
                receiptType: nil,
                receiptAtUnix: nil,
                blobId: nil,
                mimeType: nil,
                sizeBytes: nil,
                sha256: nil,
                fileName: nil,
                widthPx: nil,
                heightPx: nil,
                fileKey: nil,
                nonce: nil,
                eventType: nil,
                eventJson: nil
            )
        case .receipt:
            let targetMessageId = draft.targetMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetMessageId.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidReceiptBody
            }

            let receiptAtUnix = draft.receiptAtUnix.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsedReceiptAtUnix: UInt64?
            if receiptAtUnix.isEmpty {
                parsedReceiptAtUnix = nil
            } else if let parsedValue = UInt64(receiptAtUnix) {
                parsedReceiptAtUnix = parsedValue
            } else {
                throw TrixCoreMessageBridgeError.invalidReceiptTimestamp
            }

            return FfiMessageBody(
                kind: .receipt,
                text: nil,
                targetMessageId: targetMessageId,
                emoji: nil,
                reactionAction: nil,
                receiptType: draft.receiptKind.trix_ffiReceiptType,
                receiptAtUnix: parsedReceiptAtUnix,
                blobId: nil,
                mimeType: nil,
                sizeBytes: nil,
                sha256: nil,
                fileName: nil,
                widthPx: nil,
                heightPx: nil,
                fileKey: nil,
                nonce: nil,
                eventType: nil,
                eventJson: nil
            )
        case .chatEvent:
            let eventType = draft.eventType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !eventType.isEmpty else {
                throw TrixCoreMessageBridgeError.invalidChatEventBody
            }

            return FfiMessageBody(
                kind: .chatEvent,
                text: nil,
                targetMessageId: nil,
                emoji: nil,
                reactionAction: nil,
                receiptType: nil,
                receiptAtUnix: nil,
                blobId: nil,
                mimeType: nil,
                sizeBytes: nil,
                sha256: nil,
                fileName: nil,
                widthPx: nil,
                heightPx: nil,
                fileKey: nil,
                nonce: nil,
                eventType: eventType,
                eventJson: try canonicalizeJSON(draft.eventJSON)
            )
        }
    }

    private static func canonicalizeJSON(_ rawJSON: String) throws -> String {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw TrixCoreMessageBridgeError.invalidChatEventJSON
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw TrixCoreMessageBridgeError.invalidChatEventJSON
        }

        let normalizedData = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: normalizedData, as: UTF8.self)
    }

    private static func attachmentMimeType(for fileURL: URL) -> String {
        if let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let preferredMIMEType = contentType.preferredMIMEType {
            return preferredMIMEType
        }

        let fileExtension = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileExtension.isEmpty,
           let preferredMIMEType = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            return preferredMIMEType
        }

        return "application/octet-stream"
    }
}

private enum TrixCoreMessageBridgeError: LocalizedError {
    case invalidTextBody
    case attachmentRequiresUploadFlow
    case invalidReactionBody
    case invalidReceiptBody
    case invalidReceiptTimestamp
    case invalidChatEventBody
    case invalidChatEventJSON

    var errorDescription: String? {
        switch self {
        case .invalidTextBody:
            return "Text messages must not be empty."
        case .attachmentRequiresUploadFlow:
            return "Attachment messages must be sent through the attachment upload flow."
        case .invalidReactionBody:
            return "Reaction messages require both target message ID and emoji."
        case .invalidReceiptBody:
            return "Receipt messages require a target message ID."
        case .invalidReceiptTimestamp:
            return "Receipt timestamp must be a valid Unix timestamp."
        case .invalidChatEventBody:
            return "Chat events require an event type."
        case .invalidChatEventJSON:
            return "Chat event payload must be valid JSON."
        }
    }
}

private extension DebugReactionAction {
    var trix_ffiReactionAction: FfiReactionAction {
        switch self {
        case .add:
            return .add
        case .remove:
            return .remove
        }
    }
}

private extension DebugReceiptKind {
    var trix_ffiReceiptType: FfiReceiptType {
        switch self {
        case .delivered:
            return .delivered
        case .read:
            return .read
        }
    }
}

private extension ContentType {
    var trix_ffiContentType: FfiContentType {
        switch self {
        case .text:
            return .text
        case .reaction:
            return .reaction
        case .receipt:
            return .receipt
        case .attachment:
            return .attachment
        case .chatEvent:
            return .chatEvent
        }
    }
}

private extension FfiMessageBody {
    var trix_preview: MessageBodyPreview {
        switch kind {
        case .text:
            return MessageBodyPreview(
                title: text ?? "(empty text)",
                detail: nil
            )
        case .reaction:
            let actionLabel = reactionAction == .remove ? "Removed" : "Reacted"
            return MessageBodyPreview(
                title: "\(actionLabel) \(emoji ?? "")",
                detail: targetMessageId.map { "Target \($0)" }
            )
        case .receipt:
            let receiptLabel = receiptType == .read ? "Read receipt" : "Delivered receipt"
            return MessageBodyPreview(
                title: receiptLabel,
                detail: targetMessageId.map { "Target \($0)" }
            )
        case .attachment:
            let attachmentName = fileName ?? blobId ?? "Attachment"
            let mimeDescription = mimeType ?? "binary/octet-stream"
            return MessageBodyPreview(
                title: attachmentName,
                detail: "\(mimeDescription), \(sizeBytes ?? 0) bytes"
            )
        case .chatEvent:
            return MessageBodyPreview(
                title: eventType ?? "Chat event",
                detail: eventJson
            )
        }
    }
}
