import Foundation

enum ServiceStatus: String, Codable {
    case ok
    case degraded
}

enum DeviceStatus: String, Codable {
    case pending
    case active
    case revoked
}

enum ChatType: String, Codable, CaseIterable {
    case dm
    case group
    case accountSync = "account_sync"
}

enum MessageKind: String, Codable {
    case application
    case commit
    case welcomeRef = "welcome_ref"
    case system
}

enum ContentType: String, Codable {
    case text
    case reaction
    case receipt
    case attachment
    case chatEvent = "chat_event"
}

enum HistorySyncJobType: String, Codable {
    case initialSync = "initial_sync"
    case chatBackfill = "chat_backfill"
    case deviceRekey = "device_rekey"
}

enum HistorySyncJobStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case canceled
}

enum JSONValue: Codable, Equatable {
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

    var prettyPrinted: String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case let .object(value):
            guard
                let data = try? JSONEncoder().encode(value),
                let string = String(data: data, encoding: .utf8)
            else {
                return "{...}"
            }
            return string
        case let .array(value):
            guard
                let data = try? JSONEncoder().encode(value),
                let string = String(data: data, encoding: .utf8)
            else {
                return "[...]"
            }
            return string
        case .null:
            return "null"
        }
    }
}

struct HealthResponse: Decodable, Equatable {
    let service: String
    let status: ServiceStatus
    let version: String
    let uptimeMs: UInt64
}

struct VersionResponse: Decodable, Equatable {
    let service: String
    let version: String
    let gitSha: String?
}

struct ServerSnapshot: Equatable {
    let health: HealthResponse
    let version: VersionResponse
}

struct CreateAccountRequest: Encodable {
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

struct CreateAccountResponse: Decodable {
    let accountId: String
    let deviceId: String
    let accountSyncChatId: String
}

struct AuthChallengeRequest: Encodable {
    let deviceId: String
}

struct AuthChallengeResponse: Decodable {
    let challengeId: String
    let challengeB64: String
    let expiresAtUnix: UInt64
}

struct AuthSessionRequest: Encodable {
    let deviceId: String
    let challengeId: String
    let signatureB64: String
}

struct AuthSessionResponse: Decodable {
    let accessToken: String
    let expiresAtUnix: UInt64
    let accountId: String
    let deviceStatus: DeviceStatus
}

struct AccountProfileResponse: Decodable {
    let accountId: String
    let handle: String?
    let profileName: String
    let profileBio: String?
    let deviceId: String
    let deviceStatus: DeviceStatus
}

struct DirectoryAccountSummary: Identifiable, Hashable {
    let accountId: String
    let handle: String?
    let profileName: String
    let profileBio: String?

    var id: String { accountId }
}

struct DeviceSummary: Decodable, Identifiable {
    let deviceId: String
    let displayName: String
    let platform: String
    let deviceStatus: DeviceStatus

    var id: String { deviceId }
}

struct DeviceListResponse: Decodable {
    let accountId: String
    let devices: [DeviceSummary]
}

struct CreateLinkIntentResponse: Decodable, Identifiable {
    let linkIntentId: String
    let qrPayload: String
    let expiresAtUnix: UInt64

    var id: String { linkIntentId }

    var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtUnix))
    }
}

struct LinkIntentPayload: Decodable {
    let version: Int
    let baseURL: String
    let accountId: String
    let linkIntentId: String
    let linkToken: String

    static func parse(_ rawPayload: String) throws -> LinkIntentPayload {
        let data = Data(rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LinkIntentPayload.self, from: data)
    }
}

struct CompleteLinkIntentRequest: Encodable {
    let linkToken: String
    let deviceDisplayName: String
    let platform: String
    let credentialIdentityB64: String
    let transportPubkeyB64: String
    let keyPackages: [PublishKeyPackageItem]
}

struct CompleteLinkIntentResponse: Decodable {
    let accountId: String
    let pendingDeviceId: String
    let deviceStatus: DeviceStatus
    let bootstrapPayloadB64: String
}

struct DeviceApprovePayloadResponse: Decodable {
    let accountId: String
    let deviceId: String
    let deviceDisplayName: String
    let platform: String
    let deviceStatus: DeviceStatus
    let credentialIdentityB64: String
    let transportPubkeyB64: String
    let bootstrapPayloadB64: String
}

struct ApproveDeviceRequest: Encodable {
    let accountRootSignatureB64: String
    let transferBundleB64: String?
}

struct ApproveDeviceResponse: Decodable {
    let accountId: String
    let deviceId: String
    let deviceStatus: DeviceStatus
}

struct DeviceTransferBundleResponse: Decodable {
    let accountId: String
    let deviceId: String
    let transferBundleB64: String
    let uploadedAtUnix: UInt64
}

struct PublishKeyPackageItem: Encodable {
    let cipherSuite: String
    let keyPackageB64: String
}

struct PublishKeyPackagesRequest: Encodable {
    let packages: [PublishKeyPackageItem]
}

struct PublishedKeyPackage: Decodable, Identifiable {
    let keyPackageId: String
    let cipherSuite: String

    var id: String { keyPackageId }
}

struct PublishKeyPackagesResponse: Decodable {
    let deviceId: String
    let packages: [PublishedKeyPackage]
}

struct ReserveKeyPackagesRequest: Encodable {
    let accountId: String
    let deviceIds: [String]
}

struct ReservedKeyPackage: Decodable, Identifiable {
    let keyPackageId: String
    let deviceId: String
    let cipherSuite: String
    let keyPackageB64: String

    var id: String { keyPackageId }
}

struct AccountKeyPackagesResponse: Decodable {
    let accountId: String
    let packages: [ReservedKeyPackage]
}

struct RevokeDeviceRequest: Encodable {
    let reason: String
    let accountRootSignatureB64: String
}

struct RevokeDeviceResponse: Decodable {
    let accountId: String
    let deviceId: String
    let deviceStatus: DeviceStatus
}

struct HistorySyncJobSummary: Decodable, Identifiable {
    let jobId: String
    let jobType: HistorySyncJobType
    let jobStatus: HistorySyncJobStatus
    let sourceDeviceId: String
    let targetDeviceId: String
    let chatId: String?
    let createdAtUnix: UInt64
    let updatedAtUnix: UInt64

    var id: String { jobId }
}

struct HistorySyncJobListResponse: Decodable {
    let jobs: [HistorySyncJobSummary]
}

struct CompleteHistorySyncJobRequest: Encodable {
    let cursorJson: String?
}

struct CompleteHistorySyncJobResponse: Decodable {
    let jobId: String
    let jobStatus: HistorySyncJobStatus
}

struct ChatSummary: Decodable, Identifiable {
    let chatId: String
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64
    let pendingMessageCount: UInt64
    let lastMessage: MessageEnvelope?
    let participantProfiles: [ChatParticipantProfileSummary]

    var id: String { chatId }
}

struct ChatListResponse: Decodable {
    let chats: [ChatSummary]
}

struct ChatMemberSummary: Decodable, Identifiable {
    let accountId: String
    let role: String
    let membershipStatus: String

    var id: String { accountId }
}

struct ChatParticipantProfileSummary: Decodable, Identifiable, Hashable {
    let accountId: String
    let handle: String?
    let profileName: String
    let profileBio: String?

    var id: String { accountId }
}

struct ChatDeviceSummary: Decodable, Identifiable {
    let deviceId: String
    let accountId: String
    let displayName: String
    let platform: String
    let leafIndex: UInt32
    let credentialIdentityB64: String

    var id: String { deviceId }
}

struct ChatDetailResponse: Decodable {
    let chatId: String
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64
    let pendingMessageCount: UInt64
    let epoch: UInt64
    let lastCommitMessageId: String?
    let lastMessage: MessageEnvelope?
    let participantProfiles: [ChatParticipantProfileSummary]
    let members: [ChatMemberSummary]
    let deviceMembers: [ChatDeviceSummary]
}

struct ControlMessageInput: Encodable {
    let messageId: String
    let ciphertextB64: String
    let aadJson: JSONValue?
}

struct CreateChatRequest: Encodable {
    let chatType: ChatType
    let title: String?
    let participantAccountIds: [String]
    let reservedKeyPackageIds: [String]
    let initialCommit: ControlMessageInput?
    let welcomeMessage: ControlMessageInput?
}

struct CreateChatResponse: Decodable {
    let chatId: String
    let chatType: ChatType
    let epoch: UInt64
}

struct ModifyChatMembersRequest: Encodable {
    let epoch: UInt64
    let participantAccountIds: [String]
    let reservedKeyPackageIds: [String]
    let commitMessage: ControlMessageInput?
    let welcomeMessage: ControlMessageInput?
}

struct ModifyChatMembersResponse: Decodable {
    let chatId: String
    let epoch: UInt64
    let changedAccountIds: [String]
}

struct ModifyChatDevicesRequest: Encodable {
    let epoch: UInt64
    let deviceIds: [String]
    let reservedKeyPackageIds: [String]
    let commitMessage: ControlMessageInput?
    let welcomeMessage: ControlMessageInput?
}

struct ModifyChatDevicesResponse: Decodable {
    let chatId: String
    let epoch: UInt64
    let changedDeviceIds: [String]
}

struct CreateMessageRequest: Encodable {
    let messageId: String
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let ciphertextB64: String
    let aadJson: JSONValue?
}

struct CreateMessageResponse: Decodable {
    let messageId: String
    let serverSeq: UInt64
}

struct MessageEnvelope: Decodable, Identifiable {
    let messageId: String
    let chatId: String
    let serverSeq: UInt64
    let senderAccountId: String
    let senderDeviceId: String
    let epoch: UInt64
    let messageKind: MessageKind
    let contentType: ContentType
    let ciphertextB64: String
    let aadJson: JSONValue
    let createdAtUnix: UInt64

    var id: String { messageId }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAtUnix))
    }
}

struct ChatHistoryResponse: Decodable {
    let chatId: String
    let messages: [MessageEnvelope]
}

struct InboxItem: Decodable, Identifiable {
    let inboxId: UInt64
    let message: MessageEnvelope

    var id: UInt64 { inboxId }
}

struct InboxResponse: Decodable {
    let items: [InboxItem]
}

struct LeaseInboxRequest: Encodable {
    let leaseOwner: String?
    let limit: Int?
    let afterInboxId: UInt64?
    let leaseTtlSeconds: UInt64?
}

struct LeaseInboxResponse: Decodable {
    let leaseOwner: String
    let leaseExpiresAtUnix: UInt64
    let items: [InboxItem]

    var leaseExpiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(leaseExpiresAtUnix))
    }
}

struct AckInboxRequest: Encodable {
    let inboxIds: [UInt64]
}

struct AckInboxResponse: Decodable {
    let ackedInboxIds: [UInt64]
}

extension ChatSummary {
    func resolvedTitle(currentAccountId: String?) -> String {
        ChatPresentationResolver.resolvedTitle(
            explicitTitle: title,
            chatType: chatType,
            participantProfiles: participantProfiles,
            currentAccountId: currentAccountId
        )
    }

    func avatarSeedTitle(currentAccountId: String?) -> String {
        ChatPresentationResolver.avatarSeedTitle(
            explicitTitle: title,
            chatType: chatType,
            participantProfiles: participantProfiles,
            currentAccountId: currentAccountId
        )
    }
}

extension ChatDetailResponse {
    func resolvedTitle(currentAccountId: String?) -> String {
        ChatPresentationResolver.resolvedTitle(
            explicitTitle: title,
            chatType: chatType,
            participantProfiles: participantProfiles,
            currentAccountId: currentAccountId
        )
    }

    func avatarSeedTitle(currentAccountId: String?) -> String {
        ChatPresentationResolver.avatarSeedTitle(
            explicitTitle: title,
            chatType: chatType,
            participantProfiles: participantProfiles,
            currentAccountId: currentAccountId
        )
    }

    func participantProfile(accountId: String) -> ChatParticipantProfileSummary? {
        participantProfiles.first { $0.accountId == accountId }
    }
}

private enum ChatPresentationResolver {
    static func resolvedTitle(
        explicitTitle: String?,
        chatType: ChatType,
        participantProfiles: [ChatParticipantProfileSummary],
        currentAccountId: String?
    ) -> String {
        if let explicitTitle = sanitized(explicitTitle) {
            return explicitTitle
        }

        switch chatType {
        case .dm:
            if let otherParticipant = otherParticipant(
                participantProfiles: participantProfiles,
                currentAccountId: currentAccountId
            ) {
                return otherParticipant.conversationTitle
            }
            return fallbackTitle(for: chatType)
        case .group:
            if let participantTitle = groupedParticipantTitle(
                participantProfiles: participantProfiles,
                currentAccountId: currentAccountId
            ) {
                return participantTitle
            }
            return fallbackTitle(for: chatType)
        case .accountSync:
            return fallbackTitle(for: chatType)
        }
    }

    static func avatarSeedTitle(
        explicitTitle: String?,
        chatType: ChatType,
        participantProfiles: [ChatParticipantProfileSummary],
        currentAccountId: String?
    ) -> String {
        if let explicitTitle = sanitized(explicitTitle) {
            return explicitTitle
        }

        if let otherParticipant = otherParticipant(
            participantProfiles: participantProfiles,
            currentAccountId: currentAccountId
        ) {
            return otherParticipant.avatarSeedTitle
        }

        if let firstNamedParticipant = participantProfiles.first {
            return firstNamedParticipant.avatarSeedTitle
        }

        return fallbackTitle(for: chatType)
    }

    private static func otherParticipant(
        participantProfiles: [ChatParticipantProfileSummary],
        currentAccountId: String?
    ) -> ChatParticipantProfileSummary? {
        if let currentAccountId {
            return participantProfiles.first { $0.accountId != currentAccountId } ?? participantProfiles.first
        }

        return participantProfiles.first
    }

    private static func groupedParticipantTitle(
        participantProfiles: [ChatParticipantProfileSummary],
        currentAccountId: String?
    ) -> String? {
        let visibleProfiles = participantProfiles.filter { profile in
            guard let currentAccountId else {
                return true
            }
            return participantProfiles.count <= 1 || profile.accountId != currentAccountId
        }

        let names = visibleProfiles.compactMap { sanitized($0.profileName) ?? sanitized($0.handle) }

        switch names.count {
        case 0:
            return nil
        case 1:
            return names[0]
        case 2:
            return "\(names[0]), \(names[1])"
        default:
            return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    private static func fallbackTitle(for chatType: ChatType) -> String {
        switch chatType {
        case .dm:
            return "Direct Message"
        case .group:
            return "Group"
        case .accountSync:
            return "Account Sync"
        }
    }

    fileprivate static func sanitized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ChatParticipantProfileSummary {
    var primaryDisplayName: String {
        ChatPresentationResolver.sanitized(profileName) ?? accountId
    }

    var handleDisplay: String? {
        ChatPresentationResolver.sanitized(handle).map { "@\($0)" }
    }

    var bioSummary: String? {
        ChatPresentationResolver.sanitized(profileBio)
    }

    var conversationTitle: String {
        handleDisplay ?? primaryDisplayName
    }

    var avatarSeedTitle: String {
        ChatPresentationResolver.sanitized(profileName)
            ?? ChatPresentationResolver.sanitized(handle)
            ?? accountId
    }
}
