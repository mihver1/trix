import Foundation

// MARK: - Session

struct AdminSessionRequest: Encodable, Sendable {
    var username: String
    var password: String
}

struct AdminSessionResponse: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAtUnix: UInt64
    var username: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAtUnix = "expires_at_unix"
        case username
    }
}

// MARK: - Overview

enum AdminServiceStatus: String, Codable, Sendable {
    case ok
    case degraded
}

struct AdminOverviewResponse: Codable, Equatable, Sendable {
    var status: String
    var service: String
    var version: String
    var gitSha: String?
    var healthStatus: AdminServiceStatus
    var uptimeMs: UInt64
    var allowPublicAccountRegistration: Bool
    var userCount: UInt64
    var disabledUserCount: UInt64
    var adminUsername: String
    var adminSessionExpiresAtUnix: UInt64
    var debugMetricsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case version
        case gitSha = "git_sha"
        case healthStatus = "health_status"
        case uptimeMs = "uptime_ms"
        case allowPublicAccountRegistration = "allow_public_account_registration"
        case userCount = "user_count"
        case disabledUserCount = "disabled_user_count"
        case adminUsername = "admin_username"
        case adminSessionExpiresAtUnix = "admin_session_expires_at_unix"
        case debugMetricsEnabled = "debug_metrics_enabled"
    }
}

// MARK: - Registration settings

struct AdminRegistrationSettingsResponse: Codable, Equatable, Sendable {
    var allowPublicAccountRegistration: Bool

    enum CodingKeys: String, CodingKey {
        case allowPublicAccountRegistration = "allow_public_account_registration"
    }
}

struct PatchAdminRegistrationSettingsRequest: Encodable, Sendable {
    var allowPublicAccountRegistration: Bool

    enum CodingKeys: String, CodingKey {
        case allowPublicAccountRegistration = "allow_public_account_registration"
    }
}

// MARK: - Server settings

struct AdminServerSettingsResponse: Codable, Equatable, Sendable {
    var brandDisplayName: String?
    var supportContact: String?
    var policyText: String?

    enum CodingKeys: String, CodingKey {
        case brandDisplayName = "brand_display_name"
        case supportContact = "support_contact"
        case policyText = "policy_text"
    }
}

/// Mirrors Rust `Option<Option<String>>`: omit = leave unchanged, `.some(nil)` = null, `.some(value)` = set.
enum AdminOptionalStringPatch: Equatable, Sendable {
    case unchanged
    case clear
    case set(String)
}

struct PatchAdminServerSettingsRequest: Encodable, Sendable {
    var brandDisplayName: AdminOptionalStringPatch
    var supportContact: AdminOptionalStringPatch
    var policyText: AdminOptionalStringPatch

    init(
        brandDisplayName: AdminOptionalStringPatch = .unchanged,
        supportContact: AdminOptionalStringPatch = .unchanged,
        policyText: AdminOptionalStringPatch = .unchanged
    ) {
        self.brandDisplayName = brandDisplayName
        self.supportContact = supportContact
        self.policyText = policyText
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodePatch(brandDisplayName, forKey: .brandDisplayName, to: &c)
        try encodePatch(supportContact, forKey: .supportContact, to: &c)
        try encodePatch(policyText, forKey: .policyText, to: &c)
    }

    enum CodingKeys: String, CodingKey {
        case brandDisplayName = "brand_display_name"
        case supportContact = "support_contact"
        case policyText = "policy_text"
    }

    private func encodePatch(
        _ patch: AdminOptionalStringPatch,
        forKey key: CodingKeys,
        to c: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch patch {
        case .unchanged:
            break
        case .clear:
            try c.encodeNil(forKey: key)
        case .set(let value):
            try c.encode(value, forKey: key)
        }
    }
}

// MARK: - Users

struct AdminUserSummary: Codable, Equatable, Identifiable, Sendable {
    var accountId: UUID
    var handle: String?
    var profileName: String
    var profileBio: String?
    var createdAtUnix: UInt64
    var disabled: Bool

    var id: UUID { accountId }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case handle
        case profileName = "profile_name"
        case profileBio = "profile_bio"
        case createdAtUnix = "created_at_unix"
        case disabled
    }
}

struct AdminUserListResponse: Codable, Equatable, Sendable {
    var users: [AdminUserSummary]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case users
        case nextCursor = "next_cursor"
    }
}

struct AdminDisableAccountRequest: Encodable, Sendable {
    var reason: String?

    init(reason: String? = nil) {
        self.reason = reason
    }
}

struct CreateAdminUserProvisionRequest: Encodable, Sendable {
    var handle: String?
    var profileName: String
    var profileBio: String?
    var ttlSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case handle
        case profileName = "profile_name"
        case profileBio = "profile_bio"
        case ttlSeconds = "ttl_seconds"
    }
}

struct CreateAdminUserProvisionResponse: Codable, Equatable, Sendable {
    var provisionId: String
    var provisionToken: String
    var expiresAtUnix: UInt64
    var profileName: String
    var handle: String?
    var profileBio: String?

    enum CodingKeys: String, CodingKey {
        case provisionId = "provision_id"
        case provisionToken = "provision_token"
        case expiresAtUnix = "expires_at_unix"
        case profileName = "profile_name"
        case handle
        case profileBio = "profile_bio"
    }
}

/// Onboarding artifact derived from `CreateAdminUserProvisionResponse` for operator UI.
struct AdminUserProvisioningArtifact: Equatable, Sendable {
    var provisionID: String
    var onboardingToken: String
    var onboardingURL: String
    var expiresAtUnix: UInt64
    var profileName: String
    var handle: String?
    var profileBio: String?

    static func fromProvisionResponse(_ r: CreateAdminUserProvisionResponse) -> AdminUserProvisioningArtifact {
        AdminUserProvisioningArtifact(
            provisionID: r.provisionId,
            onboardingToken: r.provisionToken,
            onboardingURL: "trix://provision/\(r.provisionToken)",
            expiresAtUnix: r.expiresAtUnix,
            profileName: r.profileName,
            handle: r.handle,
            profileBio: r.profileBio
        )
    }
}

enum AdminAPIError: Error, LocalizedError {
    case invalidURL
    case unexpectedStatus(Int, String?)
    case decodingFailed(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .unauthorized:
            return "Session expired or not authorized."
        case let .unexpectedStatus(code, body):
            return "Unexpected HTTP status \(code): \(body ?? "")"
        case let .decodingFailed(err):
            return "Failed to decode response: \(err.localizedDescription)"
        }
    }
}

// MARK: - Feature flags

enum AdminFeatureFlagScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case global
    case platform
    case account
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "Global"
        case .platform: return "Platform"
        case .account: return "Account"
        case .device: return "Device"
        }
    }
}

struct AdminFeatureFlagDefinition: Codable, Equatable, Identifiable, Sendable {
    var flagKey: String
    var description: String
    var defaultEnabled: Bool
    var deletedAtUnix: UInt64?
    var updatedAtUnix: UInt64

    var id: String { flagKey }

    enum CodingKeys: String, CodingKey {
        case flagKey = "flag_key"
        case description
        case defaultEnabled = "default_enabled"
        case deletedAtUnix = "deleted_at_unix"
        case updatedAtUnix = "updated_at_unix"
    }

    var isArchived: Bool { deletedAtUnix != nil }
}

struct AdminFeatureFlagDefinitionListResponse: Codable, Equatable, Sendable {
    var definitions: [AdminFeatureFlagDefinition]
}

struct CreateAdminFeatureFlagDefinitionRequest: Encodable, Sendable {
    var flagKey: String
    var description: String
    var defaultEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case flagKey = "flag_key"
        case description
        case defaultEnabled = "default_enabled"
    }
}

/// Mirrors Rust `Option<Option<u64>>`: omit = leave unchanged, `.clear` = null, `.set` = value.
enum AdminOptionalUInt64Patch: Equatable, Sendable {
    case unchanged
    case clear
    case set(UInt64)
}

struct PatchAdminFeatureFlagDefinitionRequest: Encodable, Sendable {
    var description: String?
    var defaultEnabled: Bool?
    var deletedAtUnix: AdminOptionalUInt64Patch

    init(
        description: String? = nil,
        defaultEnabled: Bool? = nil,
        deletedAtUnix: AdminOptionalUInt64Patch = .unchanged
    ) {
        self.description = description
        self.defaultEnabled = defaultEnabled
        self.deletedAtUnix = deletedAtUnix
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let description {
            try c.encode(description, forKey: .description)
        }
        if let defaultEnabled {
            try c.encode(defaultEnabled, forKey: .defaultEnabled)
        }
        switch deletedAtUnix {
        case .unchanged:
            break
        case .clear:
            try c.encodeNil(forKey: .deletedAtUnix)
        case .set(let v):
            try c.encode(v, forKey: .deletedAtUnix)
        }
    }

    enum CodingKeys: String, CodingKey {
        case description
        case defaultEnabled = "default_enabled"
        case deletedAtUnix = "deleted_at_unix"
    }
}

struct AdminFeatureFlagOverride: Codable, Equatable, Identifiable, Sendable {
    var overrideId: String
    var flagKey: String
    var scope: AdminFeatureFlagScope
    var platform: String?
    var accountId: UUID?
    var deviceId: UUID?
    var enabled: Bool
    var expiresAtUnix: UInt64?
    var updatedAtUnix: UInt64

    var id: String { overrideId }

    enum CodingKeys: String, CodingKey {
        case overrideId = "override_id"
        case flagKey = "flag_key"
        case scope
        case platform
        case accountId = "account_id"
        case deviceId = "device_id"
        case enabled
        case expiresAtUnix = "expires_at_unix"
        case updatedAtUnix = "updated_at_unix"
    }
}

struct AdminFeatureFlagOverrideListResponse: Codable, Equatable, Sendable {
    var overrides: [AdminFeatureFlagOverride]
}

struct CreateAdminFeatureFlagOverrideRequest: Encodable, Sendable {
    var flagKey: String
    var scope: AdminFeatureFlagScope
    var platform: String?
    var accountId: UUID?
    var deviceId: UUID?
    var enabled: Bool
    var expiresAtUnix: UInt64?

    enum CodingKeys: String, CodingKey {
        case flagKey = "flag_key"
        case scope
        case platform
        case accountId = "account_id"
        case deviceId = "device_id"
        case enabled
        case expiresAtUnix = "expires_at_unix"
    }
}

struct PatchAdminFeatureFlagOverrideRequest: Encodable, Sendable {
    var enabled: Bool?
    var expiresAtUnix: AdminOptionalUInt64Patch

    init(enabled: Bool? = nil, expiresAtUnix: AdminOptionalUInt64Patch = .unchanged) {
        self.enabled = enabled
        self.expiresAtUnix = expiresAtUnix
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let enabled {
            try c.encode(enabled, forKey: .enabled)
        }
        switch expiresAtUnix {
        case .unchanged:
            break
        case .clear:
            try c.encodeNil(forKey: .expiresAtUnix)
        case .set(let v):
            try c.encode(v, forKey: .expiresAtUnix)
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case expiresAtUnix = "expires_at_unix"
    }
}

// MARK: - Debug metrics

struct AdminDebugMetricSession: Codable, Equatable, Identifiable, Sendable {
    var sessionId: String
    var accountId: UUID
    var deviceId: UUID?
    var userVisibleMessage: String
    var createdAtUnix: UInt64
    var expiresAtUnix: UInt64
    var revokedAtUnix: UInt64?
    var createdByAdmin: String

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case accountId = "account_id"
        case deviceId = "device_id"
        case userVisibleMessage = "user_visible_message"
        case createdAtUnix = "created_at_unix"
        case expiresAtUnix = "expires_at_unix"
        case revokedAtUnix = "revoked_at_unix"
        case createdByAdmin = "created_by_admin"
    }

    var isRevoked: Bool { revokedAtUnix != nil }
}

struct AdminDebugMetricSessionResponse: Codable, Equatable, Sendable {
    var session: AdminDebugMetricSession
}

struct AdminDebugMetricSessionListResponse: Codable, Equatable, Sendable {
    var sessions: [AdminDebugMetricSession]
}

struct CreateAdminDebugMetricSessionRequest: Encodable, Sendable {
    var accountId: UUID
    var deviceId: UUID?
    var userVisibleMessage: String
    var ttlSeconds: UInt64

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case deviceId = "device_id"
        case userVisibleMessage = "user_visible_message"
        case ttlSeconds = "ttl_seconds"
    }
}

enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? c.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? c.decode([JSONValue].self) {
            self = .array(arr)
            return
        }
        if let dict = try? c.decode([String: JSONValue].self) {
            self = .object(dict)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case .bool(let b):
            try c.encode(b)
        case .int(let i):
            try c.encode(i)
        case .double(let d):
            try c.encode(d)
        case .string(let s):
            try c.encode(s)
        case .array(let a):
            try c.encode(a)
        case .object(let o):
            try c.encode(o)
        }
    }
}

extension JSONValue {
    func prettyPrinted(maxDepth: Int = 8, indent: Int = 0) -> String {
        guard maxDepth > 0 else { return "…" }
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .string(let s):
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        case .array(let arr):
            if arr.isEmpty { return "[]" }
            let inner = arr.map { $0.prettyPrinted(maxDepth: maxDepth - 1, indent: indent + 1) }
                .joined(separator: ",\n\(pad)  ")
            return "[\n\(pad)  \(inner)\n\(pad)]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let inner = dict.sorted(by: { $0.key < $1.key }).map { k, v in
                let vv = v.prettyPrinted(maxDepth: maxDepth - 1, indent: indent + 1)
                return "\"\(k)\": \(vv)"
            }.joined(separator: ",\n\(pad)  ")
            return "{\n\(pad)  \(inner)\n\(pad)}"
        }
    }
}

struct AdminDebugMetricBatch: Codable, Equatable, Identifiable, Sendable {
    var batchId: String
    var sessionId: String
    var deviceId: UUID
    var receivedAtUnix: UInt64
    var payload: JSONValue

    var id: String { batchId }

    enum CodingKeys: String, CodingKey {
        case batchId = "batch_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case receivedAtUnix = "received_at_unix"
        case payload
    }
}

struct AdminDebugMetricBatchListResponse: Codable, Equatable, Sendable {
    var batches: [AdminDebugMetricBatch]
}
