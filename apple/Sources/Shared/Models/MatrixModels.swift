import Foundation

struct MatrixSession: Codable, Equatable, Sendable {
    let userID: String
    let deviceID: String
    let homeserverURL: URL
    let accessToken: String
    let refreshToken: String?
    let oidcData: String?
    let sdkStoreID: String
    let createdAt: Date
}

struct MatrixAccount: Equatable, Sendable {
    let userID: String
    let displayName: String
    let deviceID: String
}

enum MatrixDeviceVerificationState: String, Codable, Sendable {
    case unknown
    case verified
    case unverified

    var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .verified:
            return "Verified"
        case .unverified:
            return "Unverified"
        }
    }
}

struct MatrixDeviceVerificationStatus: Equatable, Sendable {
    let userID: String
    let deviceID: String
    let state: MatrixDeviceVerificationState
    let hasDevicesToVerifyAgainst: Bool
    let isLastDevice: Bool
    let ed25519Fingerprint: String?
    let curve25519IdentityKey: String?
    let updatedAt: Date

    var needsUserConfirmation: Bool {
        state != .verified
    }

    var deviceAvailabilityLabel: String {
        if hasDevicesToVerifyAgainst {
            return "Existing device available"
        }

        return isLastDevice ? "Only device" : "No eligible device"
    }

    var explanation: String {
        switch state {
        case .verified:
            return "Matrix SDK reports this device as verified."
        case .unverified:
            if hasDevicesToVerifyAgainst {
                return "Confirm this device from an existing verified Matrix session before treating encrypted chats as production-ready."
            }

            return "This device is not verified yet, and the SDK did not find an eligible existing device to verify against."
        case .unknown:
            return "Matrix SDK has not reported a stable verification state for this device yet."
        }
    }
}

struct MatrixDeviceVerificationRequest: Identifiable, Equatable, Sendable {
    let flowID: String
    let senderUserID: String
    let senderDisplayName: String?
    let deviceID: String
    let deviceDisplayName: String?
    let firstSeenAt: Date

    var id: String {
        flowID
    }

    var senderLabel: String {
        if let senderDisplayName, !senderDisplayName.isEmpty {
            return senderDisplayName
        }

        return senderUserID
    }

    var deviceLabel: String {
        if let deviceDisplayName, !deviceDisplayName.isEmpty {
            return "\(deviceDisplayName) (\(deviceID))"
        }

        return deviceID
    }
}

struct MatrixDeviceVerificationEmoji: Identifiable, Equatable, Sendable {
    let symbol: String
    let description: String

    var id: String {
        "\(symbol)-\(description)"
    }
}

enum MatrixDeviceVerificationChallenge: Equatable, Sendable {
    case emojis([MatrixDeviceVerificationEmoji])
    case decimals([String])
}

enum MatrixDeviceVerificationFlowPhase: String, Codable, Sendable {
    case idle
    case requestSent
    case incomingRequest
    case accepted
    case sasStarted
    case challengeReceived
    case approved
    case finished
    case cancelled
    case failed

    var label: String {
        switch self {
        case .idle:
            return "No active verification"
        case .requestSent:
            return "Verification requested"
        case .incomingRequest:
            return "Incoming request"
        case .accepted:
            return "Request accepted"
        case .sasStarted:
            return "SAS verification started"
        case .challengeReceived:
            return "Compare verification codes"
        case .approved:
            return "Verification approved"
        case .finished:
            return "Verification complete"
        case .cancelled:
            return "Verification cancelled"
        case .failed:
            return "Verification failed"
        }
    }
}

struct MatrixDeviceVerificationFlow: Equatable, Sendable {
    let phase: MatrixDeviceVerificationFlowPhase
    let request: MatrixDeviceVerificationRequest?
    let challenge: MatrixDeviceVerificationChallenge?
    let updatedAt: Date

    static var idle: MatrixDeviceVerificationFlow {
        MatrixDeviceVerificationFlow(
            phase: .idle,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
    }

    var canRequestVerification: Bool {
        switch phase {
        case .idle, .cancelled, .failed:
            return true
        case .requestSent, .incomingRequest, .accepted, .sasStarted, .challengeReceived, .approved, .finished:
            return false
        }
    }

    var summary: String {
        switch phase {
        case .idle:
            return "Start verification from this device, or refresh after requesting it from another Matrix session."
        case .requestSent:
            return "Open an existing Matrix session and accept the verification request."
        case .incomingRequest:
            return "A Matrix session is asking to verify this device. Accept only if you initiated this."
        case .accepted:
            if request != nil {
                return "Waiting for the requesting device to start SAS verification."
            }

            return "Start SAS verification and compare the codes on both devices."
        case .sasStarted:
            return "Waiting for Matrix SDK to provide comparison codes."
        case .challengeReceived:
            return "Compare these codes with the other device before approving."
        case .approved:
            return "Codes approved. Waiting for Matrix SDK to finish verification."
        case .finished:
            return "Matrix SDK finished the verification flow. Refresh the device state."
        case .cancelled:
            return "The active verification flow was cancelled."
        case .failed:
            return "The active verification flow failed. Start a new request when ready."
        }
    }
}

enum MatrixRoomKind: String, Codable, Sendable {
    case direct
    case group
}

struct MatrixRoomSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: MatrixRoomKind
    let isEncrypted: Bool
    let unreadCount: Int
    let lastMessagePreview: String
    let lastActivityAt: Date

    var subtitle: String {
        switch kind {
        case .direct:
            return isEncrypted ? "Encrypted DM" : "DM"
        case .group:
            return isEncrypted ? "Encrypted group" : "Group"
        }
    }
}

struct MatrixRoomInvite: Identifiable, Equatable, Sendable {
    let id: String
    let roomName: String
    let kind: MatrixRoomKind
    let isEncrypted: Bool
    let inviterUserID: String?
    let inviterDisplayName: String?
    let receivedAt: Date

    var title: String {
        roomName.isEmpty ? id : roomName
    }

    var inviterLabel: String {
        if let inviterDisplayName, !inviterDisplayName.isEmpty {
            return inviterDisplayName
        }

        return inviterUserID ?? "Unknown inviter"
    }

    var subtitle: String {
        let roomType = kind == .direct ? "DM invite" : "Room invite"
        let encryption = isEncrypted ? "encrypted" : "unencrypted"
        return "\(roomType) from \(inviterLabel) - \(encryption)"
    }
}

struct MatrixTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let roomID: String
    let sender: String
    let timestamp: Date
    let body: String
    let isLocalEcho: Bool
}

enum MatrixClientError: LocalizedError {
    case invalidHomeserver
    case invalidCredentials
    case invalidMatrixUserID
    case emptyMessage
    case missingSession
    case roomUnavailable
    case inviteUnavailable
    case noEligibleDeviceForVerification
    case keychainFailure(String)
    case sdkAdapterUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHomeserver:
            return "The Matrix homeserver URL is invalid."
        case .invalidCredentials:
            return "Enter a Matrix user ID and password."
        case .invalidMatrixUserID:
            return "Enter a Matrix user ID on trix.selfhost.ru."
        case .emptyMessage:
            return "Enter a message before sending."
        case .missingSession:
            return "No saved Matrix session is available."
        case .roomUnavailable:
            return "The selected Matrix room is not available yet."
        case .inviteUnavailable:
            return "The Matrix invite is no longer available."
        case .noEligibleDeviceForVerification:
            return "No verified Matrix session is available to verify this device."
        case .keychainFailure(let detail):
            return "Keychain operation failed: \(detail)"
        case .sdkAdapterUnavailable:
            return "The Matrix SDK adapter is not wired yet."
        }
    }
}

extension Error {
    var matrixUserFacingMessage: String {
        if let localizedError = self as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return localizedDescription
    }
}
