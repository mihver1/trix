import Foundation
import CoreGraphics
import ImageIO

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

struct MatrixUserProfile: Identifiable, Equatable, Sendable {
    let userID: String
    let displayName: String?
    let avatarURL: String?
    let metadata: MatrixUserMetadata

    init(
        userID: String,
        displayName: String?,
        avatarURL: String?,
        metadata: MatrixUserMetadata = .empty
    ) {
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.metadata = metadata
    }

    var id: String {
        userID.lowercased()
    }

    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }

        return Self.displayName(from: userID)
    }

    var subtitle: String {
        userID
    }

    private static func displayName(from userID: String) -> String {
        if userID.hasPrefix("@") {
            let localpart = userID
                .dropFirst()
                .split(separator: ":")
                .first
                .map(String.init)

            return localpart?.capitalized ?? userID
        }

        let localpart = userID
            .split(separator: "@")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
    }
}

struct MatrixUserMetadata: Codable, Equatable, Sendable {
    static let empty = MatrixUserMetadata()

    let bio: String?
    let statusMessage: String?
    let website: String?

    init(
        bio: String? = nil,
        statusMessage: String? = nil,
        website: String? = nil
    ) {
        self.bio = Self.nonEmpty(bio)
        self.statusMessage = Self.nonEmpty(statusMessage)
        self.website = Self.nonEmpty(website)
    }

    var isEmpty: Bool {
        bio == nil && statusMessage == nil && website == nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

struct MatrixUserProfileUpdate: Equatable, Sendable {
    let displayName: String
    let bio: String
    let statusMessage: String
    let website: String

    init(
        displayName: String,
        bio: String,
        statusMessage: String,
        website: String
    ) {
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        self.statusMessage = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var metadata: MatrixUserMetadata {
        MatrixUserMetadata(
            bio: bio,
            statusMessage: statusMessage,
            website: website
        )
    }
}

struct MatrixUserSearchResult: Equatable, Sendable {
    let users: [MatrixUserProfile]
    let limited: Bool
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

enum MatrixRecoveryState: String, Codable, Sendable {
    case unknown
    case disabled
    case enabled
    case incomplete

    var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .disabled:
            return "Not Set Up"
        case .enabled:
            return "Set Up"
        case .incomplete:
            return "Needs Recovery Key"
        }
    }
}

enum MatrixBackupState: String, Codable, Sendable {
    case unknown
    case creating
    case enabling
    case resuming
    case enabled
    case downloading
    case disabling

    var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .creating:
            return "Creating"
        case .enabling:
            return "Enabling"
        case .resuming:
            return "Resuming"
        case .enabled:
            return "Enabled"
        case .downloading:
            return "Downloading"
        case .disabling:
            return "Disabling"
        }
    }
}

struct MatrixDeviceVerificationStatus: Equatable, Sendable {
    let userID: String
    let deviceID: String
    let state: MatrixDeviceVerificationState
    let hasDevicesToVerifyAgainst: Bool
    let isLastDevice: Bool
    let recoveryState: MatrixRecoveryState
    let backupState: MatrixBackupState
    let backupExistsOnServer: Bool?
    let ed25519Fingerprint: String?
    let curve25519IdentityKey: String?
    let updatedAt: Date

    var needsUserConfirmation: Bool {
        state != .verified
    }

    var lacksEligibleVerificationDevice: Bool {
        needsUserConfirmation && !hasDevicesToVerifyAgainst
    }

    var canSetUpRecovery: Bool {
        lacksEligibleVerificationDevice && recoveryState == .disabled
    }

    var canConfirmRecovery: Bool {
        lacksEligibleVerificationDevice && (recoveryState == .enabled || recoveryState == .incomplete)
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
            return "OMEMO reports this device as trusted."
        case .unverified:
            if hasDevicesToVerifyAgainst {
                return "Confirm this device from an existing trusted OMEMO session before treating private chats as production-ready."
            }

            return "This device is not trusted yet, and the client did not find an eligible existing OMEMO device to verify against."
        case .unknown:
            return "The client has not reported a stable OMEMO trust state for this device yet."
        }
    }

    var recoveryExplanation: String {
        switch recoveryState {
        case .enabled:
            return "Enter the recovery key to confirm this session when no trusted device is available."
        case .incomplete:
            return "Recovery is incomplete. Enter the recovery key to repair recovery metadata."
        case .disabled:
            return "Set up recovery to create a recovery key for this account."
        case .unknown:
            return "The client has not reported recovery state yet."
        }
    }

    var backupAvailabilityLabel: String {
        guard let backupExistsOnServer else {
            return "Unknown"
        }

        return backupExistsOnServer ? "Exists" : "Not Found"
    }
}

enum MatrixPeerDeviceTrustState: String, Codable, Sendable {
    case undecided
    case trusted
    case verified
    case compromised

    var label: String {
        switch self {
        case .undecided:
            return "Needs Trust"
        case .trusted:
            return "Trusted"
        case .verified:
            return "Verified"
        case .compromised:
            return "Blocked"
        }
    }

    var allowsEncryptedSend: Bool {
        self == .trusted || self == .verified
    }
}

struct MatrixPeerDeviceIdentity: Identifiable, Equatable, Sendable {
    let userID: String
    let deviceID: String
    let fingerprint: String
    let trustState: MatrixPeerDeviceTrustState
    let isActive: Bool
    let isLocalDevice: Bool

    var id: String {
        "\(userID.lowercased())|\(deviceID)"
    }

    var canSendEncrypted: Bool {
        isActive && trustState.allowsEncryptedSend
    }

    var shortFingerprint: String {
        guard fingerprint.count > 19 else {
            return fingerprint
        }

        return "\(fingerprint.prefix(8))...\(fingerprint.suffix(8))"
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
            return "Start verification from this device, or refresh after requesting it from another trusted session."
        case .requestSent:
            return "Open an existing trusted session and accept the verification request."
        case .incomingRequest:
            return "Another session is asking to verify this device. Accept only if you initiated this."
        case .accepted:
            if request != nil {
                return "Waiting for the requesting device to start SAS verification."
            }

            return "Start SAS verification and compare the codes on both devices."
        case .sasStarted:
            return "Waiting for OMEMO to provide comparison codes."
        case .challengeReceived:
            return "Compare these codes with the other device before approving."
        case .approved:
            return "Codes approved. Waiting for OMEMO to finish verification."
        case .finished:
            return "OMEMO finished the verification flow. Refresh the device state."
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

    var label: String {
        switch self {
        case .direct:
            return "DM"
        case .group:
            return "Group"
        }
    }

    var systemImage: String {
        switch self {
        case .direct:
            return "person.fill"
        case .group:
            return "person.2.fill"
        }
    }
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
        kind.label
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
        return "\(roomType) from \(inviterLabel)"
    }
}

enum MatrixRoomMembership: String, Codable, Sendable {
    case joined
    case invited
    case left
    case banned
    case unknown

    var label: String {
        switch self {
        case .joined:
            return "Joined"
        case .invited:
            return "Invited"
        case .left:
            return "Left"
        case .banned:
            return "Banned"
        case .unknown:
            return "Unknown"
        }
    }

    var isActive: Bool {
        self == .joined || self == .invited
    }

    var sortOrder: Int {
        switch self {
        case .joined:
            return 0
        case .invited:
            return 1
        case .unknown:
            return 2
        case .left:
            return 3
        case .banned:
            return 4
        }
    }
}

struct MatrixRoomMember: Identifiable, Equatable, Sendable {
    let userID: String
    let displayName: String?
    let membership: MatrixRoomMembership

    var id: String {
        userID
    }

    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }

        return Self.displayName(from: userID)
    }

    private static func displayName(from userID: String) -> String {
        if userID.hasPrefix("@") {
            let localpart = userID
                .dropFirst()
                .split(separator: ":")
                .first
                .map(String.init)

            return localpart?.capitalized ?? userID
        }

        let localpart = userID
            .split(separator: "@")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
    }
}

struct MatrixTimelineItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let roomID: String
    let sender: String
    let timestamp: Date
    let body: String
    let isLocalEcho: Bool
    let attachment: MatrixTimelineAttachment?
}

enum MatrixTimelineAttachmentKind: String, Codable, Sendable {
    case file
    case image
}

struct MatrixTimelineAttachment: Codable, Equatable, Sendable {
    let kind: MatrixTimelineAttachmentKind
    let filename: String
    let mimeType: String?
    let sizeBytes: Int?
    let sourceJSON: String?

    var isDownloadable: Bool {
        sourceJSON != nil
    }

    var isImage: Bool {
        kind == .image || mimeType?.hasPrefix("image/") == true
    }

    var subtitle: String {
        [mimeType, formattedSize].compactMap { $0 }.joined(separator: " - ")
    }

    private var formattedSize: String? {
        guard let sizeBytes else {
            return nil
        }

        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

struct MatrixAttachmentUpload: Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data
    let imageDimensions: MatrixAttachmentImageDimensions?
    let imageBlurhash: String?

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    var canSendAsImage: Bool {
        isImage && imageDimensions != nil && imageBlurhash != nil
    }

    init(
        filename: String,
        mimeType: String,
        data: Data,
        imageDimensions: MatrixAttachmentImageDimensions? = nil,
        imageBlurhash: String? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.imageDimensions = imageDimensions ?? Self.imageDimensions(from: data, mimeType: mimeType)
        self.imageBlurhash = imageBlurhash ?? Self.averageBlurhash(from: data, mimeType: mimeType)
    }

    init(fileURL: URL, fallbackFilename: String? = nil) throws {
        let resourceValues = try fileURL.resourceValues(forKeys: [.contentTypeKey])
        let filename = fallbackFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFilename: String
        if let filename, !filename.isEmpty {
            resolvedFilename = filename
        } else {
            resolvedFilename = fileURL.lastPathComponent
        }

        self.init(
            filename: resolvedFilename,
            mimeType: resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream",
            data: try Data(contentsOf: fileURL)
        )
    }

    private static func imageDimensions(from data: Data, mimeType: String) -> MatrixAttachmentImageDimensions? {
        guard mimeType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        let pixelWidth = width.uint64Value
        let pixelHeight = height.uint64Value
        guard pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }

        return MatrixAttachmentImageDimensions(width: pixelWidth, height: pixelHeight)
    }

    private static func averageBlurhash(from data: Data, mimeType: String) -> String? {
        guard mimeType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let dc = (Int(pixel[0]) << 16) + (Int(pixel[1]) << 8) + Int(pixel[2])
        return encodeBlurhash(0, length: 1)
            + encodeBlurhash(0, length: 1)
            + encodeBlurhash(dc, length: 4)
    }

    private static func encodeBlurhash(_ value: Int, length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var remaining = value
        var characters = Array(repeating: alphabet[0], count: length)

        for index in stride(from: length - 1, through: 0, by: -1) {
            characters[index] = alphabet[remaining % alphabet.count]
            remaining /= alphabet.count
        }

        return String(characters)
    }
}

struct MatrixAttachmentDownload: Identifiable, Equatable, Sendable {
    let id = UUID()
    let filename: String
    let mimeType: String?
    let data: Data

    var isImage: Bool {
        mimeType?.hasPrefix("image/") == true
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

struct MatrixAttachmentImageDimensions: Codable, Equatable, Sendable {
    let width: UInt64
    let height: UInt64
}

enum MatrixClientError: LocalizedError {
    case invalidHomeserver
    case invalidCredentials
    case invalidMatrixUserID
    case groupRoomNameRequired
    case groupInviteesRequired
    case emptyMessage
    case emptyAttachment
    case attachmentDownloadUnavailable
    case attachmentTransferFailed
    case missingSession
    case roomUnavailable
    case inviteUnavailable
    case noEligibleDeviceForVerification
    case recoverySetupUnavailable
    case recoveryKeyConfirmationUnavailable
    case recoveryKeyRequired
    case recoveryKeySetupFailed
    case recoveryKeyConfirmationFailed
    case profileMetadataEncodingFailed
    case keychainFailure(String)
    case sdkAdapterUnavailable
    case e2eeUnavailable
    case omemoDeviceTrustRequired
    case omemoEncryptionFailed
    case xmppConnectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidHomeserver:
            return "The server address is invalid."
        case .invalidCredentials:
            return "Enter an XMPP JID and password."
        case .invalidMatrixUserID:
            return "Enter an XMPP JID on trix.selfhost.ru."
        case .groupRoomNameRequired:
            return "Enter a group name."
        case .groupInviteesRequired:
            return "Invite at least two people to create a group."
        case .emptyMessage:
            return "Enter a message before sending."
        case .emptyAttachment:
            return "Choose a non-empty attachment."
        case .attachmentDownloadUnavailable:
            return "This attachment is not available for download yet."
        case .attachmentTransferFailed:
            return "Attachment transfer failed."
        case .missingSession:
            return "No saved Trix session is available."
        case .roomUnavailable:
            return "The selected room is not available yet."
        case .inviteUnavailable:
            return "The invite is no longer available."
        case .noEligibleDeviceForVerification:
            return "No trusted OMEMO device is available to verify this device."
        case .recoverySetupUnavailable:
            return "OMEMO recovery is not available in this client slice yet."
        case .recoveryKeyConfirmationUnavailable:
            return "OMEMO recovery key confirmation is not available in this client slice yet."
        case .recoveryKeyRequired:
            return "Enter the recovery key."
        case .recoveryKeySetupFailed:
            return "Recovery setup failed."
        case .recoveryKeyConfirmationFailed:
            return "Recovery key confirmation failed."
        case .profileMetadataEncodingFailed:
            return "Profile metadata could not be encoded."
        case .keychainFailure(let detail):
            return "Keychain operation failed: \(detail)"
        case .sdkAdapterUnavailable:
            return "The protocol adapter is not wired yet."
        case .e2eeUnavailable:
            return "OMEMO is required before sending."
        case .omemoDeviceTrustRequired:
            return "Trust at least one active OMEMO device for this contact before sending."
        case .omemoEncryptionFailed:
            return "OMEMO encryption failed. Refresh the contact devices and try again."
        case .xmppConnectionFailed:
            return "Could not connect to the XMPP server."
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
