import Foundation
import CoreGraphics
import ImageIO

struct TrixSession: Codable, Equatable, Sendable {
    let userID: String
    let deviceID: String
    let homeserverURL: URL
    let accessToken: String
    let refreshToken: String?
    let oidcData: String?
    let sdkStoreID: String
    let createdAt: Date
}

struct TrixAccount: Equatable, Sendable {
    let userID: String
    let displayName: String
    let deviceID: String
}

struct TrixUserProfile: Identifiable, Equatable, Sendable {
    let userID: String
    let displayName: String?
    let avatarURL: String?
    let metadata: TrixUserMetadata

    init(
        userID: String,
        displayName: String?,
        avatarURL: String?,
        metadata: TrixUserMetadata = .empty
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

struct TrixUserMetadata: Codable, Equatable, Sendable {
    static let empty = TrixUserMetadata()

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

struct TrixUserProfileUpdate: Equatable, Sendable {
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

    var metadata: TrixUserMetadata {
        TrixUserMetadata(
            bio: bio,
            statusMessage: statusMessage,
            website: website
        )
    }
}

struct TrixUserSearchResult: Equatable, Sendable {
    let users: [TrixUserProfile]
    let limited: Bool
}

enum TrixDeviceVerificationState: String, Codable, Sendable {
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

enum TrixRecoveryState: String, Codable, Sendable {
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

enum TrixBackupState: String, Codable, Sendable {
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

struct TrixDeviceVerificationStatus: Equatable, Sendable {
    let userID: String
    let deviceID: String
    let state: TrixDeviceVerificationState
    let hasDevicesToVerifyAgainst: Bool
    let isLastDevice: Bool
    let recoveryState: TrixRecoveryState
    let backupState: TrixBackupState
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

enum TrixPeerDeviceTrustState: String, Codable, Sendable {
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

struct TrixPeerDeviceIdentity: Identifiable, Equatable, Sendable {
    let userID: String
    let deviceID: String
    let fingerprint: String
    let trustState: TrixPeerDeviceTrustState
    let isActive: Bool
    let isLocalDevice: Bool

    var id: String {
        "\(userID.lowercased())|\(deviceID)"
    }

    var canSendEncrypted: Bool {
        isActive && trustState.allowsEncryptedSend
    }

    var hasFingerprint: Bool {
        !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shortFingerprint: String {
        guard hasFingerprint else {
            return "Fingerprint unavailable"
        }

        guard fingerprint.count > 19 else {
            return fingerprint
        }

        return "\(fingerprint.prefix(8))...\(fingerprint.suffix(8))"
    }
}

struct TrixDeviceVerificationRequest: Identifiable, Equatable, Sendable {
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

struct TrixDeviceVerificationEmoji: Identifiable, Equatable, Sendable {
    let symbol: String
    let description: String

    var id: String {
        "\(symbol)-\(description)"
    }
}

enum TrixDeviceVerificationChallenge: Equatable, Sendable {
    case emojis([TrixDeviceVerificationEmoji])
    case decimals([String])
}

enum TrixDeviceVerificationFlowPhase: String, Codable, Sendable {
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

struct TrixDeviceVerificationFlow: Equatable, Sendable {
    let phase: TrixDeviceVerificationFlowPhase
    let request: TrixDeviceVerificationRequest?
    let challenge: TrixDeviceVerificationChallenge?
    let updatedAt: Date

    static var idle: TrixDeviceVerificationFlow {
        TrixDeviceVerificationFlow(
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

enum TrixRoomKind: String, Codable, Sendable {
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

struct TrixRoomSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: TrixRoomKind
    let isEncrypted: Bool
    let unreadCount: Int
    let lastMessagePreview: String
    let lastActivityAt: Date

    var subtitle: String {
        kind.label
    }

    func withUnreadCount(_ unreadCount: Int) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: name,
            kind: kind,
            isEncrypted: isEncrypted,
            unreadCount: max(unreadCount, 0),
            lastMessagePreview: lastMessagePreview,
            lastActivityAt: lastActivityAt
        )
    }

    func markingRead() -> TrixRoomSummary {
        withUnreadCount(0)
    }
}

struct TrixRoomInvite: Identifiable, Equatable, Sendable {
    let id: String
    let roomName: String
    let kind: TrixRoomKind
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

enum TrixRoomMembership: String, Codable, Sendable {
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

struct TrixRoomMember: Identifiable, Equatable, Sendable {
    let userID: String
    let displayName: String?
    let membership: TrixRoomMembership

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

enum TrixDeliveryState: String, Codable, Equatable, Sendable {
    case sent
    case delivered

    var label: String {
        switch self {
        case .sent:
            return "Sent"
        case .delivered:
            return "Delivered"
        }
    }

    var systemImage: String {
        switch self {
        case .sent:
            return "checkmark"
        case .delivered:
            return "checkmark.circle.fill"
        }
    }
}

struct TrixMessageReaction: Identifiable, Codable, Equatable, Sendable {
    let emoji: String
    let sender: String
    let timestamp: Date
    let isLocalEcho: Bool

    var id: String {
        "\(emoji)|\(sender.lowercased())"
    }
}

struct TrixReactionAggregate: Identifiable, Equatable, Sendable {
    let emoji: String
    let count: Int
    let isOwnReaction: Bool

    var id: String {
        emoji
    }
}

enum TrixTypingState: String, Codable, Equatable, Sendable {
    case idle
    case composing
    case paused
}

struct TrixRoomTypingState: Codable, Equatable, Sendable {
    let roomID: String
    let typingUserIDs: [String]
    let updatedAt: Date

    var hasTypingUsers: Bool {
        !typingUserIDs.isEmpty
    }
}

enum TrixStickerSourceKind: String, Codable, Sendable {
    case telegram
    case local
}

struct TrixStickerSource: Codable, Equatable, Sendable {
    let kind: TrixStickerSourceKind
    let name: String?
    let url: String?

    init(kind: TrixStickerSourceKind, name: String? = nil, url: String? = nil) {
        self.kind = kind
        self.name = Self.nonEmpty(name)
        self.url = Self.nonEmpty(url)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct TrixSticker: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let packID: String
    let emoji: String?
    let filename: String
    let mimeType: String
    let sizeBytes: Int?
    let imageDimensions: TrixAttachmentImageDimensions?
    let source: TrixStickerSource

    init(
        id: String,
        packID: String,
        emoji: String?,
        filename: String,
        mimeType: String,
        sizeBytes: Int?,
        imageDimensions: TrixAttachmentImageDimensions?,
        source: TrixStickerSource
    ) {
        self.id = id
        self.packID = packID
        self.emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.imageDimensions = imageDimensions
        self.source = source
    }
}

struct TrixStickerPack: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let source: TrixStickerSource
    let stickers: [TrixSticker]
    let importedAt: Date
}

struct TrixStickerAttachmentMetadata: Codable, Equatable, Sendable {
    let stickerID: String
    let packID: String
    let packTitle: String
    let source: TrixStickerSource
    let emoji: String?

    init(
        stickerID: String,
        packID: String,
        packTitle: String,
        source: TrixStickerSource,
        emoji: String?
    ) {
        self.stickerID = stickerID
        self.packID = packID
        self.packTitle = packTitle
        self.source = source
        self.emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct TrixStickerImportSummary: Equatable, Sendable {
    let pack: TrixStickerPack
    let importedStickerCount: Int
    let unsupportedStickerCount: Int
}

struct TrixTimelineItem: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case roomID
        case sender
        case timestamp
        case body
        case isLocalEcho
        case attachment
        case deliveryState
        case reactions
    }

    let id: String
    let roomID: String
    let sender: String
    let timestamp: Date
    let body: String
    let isLocalEcho: Bool
    let attachment: TrixTimelineAttachment?
    let deliveryState: TrixDeliveryState?
    let reactions: [TrixMessageReaction]

    init(
        id: String,
        roomID: String,
        sender: String,
        timestamp: Date,
        body: String,
        isLocalEcho: Bool,
        attachment: TrixTimelineAttachment?,
        deliveryState: TrixDeliveryState? = nil,
        reactions: [TrixMessageReaction] = []
    ) {
        self.id = id
        self.roomID = roomID
        self.sender = sender
        self.timestamp = timestamp
        self.body = body
        self.isLocalEcho = isLocalEcho
        self.attachment = attachment
        self.deliveryState = deliveryState
        self.reactions = reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.roomID = try container.decode(String.self, forKey: .roomID)
        self.sender = try container.decode(String.self, forKey: .sender)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.body = try container.decode(String.self, forKey: .body)
        self.isLocalEcho = try container.decode(Bool.self, forKey: .isLocalEcho)
        self.attachment = try container.decodeIfPresent(TrixTimelineAttachment.self, forKey: .attachment)
        self.deliveryState = try container.decodeIfPresent(TrixDeliveryState.self, forKey: .deliveryState)
        self.reactions = try container.decodeIfPresent([TrixMessageReaction].self, forKey: .reactions) ?? []
    }

    func withDeliveryState(_ deliveryState: TrixDeliveryState?) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: sender,
            timestamp: timestamp,
            body: body,
            isLocalEcho: isLocalEcho,
            attachment: attachment,
            deliveryState: deliveryState,
            reactions: reactions
        )
    }

    func withReactions(_ reactions: [TrixMessageReaction]) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: sender,
            timestamp: timestamp,
            body: body,
            isLocalEcho: isLocalEcho,
            attachment: attachment,
            deliveryState: deliveryState,
            reactions: reactions
        )
    }

    var reactionAggregates: [TrixReactionAggregate] {
        Dictionary(grouping: reactions, by: \.emoji)
            .map { emoji, reactions in
                TrixReactionAggregate(
                    emoji: emoji,
                    count: reactions.count,
                    isOwnReaction: reactions.contains(where: \.isLocalEcho)
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }

                return lhs.emoji < rhs.emoji
            }
    }

    static func mergedDeliveryState(
        _ lhs: TrixDeliveryState?,
        _ rhs: TrixDeliveryState?
    ) -> TrixDeliveryState? {
        if lhs == .delivered || rhs == .delivered {
            return .delivered
        }

        if lhs == .sent || rhs == .sent {
            return .sent
        }

        return nil
    }
}

enum TrixTimelineAttachmentKind: String, Codable, Sendable {
    case file
    case image
    case sticker
}

struct TrixTimelineAttachment: Codable, Equatable, Sendable {
    let kind: TrixTimelineAttachmentKind
    let filename: String
    let mimeType: String?
    let sizeBytes: Int?
    let sourceJSON: String?
    let imageDimensions: TrixAttachmentImageDimensions?
    let imageBlurhash: String?
    let stickerMetadata: TrixStickerAttachmentMetadata?

    init(
        kind: TrixTimelineAttachmentKind,
        filename: String,
        mimeType: String?,
        sizeBytes: Int?,
        sourceJSON: String?,
        imageDimensions: TrixAttachmentImageDimensions? = nil,
        imageBlurhash: String? = nil,
        stickerMetadata: TrixStickerAttachmentMetadata? = nil
    ) {
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sourceJSON = sourceJSON
        self.imageDimensions = imageDimensions
        self.imageBlurhash = imageBlurhash
        self.stickerMetadata = stickerMetadata
    }

    var isDownloadable: Bool {
        sourceJSON != nil
    }

    var isImage: Bool {
        kind == .image || kind == .sticker || mimeType?.hasPrefix("image/") == true
    }

    var isSticker: Bool {
        kind == .sticker || stickerMetadata != nil
    }

    var subtitle: String {
        let details = [mimeType, formattedSize, formattedDimensions].compactMap { $0 }.joined(separator: " - ")
        guard isSticker else {
            return details
        }
        return [stickerMetadata?.packTitle, details].compactMap { value in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }.joined(separator: " - ")
    }

    private var formattedSize: String? {
        guard let sizeBytes else {
            return nil
        }

        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    private var formattedDimensions: String? {
        guard let imageDimensions else {
            return nil
        }

        return "\(imageDimensions.width)x\(imageDimensions.height)"
    }
}

struct TrixAttachmentUpload: Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data
    let imageDimensions: TrixAttachmentImageDimensions?
    let imageBlurhash: String?
    let stickerMetadata: TrixStickerAttachmentMetadata?

    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    var isSticker: Bool {
        stickerMetadata != nil
    }

    var canSendAsImage: Bool {
        isImage && imageDimensions != nil && imageBlurhash != nil
    }

    init(
        filename: String,
        mimeType: String,
        data: Data,
        imageDimensions: TrixAttachmentImageDimensions? = nil,
        imageBlurhash: String? = nil,
        stickerMetadata: TrixStickerAttachmentMetadata? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.imageDimensions = imageDimensions ?? Self.imageDimensions(from: data, mimeType: mimeType)
        self.imageBlurhash = imageBlurhash ?? Self.averageBlurhash(from: data, mimeType: mimeType)
        self.stickerMetadata = stickerMetadata
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

    private static func imageDimensions(from data: Data, mimeType: String) -> TrixAttachmentImageDimensions? {
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

        return TrixAttachmentImageDimensions(width: pixelWidth, height: pixelHeight)
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

struct TrixAttachmentDownload: Identifiable, Equatable, Sendable {
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

enum TrixInlineMediaPreviewSupport {
    static let maxInlinePreviewBytes = 25 * 1024 * 1024
    static let fallbackAspectRatio: CGFloat = 4 / 3
    static let minAspectRatio: CGFloat = 0.5
    static let maxAspectRatio: CGFloat = 1.8

    private static let imageMimeTypes: Set<String> = [
        "image/jpeg",
        "image/jpg",
        "image/png",
        "image/gif",
        "image/webp",
        "image/heif",
        "image/heic",
        "image/heif-sequence",
        "image/heic-sequence",
    ]

    private static let imageFileExtensions: Set<String> = [
        "jpg",
        "jpeg",
        "png",
        "gif",
        "webp",
        "heif",
        "heic",
    ]

    static func canAttemptInlinePreview(_ attachment: TrixTimelineAttachment) -> Bool {
        guard attachment.isDownloadable,
              supports(mimeType: attachment.mimeType, filename: attachment.filename),
              let sizeBytes = attachment.sizeBytes,
              sizeBytes <= maxInlinePreviewBytes else {
            return false
        }

        return true
    }

    static func canRenderInlinePreview(_ download: TrixAttachmentDownload) -> Bool {
        supports(mimeType: download.mimeType, filename: download.filename)
            && download.data.count <= maxInlinePreviewBytes
    }

    static func supports(mimeType: String?, filename: String?) -> Bool {
        if let normalizedMimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if normalizedMimeType.hasPrefix("image/") || imageMimeTypes.contains(normalizedMimeType) {
                return true
            }
        }

        guard let filename else {
            return false
        }

        let fileExtension = URL(fileURLWithPath: filename)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if imageFileExtensions.contains(fileExtension) {
            return true
        }

        return imageFileExtensions.contains(
            filename
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }

    static func isAnimatedGIF(mimeType: String?, filename: String?) -> Bool {
        if mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "image/gif" {
            return true
        }

        guard let filename else {
            return false
        }

        let fileExtension = URL(fileURLWithPath: filename)
            .pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return fileExtension == "gif"
            || filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gif"
    }

    static func aspectRatio(for attachment: TrixTimelineAttachment) -> CGFloat {
        guard let dimensions = attachment.imageDimensions,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return fallbackAspectRatio
        }

        let ratio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
        return min(max(ratio, minAspectRatio), maxAspectRatio)
    }
}

enum TrixAttachmentSendBlockReason: String, Codable, Equatable, Sendable {
    case omemoDeviceTrustRequired
    case groupRecipientSetUnavailable
    case groupOmemoDeviceTrustRequired
    case unavailable

    var message: String {
        switch self {
        case .omemoDeviceTrustRequired:
            return "Trust at least one active OMEMO device for this contact before sending attachments."
        case .groupRecipientSetUnavailable:
            return "Group attachments require a validated MUC member recipient set before sending."
        case .groupOmemoDeviceTrustRequired:
            return "Trust an active OMEMO device for every group member before sending attachments."
        case .unavailable:
            return "Encrypted attachments are not available for this room yet."
        }
    }
}

struct TrixAttachmentSendAvailability: Equatable, Sendable {
    let roomID: String
    let canSend: Bool
    let recipientUserIDs: [String]
    let blockReason: TrixAttachmentSendBlockReason?

    static func allowed(roomID: String, recipientUserIDs: [String]) -> TrixAttachmentSendAvailability {
        TrixAttachmentSendAvailability(
            roomID: roomID,
            canSend: true,
            recipientUserIDs: recipientUserIDs,
            blockReason: nil
        )
    }

    static func blocked(
        roomID: String,
        reason: TrixAttachmentSendBlockReason
    ) -> TrixAttachmentSendAvailability {
        TrixAttachmentSendAvailability(
            roomID: roomID,
            canSend: false,
            recipientUserIDs: [],
            blockReason: reason
        )
    }
}

struct TrixAttachmentImageDimensions: Codable, Equatable, Sendable {
    let width: UInt64
    let height: UInt64
}

enum TrixAPNsEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production

    static var current: TrixAPNsEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    var xmppPushProvider: String {
        switch self {
        case .sandbox:
            return XMPPPushConfiguration.apnsSandboxProvider
        case .production:
            return XMPPPushConfiguration.apnsProductionProvider
        }
    }
}

struct TrixAPNsDeviceToken: Equatable, Sendable {
    let data: Data
    let environment: TrixAPNsEnvironment

    init(data: Data, environment: TrixAPNsEnvironment = .current) {
        self.data = data
        self.environment = environment
    }

    var hexString: String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

struct TrixPushRegistration: Equatable, Sendable {
    let environment: TrixAPNsEnvironment
    let provider: String
    let gatewayJID: String
    let node: String
    let registeredAt: Date
}

struct TrixLocalNotificationRequest: Equatable, Sendable {
    let title: String
    let body: String
    let threadIdentifier: String
    let badgeCount: Int
}

struct TrixRemoteNotificationHandlingResult: Equatable, Sendable {
    let didProcess: Bool
    let badgeCount: Int
    let localNotification: TrixLocalNotificationRequest?

    static let ignored = TrixRemoteNotificationHandlingResult(
        didProcess: false,
        badgeCount: 0,
        localNotification: nil
    )
}

enum TrixPushRegistrationBlocker: String, Codable, Equatable, Sendable {
    case waitingForAPNsToken
    case waitingForSession
    case pushGatewayUnavailable
    case registrationFailed

    var label: String {
        switch self {
        case .waitingForAPNsToken:
            return "Waiting for APNs token"
        case .waitingForSession:
            return "Waiting for session"
        case .pushGatewayUnavailable:
            return "Push gateway unavailable"
        case .registrationFailed:
            return "Registration failed"
        }
    }
}

struct TrixRemoteNotificationPayload: Equatable, Sendable {
    let accountID: String?
    let roomID: String?
    let badge: Int?
    let isSyncNotification: Bool
    let presentsRemoteNotification: Bool

    init(userInfo: [AnyHashable: Any]) {
        let root = Self.stringKeyedDictionary(userInfo)
        let aps = Self.dictionary(root["aps"])
        let trix = Self.dictionary(root["trix"])
        let alert = aps?["alert"]
        let allowedGenericAlert = Self.isAllowedGenericAlert(alert)
        let hasAlert = alert != nil

        self.accountID = Self.nonEmptyString(trix?["account"])
        self.roomID = Self.nonEmptyString(trix?["room"])
        self.badge = Self.integer(trix?["badge"]) ?? Self.integer(aps?["badge"])
        self.presentsRemoteNotification = allowedGenericAlert

        let contentAvailable = Self.integer(aps?["content-available"]) == 1
        let type = Self.nonEmptyString(trix?["type"])
        self.isSyncNotification = contentAvailable &&
            type == "sync" &&
            (!hasAlert || allowedGenericAlert) &&
            Self.isAllowedGenericSound(aps?["sound"]) &&
            !Self.containsForbiddenPlaintextKey(root)
    }

    private static func stringKeyedDictionary(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { partialResult, pair in
            guard let key = pair.key as? String else {
                return
            }
            partialResult[key] = pair.value
        }
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }

        if let dictionary = value as? [AnyHashable: Any] {
            return stringKeyedDictionary(dictionary)
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func isAllowedGenericAlert(_ value: Any?) -> Bool {
        guard let value else {
            return false
        }

        if let alert = value as? String {
            return isAllowedGenericNotificationBody(alert)
        }

        guard let alert = Self.dictionary(value) else {
            return false
        }

        let allowedKeys: Set<String> = ["title", "body"]
        let keys = Set(alert.keys.map { $0.lowercased() })
        guard keys.isSubset(of: allowedKeys) else {
            return false
        }

        return Self.nonEmptyString(alert["title"]) == "Trix" &&
            Self.nonEmptyString(alert["body"]).map(isAllowedGenericNotificationBody) == true
    }

    private static func isAllowedGenericSound(_ value: Any?) -> Bool {
        guard let value else {
            return true
        }

        return Self.nonEmptyString(value) == "default"
    }

    private static func isAllowedGenericNotificationBody(_ body: String) -> Bool {
        if body == "New encrypted message" {
            return true
        }

        return body.range(
            of: #"^[1-9][0-9]* unread encrypted messages$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsForbiddenPlaintextKey(
        _ dictionary: [String: Any],
        path: [String] = []
    ) -> Bool {
        for (key, value) in dictionary {
            let normalizedKey = key.lowercased()
            let childPath = path + [normalizedKey]
            if !isAllowedGenericAlertFieldPath(childPath) &&
                (normalizedKey.contains("body") ||
                normalizedKey.contains("plaintext") ||
                normalizedKey.contains("decrypted") ||
                normalizedKey.contains("filename") ||
                normalizedKey.contains("attachmentname") ||
                normalizedKey.contains("attachment-name")) {
                return true
            }

            if let nested = Self.dictionary(value),
               containsForbiddenPlaintextKey(nested, path: childPath) {
                return true
            }
        }

        return false
    }

    private static func isAllowedGenericAlertFieldPath(_ path: [String]) -> Bool {
        path == ["aps", "alert", "title"] || path == ["aps", "alert", "body"]
    }
}

enum TrixClientError: LocalizedError {
    case invalidHomeserver
    case invalidCredentials
    case invalidTrixUserID
    case groupRoomNameRequired
    case groupInviteesRequired
    case emptyMessage
    case emptyAttachment
    case attachmentDownloadUnavailable
    case attachmentTransferFailed
    case attachmentEncryptionUnavailable
    case attachmentDecryptionFailed
    case stickerImportUnavailable
    case stickerPackUnavailable
    case stickerFileUnavailable
    case unsupportedStickerPack
    case groupOmemoRecipientSetUnavailable
    case groupOmemoDeviceTrustRequired
    case missingSession
    case roomUnavailable
    case inviteUnavailable
    case roomJoinTimedOut
    case noEligibleDeviceForVerification
    case recoverySetupUnavailable
    case recoveryKeyConfirmationUnavailable
    case recoveryKeyRequired
    case recoveryKeySetupFailed
    case recoveryKeyConfirmationFailed
    case profileMetadataEncodingFailed
    case inviteIssueUnavailable
    case inviteIssueUnauthorized
    case passwordChangeUnavailable
    case invalidRegistrationInvite
    case registrationPasswordTooWeak
    case registrationUnavailable
    case keychainFailure(String)
    case sdkAdapterUnavailable
    case e2eeUnavailable
    case omemoDeviceTrustRequired
    case omemoEncryptionFailed
    case xmppConnectionFailed
    case apnsGatewayUnavailable
    case apnsRegistrationFailed
    case reactionsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHomeserver:
            return "The server address is invalid."
        case .invalidCredentials:
            return "Enter an XMPP JID and password."
        case .invalidTrixUserID:
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
        case .attachmentEncryptionUnavailable:
            return "Encrypted attachment transfer is not available yet."
        case .attachmentDecryptionFailed:
            return "Attachment decryption failed."
        case .stickerImportUnavailable:
            return "Sticker import is not available yet."
        case .stickerPackUnavailable:
            return "Sticker pack is not available."
        case .stickerFileUnavailable:
            return "Sticker file download failed."
        case .unsupportedStickerPack:
            return "This sticker pack has no supported static stickers."
        case .groupOmemoRecipientSetUnavailable:
            return "Group OMEMO sends require a validated MUC member recipient set before sending."
        case .groupOmemoDeviceTrustRequired:
            return "Trust an active OMEMO device for every group member before sending."
        case .missingSession:
            return "No saved Trix session is available."
        case .roomUnavailable:
            return "The selected room is not available yet."
        case .inviteUnavailable:
            return "The invite is no longer available."
        case .roomJoinTimedOut:
            return "Joining the room timed out. Refresh invites and try again."
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
        case .inviteIssueUnavailable:
            return "Invite creation is not available."
        case .inviteIssueUnauthorized:
            return "Sign in again before changing account settings."
        case .passwordChangeUnavailable:
            return "Password change is not available."
        case .invalidRegistrationInvite:
            return "Invite code or handle is not valid."
        case .registrationPasswordTooWeak:
            return "Use a password with at least 12 characters."
        case .registrationUnavailable:
            return "Invite registration is not available."
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
        case .apnsGatewayUnavailable:
            return "The XMPP APNs gateway is not available yet."
        case .apnsRegistrationFailed:
            return "APNs registration failed."
        case .reactionsUnavailable:
            return "Message reactions are not available on this XMPP path yet."
        }
    }
}

extension Error {
    var trixUserFacingMessage: String {
        if let localizedError = self as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return localizedDescription
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
