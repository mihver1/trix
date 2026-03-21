import Foundation

enum ServiceStatus: String, Codable {
    case ok
    case degraded
}

struct HealthResponse: Codable {
    let service: String
    let status: ServiceStatus
    let version: String
    let uptimeMs: UInt64
}

struct VersionResponse: Codable {
    let service: String
    let version: String
    let gitSha: String?
}

struct CreateAccountRequest: Codable {
    let handle: String?
    let profileName: String
    let profileBio: String?
    let deviceDisplayName: String
    let platform: String
    let credentialIdentityB64: String
    let accountRootPubkeyB64: String
    let accountRootSignatureB64: String
    let transportPubkeyB64: String
}

struct CreateAccountResponse: Codable {
    let accountId: UUID
    let deviceId: UUID
    let accountSyncChatId: UUID
}

struct AuthChallengeRequest: Codable {
    let deviceId: UUID
}

struct AuthChallengeResponse: Codable {
    let challengeId: String
    let challengeB64: String
    let expiresAtUnix: UInt64
}

struct AuthSessionRequest: Codable {
    let deviceId: UUID
    let challengeId: String
    let signatureB64: String
}

struct AuthSessionResponse: Codable {
    let accessToken: String
    let expiresAtUnix: UInt64
    let accountId: UUID
    let deviceStatus: DeviceStatus
}

enum DeviceStatus: String, Codable {
    case pending
    case active
    case revoked

    var label: String {
        switch self {
        case .pending:
            "Pending"
        case .active:
            "Active"
        case .revoked:
            "Revoked"
        }
    }
}

struct AccountProfileResponse: Codable {
    let accountId: UUID
    let handle: String?
    let profileName: String
    let profileBio: String?
    let deviceId: UUID
    let deviceStatus: DeviceStatus
}

struct DirectoryAccountSummary: Codable, Identifiable, Hashable {
    let accountId: UUID
    let handle: String?
    let profileName: String
    let profileBio: String?

    var id: UUID { accountId }

    var primaryLabel: String {
        if let handle, !handle.isEmpty {
            return "@\(handle)"
        }

        return profileName
    }

    var secondaryLabel: String {
        if let handle, !handle.isEmpty {
            return profileName
        }

        return String(accountId.uuidString.prefix(8)).lowercased()
    }
}

struct AccountDirectoryResponse: Codable {
    let accounts: [DirectoryAccountSummary]
}

struct UpdateAccountProfileRequest: Codable {
    let handle: String?
    let profileName: String
    let profileBio: String?
}

struct DeviceListResponse: Codable {
    let accountId: UUID
    let devices: [DeviceSummary]
}

struct CreateLinkIntentResponse: Codable {
    let linkIntentId: UUID
    let qrPayload: String
    let expiresAtUnix: UInt64
}

struct CompleteLinkIntentRequest: Codable {
    let linkToken: String
    let deviceDisplayName: String
    let platform: String
    let credentialIdentityB64: String
    let transportPubkeyB64: String
    let keyPackages: [PublishKeyPackageItem]
}

struct CompleteLinkIntentResponse: Codable {
    let accountId: UUID
    let pendingDeviceId: UUID
    let deviceStatus: DeviceStatus
    let bootstrapPayloadB64: String
}

struct DeviceApprovePayloadResponse: Codable {
    let accountId: UUID
    let deviceId: UUID
    let deviceDisplayName: String
    let platform: String
    let deviceStatus: DeviceStatus
    let credentialIdentityB64: String
    let transportPubkeyB64: String
    let bootstrapPayloadB64: String
}

struct ApproveDeviceRequest: Codable {
    let accountRootSignatureB64: String
    let transferBundleB64: String?

    init(accountRootSignatureB64: String, transferBundleB64: String? = nil) {
        self.accountRootSignatureB64 = accountRootSignatureB64
        self.transferBundleB64 = transferBundleB64
    }
}

struct ApproveDeviceResponse: Codable {
    let accountId: UUID
    let deviceId: UUID
    let deviceStatus: DeviceStatus
}

struct RevokeDeviceRequest: Codable {
    let reason: String
    let accountRootSignatureB64: String
}

struct RevokeDeviceResponse: Codable {
    let accountId: UUID
    let deviceId: UUID
    let deviceStatus: DeviceStatus
}

struct PublishKeyPackageItem: Codable {
    let cipherSuite: String
    let keyPackageB64: String
}

struct PublishKeyPackagesRequest: Codable {
    let packages: [PublishKeyPackageItem]
}

struct PublishedKeyPackage: Codable, Identifiable {
    let keyPackageId: String
    let cipherSuite: String

    var id: String { keyPackageId }
}

struct PublishKeyPackagesResponse: Codable {
    let deviceId: UUID
    let packages: [PublishedKeyPackage]
}

struct ReserveKeyPackagesRequest: Codable {
    let accountId: UUID
    let deviceIds: [UUID]
}

struct ReservedKeyPackage: Codable, Identifiable {
    let keyPackageId: String
    let deviceId: UUID
    let cipherSuite: String
    let keyPackageB64: String

    var id: String { keyPackageId }
}

struct AccountKeyPackagesResponse: Codable {
    let accountId: UUID
    let packages: [ReservedKeyPackage]
}

struct ControlMessageInput: Codable {
    let messageId: UUID
    let ciphertextB64: String
    let aadJson: JSONValue?
}

struct DeviceSummary: Codable, Identifiable {
    let deviceId: UUID
    let displayName: String
    let platform: String
    let deviceStatus: DeviceStatus
    let availableKeyPackageCount: UInt32

    var id: UUID { deviceId }
}

struct LinkIntentPayload: Codable {
    let version: Int
    let baseURL: String
    let accountId: UUID
    let linkIntentId: UUID
    let linkToken: UUID

    enum CodingKeys: String, CodingKey {
        case version
        case baseURL = "base_url"
        case accountId = "account_id"
        case linkIntentId = "link_intent_id"
        case linkToken = "link_token"
    }
}

enum ChatType: String, Codable {
    case dm
    case group
    case accountSync = "account_sync"

    var label: String {
        switch self {
        case .dm:
            return "Direct Message"
        case .group:
            return "Group"
        case .accountSync:
            return "Account Sync"
        }
    }
}

struct CreateChatRequest: Codable {
    let chatType: ChatType
    let title: String?
    let participantAccountIds: [UUID]
    let reservedKeyPackageIds: [String]
    let initialCommit: ControlMessageInput?
    let welcomeMessage: ControlMessageInput?
}

struct CreateChatResponse: Codable {
    let chatId: UUID
    let chatType: ChatType
    let epoch: UInt64
}

struct CreateChatControlOutcome: Sendable {
    let chatId: UUID
    let chatType: ChatType
    let epoch: UInt64
    let mlsGroupId: Data
    let report: LocalStoreApplyReport
    let projectedMessages: [LocalProjectedMessage]
}

enum HistorySyncJobType: String, Codable {
    case initialSync = "initial_sync"
    case chatBackfill = "chat_backfill"
    case deviceRekey = "device_rekey"

    var label: String {
        switch self {
        case .initialSync:
            return "Initial Sync"
        case .chatBackfill:
            return "Chat Backfill"
        case .deviceRekey:
            return "Device Rekey"
        }
    }
}

enum HistorySyncJobStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case canceled

    var label: String {
        rawValue.capitalized
    }
}

struct ChatListResponse: Codable {
    let chats: [ChatSummary]
}

struct LocalStoreApplyReport: Sendable {
    let chatsUpserted: Int
    let messagesUpserted: Int
    let changedChatIDs: [UUID]
}

struct SyncChatCursor: Identifiable, Sendable {
    let chatId: UUID
    let lastServerSeq: UInt64

    var id: UUID { chatId }
}

struct SyncStateSnapshot: Sendable {
    let leaseOwner: String
    let lastAckedInboxId: UInt64?
    let chatCursors: [SyncChatCursor]
}

struct LocalHistorySyncResult: Sendable {
    let report: LocalStoreApplyReport
    let syncState: SyncStateSnapshot
    let chats: [ChatSummary]
}

struct LocalInboxPollResult: Sendable {
    let items: [InboxItem]
    let report: LocalStoreApplyReport
    let syncState: SyncStateSnapshot
    let chats: [ChatSummary]
}

struct LocalInboxLeaseResult: Sendable {
    let lease: LeaseInboxResponse
    let ackedInboxIds: [UInt64]
    let report: LocalStoreApplyReport
    let syncState: SyncStateSnapshot
    let chats: [ChatSummary]
}

struct LocalInboxAckResult: Sendable {
    let ackedInboxIds: [UInt64]
    let syncState: SyncStateSnapshot
}

struct LocalChatReadState: Identifiable, Sendable {
    let chatId: UUID
    let readCursorServerSeq: UInt64
    let unreadCount: UInt64

    var id: UUID { chatId }

    var hasUnread: Bool {
        unreadCount > 0
    }
}

struct LocalChatListItem: Identifiable, Sendable, Equatable {
    let chatId: UUID
    let chatType: ChatType
    let title: String?
    let displayTitle: String
    let lastServerSeq: UInt64
    let epoch: UInt64
    let pendingMessageCount: UInt64
    let unreadCount: UInt64
    let previewText: String?
    let previewSenderAccountId: UUID?
    let previewSenderDisplayName: String?
    let previewIsOutgoing: Bool?
    let previewServerSeq: UInt64?
    let previewCreatedAtUnix: UInt64?
    let participantProfiles: [ChatParticipantProfileSummary]

    var id: UUID { chatId }

    var previewCreatedAt: Date? {
        guard let previewCreatedAtUnix else {
            return nil
        }

        return Date(timeIntervalSince1970: TimeInterval(previewCreatedAtUnix))
    }

    var hasUnread: Bool {
        unreadCount > 0
    }

    func participantSubtitle(for currentAccountID: UUID?) -> String {
        chatSummary.subtitle(for: currentAccountID)
    }

    func sidebarPreview(for currentAccountID: UUID?) -> String {
        if let previewText = previewText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !previewText.isEmpty {
            if previewIsOutgoing == true {
                return "You: \(previewText)"
            }

            if let previewSenderDisplayName,
               !previewSenderDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               chatType != .dm {
                return "\(previewSenderDisplayName): \(previewText)"
            }

            return previewText
        }

        return participantSubtitle(for: currentAccountID)
    }

    private var chatSummary: ChatSummary {
        ChatSummary(
            chatId: chatId,
            chatType: chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: nil,
            participantProfiles: participantProfiles
        )
    }
}

struct ChatParticipantProfileSummary: Codable, Identifiable, Hashable {
    let accountId: UUID
    let handle: String?
    let profileName: String
    let profileBio: String?

    var id: UUID { accountId }

    var displayName: String {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        if let handle, !handle.isEmpty {
            return "@\(handle)"
        }

        return String(accountId.uuidString.prefix(8)).lowercased()
    }

    var handleLabel: String? {
        guard let handle, !handle.isEmpty else {
            return nil
        }

        return "@\(handle)"
    }

    var detailLine: String? {
        if let handleLabel {
            return handleLabel
        }

        guard let profileBio, !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return profileBio
    }
}

struct ChatDeviceSummary: Codable, Identifiable {
    let deviceId: UUID
    let accountId: UUID
    let displayName: String
    let platform: String
    let leafIndex: UInt32
    let credentialIdentityB64: String

    var id: UUID { deviceId }
}

struct ChatSummary: Codable, Identifiable {
    let chatId: UUID
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64
    let epoch: UInt64
    let pendingMessageCount: UInt64
    let lastMessage: MessageEnvelope?
    let participantProfiles: [ChatParticipantProfileSummary]

    var id: UUID { chatId }

    func displayTitle(for currentAccountID: UUID?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        switch chatType {
        case .dm:
            return primaryParticipant(for: currentAccountID)?.displayName ?? "Direct Message"
        case .group:
            let names = displayParticipantNames(excluding: currentAccountID, limit: 3)
            return names.isEmpty ? "Untitled Group" : names
        case .accountSync:
            return "Account Sync"
        }
    }

    func subtitle(for currentAccountID: UUID?) -> String {
        switch chatType {
        case .dm:
            return primaryParticipant(for: currentAccountID)?.detailLine ?? chatType.label
        case .group:
            let names = displayParticipantNames(excluding: currentAccountID, limit: 5)
            return names.isEmpty ? chatType.label : names
        case .accountSync:
            return chatType.label
        }
    }

    func primaryParticipant(for currentAccountID: UUID?) -> ChatParticipantProfileSummary? {
        participantProfiles.first { $0.accountId != currentAccountID } ?? participantProfiles.first
    }

    private func displayParticipantNames(excluding currentAccountID: UUID?, limit: Int) -> String {
        let participants = participantProfiles.filter { $0.accountId != currentAccountID }
        guard !participants.isEmpty else {
            return ""
        }

        let names = participants.prefix(limit).map(\.displayName)
        if participants.count > limit {
            return names.joined(separator: ", ") + " +\(participants.count - limit)"
        }

        return names.joined(separator: ", ")
    }
}

struct ChatDetailResponse: Codable {
    let chatId: UUID
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64
    let pendingMessageCount: UInt64
    let epoch: UInt64
    let lastCommitMessageId: UUID?
    let lastMessage: MessageEnvelope?
    let participantProfiles: [ChatParticipantProfileSummary]
    let members: [ChatMemberSummary]
    let deviceMembers: [ChatDeviceSummary]

    func displayTitle(for currentAccountID: UUID?) -> String {
        ChatSummary(
            chatId: chatId,
            chatType: chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: lastMessage,
            participantProfiles: participantProfiles
        )
        .displayTitle(for: currentAccountID)
    }

    func subtitle(for currentAccountID: UUID?) -> String {
        ChatSummary(
            chatId: chatId,
            chatType: chatType,
            title: title,
            lastServerSeq: lastServerSeq,
            epoch: epoch,
            pendingMessageCount: pendingMessageCount,
            lastMessage: lastMessage,
            participantProfiles: participantProfiles
        )
        .subtitle(for: currentAccountID)
    }
}

struct ChatMemberSummary: Codable, Identifiable {
    let accountId: UUID
    let role: String
    let membershipStatus: String

    var id: UUID { accountId }
}

enum MessageKind: String, Codable {
    case application
    case commit
    case welcomeRef = "welcome_ref"
    case system

    var label: String {
        switch self {
        case .application:
            return "Application"
        case .commit:
            return "Commit"
        case .welcomeRef:
            return "Welcome"
        case .system:
            return "System"
        }
    }
}

enum ContentType: String, Codable {
    case text
    case reaction
    case receipt
    case attachment
    case chatEvent = "chat_event"

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .reaction:
            return "Reaction"
        case .receipt:
            return "Receipt"
        case .attachment:
            return "Attachment"
        case .chatEvent:
            return "Chat Event"
        }
    }
}

enum LocalProjectionKind: String, Sendable {
    case applicationMessage = "application_message"
    case proposalQueued = "proposal_queued"
    case commitMerged = "commit_merged"
    case welcomeRef = "welcome_ref"
    case system

    var label: String {
        switch self {
        case .applicationMessage:
            return "Application"
        case .proposalQueued:
            return "Proposal"
        case .commitMerged:
            return "Commit"
        case .welcomeRef:
            return "Welcome"
        case .system:
            return "System"
        }
    }
}

enum TypedMessageBodyKind: String, Sendable {
    case text
    case reaction
    case receipt
    case attachment
    case chatEvent = "chat_event"

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .reaction:
            return "Reaction"
        case .receipt:
            return "Receipt"
        case .attachment:
            return "Attachment"
        case .chatEvent:
            return "Chat Event"
        }
    }
}

enum ReactionAction: String, Sendable {
    case add
    case remove

    var label: String {
        rawValue.capitalized
    }
}

enum ReceiptType: String, Sendable {
    case delivered
    case read

    var label: String {
        rawValue.capitalized
    }
}

struct TypedMessageBody: Sendable {
    let kind: TypedMessageBodyKind
    let text: String?
    let targetMessageId: UUID?
    let emoji: String?
    let reactionAction: ReactionAction?
    let receiptType: ReceiptType?
    let receiptAtUnix: UInt64?
    let blobId: String?
    let mimeType: String?
    let sizeBytes: UInt64?
    let sha256: Data?
    let fileName: String?
    let widthPx: UInt32?
    let heightPx: UInt32?
    let fileKey: Data?
    let nonce: Data?
    let eventType: String?
    let eventJson: String?

    var summary: String {
        switch kind {
        case .text:
            return text?.isEmpty == false ? text! : "Empty text"
        case .reaction:
            let emojiPart = emoji ?? "?"
            let targetPart = targetMessageId.map { String($0.uuidString.prefix(8)).lowercased() } ?? "unknown"
            let actionPart = reactionAction?.label.lowercased() ?? "update"
            return "\(emojiPart) \(actionPart) \(targetPart)"
        case .receipt:
            let targetPart = targetMessageId.map { String($0.uuidString.prefix(8)).lowercased() } ?? "unknown"
            return "\(receiptType?.label ?? "Receipt") for \(targetPart)"
        case .attachment:
            return fileName ?? blobId ?? (mimeType ?? "Attachment")
        case .chatEvent:
            return eventType ?? "Chat event"
        }
    }

    static func text(_ text: String) -> TypedMessageBody {
        TypedMessageBody(
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
    }
}

struct LocalProjectedMessage: Identifiable, Sendable {
    let serverSeq: UInt64
    let messageId: UUID
    let senderAccountId: UUID
    let senderDeviceId: UUID
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let projectionKind: LocalProjectionKind
    let payloadB64: String?
    let body: TypedMessageBody?
    let bodyParseError: String?
    let mergedEpoch: UInt64?
    let createdAtUnix: UInt64

    var id: UUID { messageId }

    var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }

    var senderShortID: String {
        String(senderAccountId.uuidString.prefix(8)).lowercased()
    }

    var payloadSizeBytes: Int {
        guard let payloadB64 else {
            return 0
        }

        return Data(base64Encoded: payloadB64)?.count ?? 0
    }
}

struct LocalTimelineItem: Identifiable, Sendable {
    let serverSeq: UInt64
    let messageId: UUID
    let senderAccountId: UUID
    let senderDeviceId: UUID
    let senderDisplayName: String
    let isOutgoing: Bool
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let projectionKind: LocalProjectionKind
    let body: TypedMessageBody?
    let bodyParseError: String?
    let previewText: String
    let mergedEpoch: UInt64?
    let createdAtUnix: UInt64

    var id: UUID { messageId }

    var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }

    var bodySummary: String {
        if let body {
            return body.summary
        }

        if let bodyParseError,
           !bodyParseError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bodyParseError
        }

        return previewText
    }
}

enum BlobUploadStatus: String, Sendable {
    case pending
    case uploaded
    case failed

    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .uploaded:
            return "Uploaded"
        case .failed:
            return "Failed"
        }
    }
}

struct UploadedAttachment: Sendable {
    let body: TypedMessageBody
    let blobId: String
    let uploadStatus: BlobUploadStatus
    let plaintextSizeBytes: UInt64
    let encryptedSizeBytes: UInt64
    let encryptedSha256: Data
}

struct DownloadedAttachment: Sendable {
    let body: TypedMessageBody
    let plaintext: Data
}

struct ModifyChatMembersControlOutcome: Sendable {
    let chatId: UUID
    let epoch: UInt64
    let changedParticipantAccountIDs: [UUID]
    let report: LocalStoreApplyReport
    let projectedMessages: [LocalProjectedMessage]
}

struct ModifyChatDevicesControlOutcome: Sendable {
    let chatId: UUID
    let epoch: UInt64
    let changedDeviceIDs: [UUID]
    let report: LocalStoreApplyReport
    let projectedMessages: [LocalProjectedMessage]
}

struct SendMessageOutcome: Sendable {
    let chatId: UUID
    let messageId: UUID
    let serverSeq: UInt64
    let report: LocalStoreApplyReport
    let projectedMessage: LocalProjectedMessage
}

struct AttachmentDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let mimeType: String
    let widthPx: UInt32?
    let heightPx: UInt32?
    let fileSizeBytes: UInt64

    init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        mimeType: String,
        widthPx: UInt32? = nil,
        heightPx: UInt32? = nil,
        fileSizeBytes: UInt64
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.fileSizeBytes = fileSizeBytes
    }

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}

enum PendingOutgoingPayload: Sendable, Equatable {
    case text(String)
    case attachment(AttachmentDraft)

    var summary: String {
        switch self {
        case let .text(text):
            return text
        case let .attachment(draft):
            return draft.fileName
        }
    }
}

enum PendingOutgoingStatus: String, Sendable {
    case sending
    case failed
}

struct PendingOutgoingMessage: Identifiable, Sendable {
    let id: UUID
    let chatId: UUID
    let createdAt: Date
    let payload: PendingOutgoingPayload
    var status: PendingOutgoingStatus
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        chatId: UUID,
        createdAt: Date = Date(),
        payload: PendingOutgoingPayload,
        status: PendingOutgoingStatus = .sending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.createdAt = createdAt
        self.payload = payload
        self.status = status
        self.errorMessage = errorMessage
    }
}

enum NotificationPermissionState: String, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var label: String {
        switch self {
        case .notDetermined:
            return "Not Requested"
        case .denied:
            return "Denied"
        case .authorized:
            return "Allowed"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        }
    }
}

struct NotificationPreferences: Sendable {
    var isEnabled: Bool = false
    var permissionState: NotificationPermissionState = .notDetermined
    var backgroundPollingIntervalSeconds: TimeInterval = 30
}

struct ChatHistoryResponse: Codable {
    let chatId: UUID
    let messages: [MessageEnvelope]
}

struct InboxItem: Codable, Identifiable {
    let inboxId: UInt64
    let message: MessageEnvelope

    var id: UInt64 { inboxId }
}

struct InboxResponse: Codable {
    let items: [InboxItem]
}

struct LeaseInboxRequest: Codable {
    let leaseOwner: String?
    let limit: Int?
    let afterInboxId: UInt64?
    let leaseTtlSeconds: UInt64?
}

struct LeaseInboxResponse: Codable {
    let leaseOwner: String
    let leaseExpiresAtUnix: UInt64
    let items: [InboxItem]

    var leaseExpiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(leaseExpiresAtUnix))
    }
}

struct AckInboxRequest: Codable {
    let inboxIds: [UInt64]
}

struct AckInboxResponse: Codable {
    let ackedInboxIds: [UInt64]
}

struct HistorySyncJobListResponse: Codable, Sendable {
    let jobs: [HistorySyncJobSummary]
}

struct HistorySyncJobSummary: Codable, Identifiable, Sendable {
    let jobId: UUID
    let jobType: HistorySyncJobType
    let jobStatus: HistorySyncJobStatus
    let sourceDeviceId: UUID
    let targetDeviceId: UUID
    let chatId: UUID?
    let cursorJson: JSONValue?
    let createdAtUnix: UInt64
    let updatedAtUnix: UInt64

    var id: UUID { jobId }

    var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }

    var updatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAtUnix))
    }

    var isCompletable: Bool {
        jobStatus == .pending || jobStatus == .running
    }
}

struct CompleteHistorySyncJobRequest: Codable, Sendable {
    let cursorJson: JSONValue?
}

struct CompleteHistorySyncJobResponse: Codable, Sendable {
    let jobId: UUID
    let jobStatus: HistorySyncJobStatus
}

struct MessageEnvelope: Codable, Identifiable {
    let messageId: UUID
    let chatId: UUID
    let serverSeq: UInt64
    let senderAccountId: UUID
    let senderDeviceId: UUID
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let ciphertextB64: String
    let aadJson: [String: JSONValue]
    let createdAtUnix: UInt64

    var id: UUID { messageId }

    var createdAt: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }

    var ciphertextSizeBytes: Int {
        Data(base64Encoded: ciphertextB64)?.count ?? 0
    }

    var senderShortID: String {
        String(senderAccountId.uuidString.prefix(8)).lowercased()
    }

    var aadSummary: String {
        aadJson.isEmpty ? "No AAD" : "\(aadJson.count) AAD field\(aadJson.count == 1 ? "" : "s")"
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
