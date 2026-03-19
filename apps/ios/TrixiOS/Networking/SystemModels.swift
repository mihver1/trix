import Foundation

enum ServiceStatus: String, Decodable {
    case ok
    case degraded
}

enum DeviceStatus: String, Decodable {
    case pending
    case active
    case revoked
}

enum HistorySyncJobType: String, Decodable {
    case initialSync
    case chatBackfill
    case deviceRekey
}

enum HistorySyncJobStatus: String, Decodable {
    case pending
    case running
    case completed
    case failed
    case canceled
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
}

struct ApproveDeviceRequest: Encodable {
    let accountRootSignatureB64: String
}

struct ApproveDeviceResponse: Decodable {
    let accountId: String
    let deviceId: String
    let deviceStatus: DeviceStatus
}

struct PublishKeyPackageItem: Encodable {
    let cipherSuite: String
    let keyPackageB64: String
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
