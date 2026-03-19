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
