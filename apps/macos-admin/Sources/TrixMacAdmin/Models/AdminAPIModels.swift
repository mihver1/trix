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
