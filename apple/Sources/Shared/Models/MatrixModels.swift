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
