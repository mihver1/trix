import CryptoKit
import Foundation

enum TrixDevicePassportState: String, Codable, Sendable {
    case pending
    case approvalRequested = "approval_requested"
    case approved
    case revoked
    case resetRoot = "reset_root"

    var isReadOnly: Bool {
        switch self {
        case .pending, .approvalRequested, .revoked:
            return true
        case .approved, .resetRoot:
            return false
        }
    }

    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .approvalRequested:
            return "Waiting for approval"
        case .approved:
            return "Approved"
        case .revoked:
            return "Revoked"
        case .resetRoot:
            return "Reset root"
        }
    }
}

enum TrixDevicePassportApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case declined
    case expired
}

enum TrixDevicePassportClaimKind: String, Codable, Sendable {
    case approved
    case reset
    case revoked
}

enum TrixDevicePassportNoticeSeverity: String, Codable, Sendable {
    case normal
    case high
}

struct TrixDevicePassportCurrentDeviceRequest: Codable, Equatable, Sendable {
    let userID: String
    let omemoDeviceID: String
    let deviceLabel: String
    let platform: String
    let fingerprintHash: String
    let appVersion: String?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case omemoDeviceID = "omemo_device_id"
        case deviceLabel = "device_label"
        case platform
        case fingerprintHash = "fingerprint_hash"
        case appVersion = "app_version"
    }
}

struct TrixDevicePassportDevice: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    let deviceID: String
    let generation: Int
    let state: TrixDevicePassportState
    let deviceLabel: String
    let platform: String
    let fingerprintHash: String
    let appVersion: String?
    let firstSeenAtUnix: Int64
    let lastSeenAtUnix: Int64
    let approvedAtUnix: Int64?
    let approvedByDeviceID: String?
    let revokedAtUnix: Int64?

    var id: String {
        "\(userID.lowercased())|\(deviceID)"
    }

    var isCurrentDeviceReadOnly: Bool {
        state.isReadOnly
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case generation
        case state
        case deviceLabel = "device_label"
        case platform
        case fingerprintHash = "fingerprint_hash"
        case appVersion = "app_version"
        case firstSeenAtUnix = "first_seen_at_unix"
        case lastSeenAtUnix = "last_seen_at_unix"
        case approvedAtUnix = "approved_at_unix"
        case approvedByDeviceID = "approved_by_device_id"
        case revokedAtUnix = "revoked_at_unix"
    }
}

struct TrixDevicePassportApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let userID: String
    let deviceID: String
    let generation: Int
    let challenge: String
    let status: TrixDevicePassportApprovalStatus
    let createdAtUnix: Int64
    let expiresAtUnix: Int64
    let decidedAtUnix: Int64?
    let decidedByDeviceID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case deviceID = "device_id"
        case generation
        case challenge
        case status
        case createdAtUnix = "created_at_unix"
        case expiresAtUnix = "expires_at_unix"
        case decidedAtUnix = "decided_at_unix"
        case decidedByDeviceID = "decided_by_device_id"
    }
}

struct TrixDevicePassportDirectoryClaim: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let userID: String
    let deviceID: String
    let generation: Int
    let kind: TrixDevicePassportClaimKind
    let severity: TrixDevicePassportNoticeSeverity
    let fingerprintHash: String
    let proofRequired: Bool
    let createdAtUnix: Int64
    let approvedByDeviceID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case deviceID = "device_id"
        case generation
        case kind
        case severity
        case fingerprintHash = "fingerprint_hash"
        case proofRequired = "proof_required"
        case createdAtUnix = "created_at_unix"
        case approvedByDeviceID = "approved_by_device_id"
    }
}

struct TrixDevicePassportSnapshot: Codable, Equatable, Sendable {
    let userID: String
    let generation: Int
    let currentDevice: TrixDevicePassportDevice?
    let currentApprovalRequest: TrixDevicePassportApprovalRequest?
    let pendingApprovalRequests: [TrixDevicePassportApprovalRequest]
    let serverStateIsTrustAuthority: Bool

    var isCurrentDeviceReadOnly: Bool {
        currentDevice?.isCurrentDeviceReadOnly == true
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case generation
        case currentDevice = "current_device"
        case currentApprovalRequest = "current_approval_request"
        case pendingApprovalRequests = "pending_approval_requests"
        case serverStateIsTrustAuthority = "server_state_is_trust_authority"
    }
}

struct TrixDevicePassportApproveResult: Codable, Equatable, Sendable {
    let device: TrixDevicePassportDevice
    let claim: TrixDevicePassportDirectoryClaim
}

struct TrixDevicePassportDirectoryClaimsPage: Codable, Equatable, Sendable {
    let recipientUserID: String
    let claims: [TrixDevicePassportDirectoryClaim]
    let nextCursor: Int64

    private enum CodingKeys: String, CodingKey {
        case recipientUserID = "recipient_user_id"
        case claims
        case nextCursor = "next_cursor"
    }
}

struct TrixDevicePassportNotice: Identifiable, Equatable, Sendable {
    let userID: String
    let deviceLabel: String?
    let severity: TrixDevicePassportNoticeSeverity
    let claimID: Int64

    var id: String {
        "\(userID.lowercased())|\(severity.rawValue)"
    }

    var title: String {
        switch severity {
        case .normal:
            return "\(TrixUserIdentity.displayName(from: userID)) confirmed a new device"
        case .high:
            return "\(TrixUserIdentity.displayName(from: userID)) reset device trust"
        }
    }

    var message: String {
        switch severity {
        case .normal:
            return "Trix will use the confirmed device for encrypted messages after local OMEMO proof is verified."
        case .high:
            return "Review before sending sensitive messages. Operator reset is not treated like an ordinary new device."
        }
    }
}

struct TrixDevicePassportApprovalDescriptor: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.device-passport.approval.v1"

    let version: Int
    let claimID: Int64
    let userID: String
    let deviceID: String
    let generation: Int
    let fingerprintHash: String
    let approvedByDeviceID: String
    let createdAtUnix: Int64

    init(claim: TrixDevicePassportDirectoryClaim) throws {
        guard claim.kind == .approved,
              let approvedByDeviceID = claim.approvedByDeviceID,
              !approvedByDeviceID.isEmpty else {
            throw TrixClientError.devicePassportClaimUnverified
        }

        self.version = 1
        self.claimID = claim.id
        self.userID = claim.userID
        self.deviceID = claim.deviceID
        self.generation = claim.generation
        self.fingerprintHash = claim.fingerprintHash
        self.approvedByDeviceID = approvedByDeviceID
        self.createdAtUnix = claim.createdAtUnix
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case claimID = "claim_id"
        case userID = "user_id"
        case deviceID = "device_id"
        case generation
        case fingerprintHash = "fingerprint_hash"
        case approvedByDeviceID = "approved_by_device_id"
        case createdAtUnix = "created_at_unix"
    }
}

struct TrixReceivedDevicePassportDescriptor: Equatable, Sendable {
    let id: String
    let roomID: String
    let senderID: String
    let senderFingerprint: String?
    let timestamp: Date
    let descriptor: TrixDevicePassportApprovalDescriptor
    let isLocalEcho: Bool
}

struct TrixDevicePassportClaimProof: Equatable, Sendable {
    let userID: String
    let deviceID: String
    let generation: Int
    let approvedByDeviceID: String
    let approverFingerprintHash: String

    static func proof(
        for claim: TrixDevicePassportDirectoryClaim,
        descriptors: [TrixReceivedDevicePassportDescriptor]
    ) -> TrixDevicePassportClaimProof? {
        guard let approvedByDeviceID = claim.approvedByDeviceID else {
            return nil
        }
        let matching = descriptors
            .filter { item in
                let descriptor = item.descriptor
                return descriptor.claimID == claim.id &&
                    descriptor.userID.caseInsensitiveCompare(claim.userID) == .orderedSame &&
                    descriptor.deviceID == claim.deviceID &&
                    descriptor.generation == claim.generation &&
                    descriptor.fingerprintHash == claim.fingerprintHash &&
                    descriptor.approvedByDeviceID == approvedByDeviceID
            }
            .sorted { lhs, rhs in lhs.timestamp > rhs.timestamp }

        guard let received = matching.first,
              let senderFingerprint = received.senderFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !senderFingerprint.isEmpty else {
            return nil
        }

        return TrixDevicePassportClaimProof(
            userID: claim.userID,
            deviceID: claim.deviceID,
            generation: claim.generation,
            approvedByDeviceID: approvedByDeviceID,
            approverFingerprintHash: TrixDevicePassportFingerprint.hash(senderFingerprint)
        )
    }
}

enum TrixDevicePassportClaimDecision: Equatable, Sendable {
    case autoTrust
    case pendingFirstContact
    case proofRequired
    case fingerprintMismatch
    case ignored
}

enum TrixDevicePassportFingerprint {
    static func hash(_ fingerprint: String) -> String {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum TrixDevicePassportCurrentDeviceMetadata {
    static func request(
        session: TrixSession,
        status: TrixDeviceVerificationStatus,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ) throws -> TrixDevicePassportCurrentDeviceRequest {
        guard let fingerprint = status.ed25519Fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            throw TrixClientError.devicePassportUnavailable
        }
        let userID = try TrixUserIdentity.normalizedXMPPUserID(session.userID)

        return TrixDevicePassportCurrentDeviceRequest(
            userID: userID,
            omemoDeviceID: status.deviceID,
            deviceLabel: deviceLabel,
            platform: platform,
            fingerprintHash: TrixDevicePassportFingerprint.hash(fingerprint),
            appVersion: appVersion
        )
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    private static var deviceLabel: String {
        #if os(iOS)
        return "iPhone"
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Trix device"
        #endif
    }
}

enum TrixDevicePassportClaimProcessor {
    static func decision(
        for claim: TrixDevicePassportDirectoryClaim,
        proof: TrixDevicePassportClaimProof?,
        peerDevices: [TrixPeerDeviceIdentity]
    ) -> TrixDevicePassportClaimDecision {
        guard claim.kind == .approved else {
            return .ignored
        }
        guard let proof,
              proof.userID.caseInsensitiveCompare(claim.userID) == .orderedSame,
              proof.deviceID == claim.deviceID,
              proof.generation == claim.generation,
              let claimApproverDeviceID = claim.approvedByDeviceID,
              proof.approvedByDeviceID == claimApproverDeviceID else {
            return claim.proofRequired ? .proofRequired : .pendingFirstContact
        }
        guard let target = peerDevices.first(where: { $0.deviceID == claim.deviceID }) else {
            return .pendingFirstContact
        }
        guard TrixDevicePassportFingerprint.hash(target.fingerprint) == claim.fingerprintHash else {
            return .fingerprintMismatch
        }
        guard let approver = peerDevices.first(where: { $0.deviceID == claimApproverDeviceID }),
              approver.isActive,
              approver.canSendEncrypted,
              TrixDevicePassportFingerprint.hash(approver.fingerprint) == proof.approverFingerprintHash else {
            return .pendingFirstContact
        }
        let hasTrustedPriorDevice = peerDevices.contains { device in
            device.deviceID != claim.deviceID &&
                device.isActive &&
                device.canSendEncrypted &&
                device.deviceID == claimApproverDeviceID
        }
        return hasTrustedPriorDevice ? .autoTrust : .pendingFirstContact
    }

    static func apply(
        claim: TrixDevicePassportDirectoryClaim,
        proof: TrixDevicePassportClaimProof?,
        session: TrixSession,
        deviceService: TrixDeviceVerificationService
    ) async throws -> TrixDevicePassportClaimDecision {
        let devices = try await deviceService.refreshPeerDeviceIdentities(userID: claim.userID, session: session)
        let decision = decision(for: claim, proof: proof, peerDevices: devices)
        guard decision == .autoTrust else {
            return decision
        }
        _ = try await deviceService.trustPeerDevice(userID: claim.userID, deviceID: claim.deviceID, session: session)
        return decision
    }
}
