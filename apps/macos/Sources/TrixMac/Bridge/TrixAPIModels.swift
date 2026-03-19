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

struct ErrorResponse: Codable {
    let code: String
    let message: String
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
}

struct ApproveDeviceRequest: Codable {
    let accountRootSignatureB64: String
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

struct DeviceSummary: Codable, Identifiable {
    let deviceId: UUID
    let displayName: String
    let platform: String
    let deviceStatus: DeviceStatus

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

struct DeviceApprovalPayload: Codable {
    let version: Int
    let baseURL: String
    let accountId: UUID
    let pendingDeviceId: UUID
    let deviceDisplayName: String
    let platform: String
    let credentialIdentityB64: String
    let transportPubkeyB64: String

    enum CodingKeys: String, CodingKey {
        case version
        case baseURL = "base_url"
        case accountId = "account_id"
        case pendingDeviceId = "pending_device_id"
        case deviceDisplayName = "device_display_name"
        case platform
        case credentialIdentityB64 = "credential_identity_b64"
        case transportPubkeyB64 = "transport_pubkey_b64"
    }
}

enum ChatType: String, Codable {
    case dm
    case group
    case accountSync = "account_sync"
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

struct ChatSummary: Codable, Identifiable {
    let chatId: UUID
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64

    var id: UUID { chatId }

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }

        switch chatType {
        case .dm:
            return "Direct Message"
        case .group:
            return "Untitled Group"
        case .accountSync:
            return "Account Sync"
        }
    }
}

struct ChatDetailResponse: Codable {
    let chatId: UUID
    let chatType: ChatType
    let title: String?
    let lastServerSeq: UInt64
    let epoch: UInt64
    let lastCommitMessageId: UUID?
    let members: [ChatMemberSummary]
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

struct ChatHistoryResponse: Codable {
    let chatId: UUID
    let messages: [MessageEnvelope]
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
