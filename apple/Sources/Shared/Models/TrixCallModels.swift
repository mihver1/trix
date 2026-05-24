import Foundation
import Security

enum TrixCallKind: String, Codable, Equatable, Sendable {
    case directVideo = "direct_video"
    case groupVoice = "group_voice"
}

enum TrixCallDescriptorEvent: String, Codable, Equatable, Sendable {
    case invite
    case answer
    case end
    case voiceRoomState = "voice_room_state"
    case keyRotation = "key_rotation"
}

struct TrixCallMediaKey: Codable, Equatable, Sendable {
    static let byteCount = 32

    let keyID: String
    let key: String
    let keyIndex: Int
    let createdAtUnix: UInt64

    init(
        keyID: String,
        key: String,
        keyIndex: Int,
        createdAtUnix: UInt64
    ) throws {
        let trimmedKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyID.isEmpty, !trimmedKey.isEmpty, (0..<16).contains(keyIndex) else {
            throw TrixClientError.callE2EEKeyUnavailable
        }

        self.keyID = trimmedKeyID
        self.key = trimmedKey
        self.keyIndex = keyIndex
        self.createdAtUnix = createdAtUnix
    }

    static func generate(now: Date = Date()) throws -> TrixCallMediaKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw TrixClientError.callE2EEKeyUnavailable
        }

        return try TrixCallMediaKey(
            keyID: UUID().uuidString,
            key: Data(bytes).base64EncodedString(),
            keyIndex: 0,
            createdAtUnix: UInt64(now.timeIntervalSince1970)
        )
    }
}

struct TrixCallInvite: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.call.invite.v1"

    let version: Int
    let event: TrixCallDescriptorEvent
    let callID: String
    let kind: TrixCallKind
    let roomID: String
    let senderID: String
    let liveKitRoom: String
    let createdAtUnix: UInt64
    let expiresAtUnix: UInt64
    let mediaKey: TrixCallMediaKey

    init(
        callID: String,
        kind: TrixCallKind,
        roomID: String,
        senderID: String,
        liveKitRoom: String,
        createdAtUnix: UInt64,
        expiresAtUnix: UInt64,
        mediaKey: TrixCallMediaKey
    ) {
        self.version = 1
        self.event = .invite
        self.callID = callID
        self.kind = kind
        self.roomID = roomID
        self.senderID = senderID
        self.liveKitRoom = liveKitRoom
        self.createdAtUnix = createdAtUnix
        self.expiresAtUnix = expiresAtUnix
        self.mediaKey = mediaKey
    }
}

struct TrixCallAnswer: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.call.answer.v1"

    let version: Int
    let event: TrixCallDescriptorEvent
    let callID: String
    let accepted: Bool
    let answeredAtUnix: UInt64

    init(callID: String, accepted: Bool, answeredAtUnix: UInt64) {
        self.version = 1
        self.event = .answer
        self.callID = callID
        self.accepted = accepted
        self.answeredAtUnix = answeredAtUnix
    }
}

struct TrixCallEnd: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.call.end.v1"

    let version: Int
    let event: TrixCallDescriptorEvent
    let callID: String
    let endedAtUnix: UInt64

    init(callID: String, endedAtUnix: UInt64) {
        self.version = 1
        self.event = .end
        self.callID = callID
        self.endedAtUnix = endedAtUnix
    }
}

struct TrixVoiceRoomState: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.call.voice-room-state.v1"

    let version: Int
    let event: TrixCallDescriptorEvent
    let callID: String
    let roomID: String
    let activeParticipantIDs: [String]
    let mediaKey: TrixCallMediaKey?
    let updatedAtUnix: UInt64

    init(
        callID: String,
        roomID: String,
        activeParticipantIDs: [String],
        mediaKey: TrixCallMediaKey? = nil,
        updatedAtUnix: UInt64
    ) {
        self.version = 1
        self.event = .voiceRoomState
        self.callID = callID
        self.roomID = roomID
        self.activeParticipantIDs = activeParticipantIDs
        self.mediaKey = mediaKey
        self.updatedAtUnix = updatedAtUnix
    }
}

struct TrixCallKeyRotation: Codable, Equatable, Sendable {
    static let contentType = "com.softgrid.trix.call.key-rotation.v1"

    let version: Int
    let event: TrixCallDescriptorEvent
    let callID: String
    let previousKeyID: String
    let mediaKey: TrixCallMediaKey
    let rotatedAtUnix: UInt64

    init(
        callID: String,
        previousKeyID: String,
        mediaKey: TrixCallMediaKey,
        rotatedAtUnix: UInt64
    ) {
        self.version = 1
        self.event = .keyRotation
        self.callID = callID
        self.previousKeyID = previousKeyID
        self.mediaKey = mediaKey
        self.rotatedAtUnix = rotatedAtUnix
    }
}

enum TrixCallDescriptor: Equatable, Sendable {
    case invite(TrixCallInvite)
    case answer(TrixCallAnswer)
    case end(TrixCallEnd)
    case voiceRoomState(TrixVoiceRoomState)
    case keyRotation(TrixCallKeyRotation)

    var callID: String {
        switch self {
        case .invite(let descriptor):
            return descriptor.callID
        case .answer(let descriptor):
            return descriptor.callID
        case .end(let descriptor):
            return descriptor.callID
        case .voiceRoomState(let descriptor):
            return descriptor.callID
        case .keyRotation(let descriptor):
            return descriptor.callID
        }
    }

    var event: TrixCallDescriptorEvent {
        switch self {
        case .invite(let descriptor):
            return descriptor.event
        case .answer(let descriptor):
            return descriptor.event
        case .end(let descriptor):
            return descriptor.event
        case .voiceRoomState(let descriptor):
            return descriptor.event
        case .keyRotation(let descriptor):
            return descriptor.event
        }
    }
}

struct TrixReceivedCallDescriptor: Equatable, Sendable {
    let id: String
    let roomID: String
    let senderID: String
    let timestamp: Date
    let descriptor: TrixCallDescriptor
    let isLocalEcho: Bool
}

struct TrixIncomingDirectCall: Identifiable, Equatable, Sendable {
    let callID: String
    let roomID: String
    let callerID: String
    let liveKitRoom: String
    let createdAt: Date
    let expiresAt: Date
    let mediaKey: TrixCallMediaKey

    var id: String {
        callID
    }
}

struct TrixGroupVoiceRoomSnapshot: Identifiable, Equatable, Sendable {
    let roomID: String
    let callID: String?
    let activeParticipantIDs: [String]
    let updatedAt: Date?

    var id: String {
        roomID
    }

    var activeParticipantCount: Int {
        activeParticipantIDs.count
    }
}

enum TrixCallLifecyclePhase: String, Codable, Equatable, Sendable {
    case idle
    case outgoingPreparing = "outgoing_preparing"
    case outgoingRinging = "outgoing_ringing"
    case incomingRinging = "incoming_ringing"
    case connecting
    case active
    case reconnecting
    case ending
    case ended
    case failed

    var isTransient: Bool {
        switch self {
        case .outgoingPreparing, .connecting, .reconnecting, .ending:
            return true
        case .idle, .outgoingRinging, .incomingRinging, .active, .ended, .failed:
            return false
        }
    }

    var isActiveLike: Bool {
        switch self {
        case .active, .reconnecting:
            return true
        case .idle, .outgoingPreparing, .outgoingRinging, .incomingRinging, .connecting, .ending, .ended, .failed:
            return false
        }
    }
}

enum TrixCallLocalAudioState: String, Codable, Equatable, Sendable {
    case unavailable
    case muted
    case unmuted
}

enum TrixCallLocalCameraState: String, Codable, Equatable, Sendable {
    case unavailable
    case off
    case on
}

enum TrixCallRemoteMediaReadiness: String, Codable, Equatable, Sendable {
    case none
    case waiting
    case ready
}

enum TrixCallE2EEState: String, Codable, Equatable, Sendable {
    case none
    case required
    case active
    case failed
}

enum TrixCallPlatformSurfaceState: String, Codable, Equatable, Sendable {
    case none
    case incomingDirectCallBar
    case directCallBar
    case groupVoiceRoomBar
    case callKitIncoming
    case floatingWindow
}

enum TrixRoomCallIndicatorKind: Equatable, Sendable {
    case incomingDirect
    case directCall
    case groupVoice
}

struct TrixRoomCallIndicator: Equatable, Sendable {
    let kind: TrixRoomCallIndicatorKind
    let title: String
    let accessibilityLabel: String
    let participantCount: Int?
    let isRinging: Bool

    init?(state: TrixCallLifecycleState) {
        switch state.kind {
        case .directVideo:
            switch state.phase {
            case .incomingRinging:
                self.kind = .incomingDirect
                self.title = "Incoming"
                self.accessibilityLabel = "Incoming encrypted call"
                self.participantCount = nil
                self.isRinging = true
            case .outgoingRinging:
                self.kind = .directCall
                self.title = "Calling"
                self.accessibilityLabel = "Encrypted call ringing"
                self.participantCount = nil
                self.isRinging = false
            case .connecting:
                self.kind = .directCall
                self.title = "Connecting"
                self.accessibilityLabel = "Encrypted call connecting"
                self.participantCount = nil
                self.isRinging = false
            case .active:
                self.kind = .directCall
                self.title = "In call"
                self.accessibilityLabel = "Encrypted call active"
                self.participantCount = nil
                self.isRinging = false
            case .reconnecting:
                self.kind = .directCall
                self.title = "Reconnecting"
                self.accessibilityLabel = "Encrypted call reconnecting"
                self.participantCount = nil
                self.isRinging = false
            case .ending:
                self.kind = .directCall
                self.title = "Ending"
                self.accessibilityLabel = "Encrypted call ending"
                self.participantCount = nil
                self.isRinging = false
            case .idle, .outgoingPreparing, .ended, .failed:
                return nil
            }
        case .groupVoice:
            guard state.phase.isActiveLike, !state.participantIDs.isEmpty else {
                return nil
            }

            self.kind = .groupVoice
            self.title = state.phase == .reconnecting ? "Reconnecting" : "Voice live"
            self.accessibilityLabel = "\(state.participantIDs.count) in encrypted group voice"
            self.participantCount = state.participantIDs.count
            self.isRinging = false
        case nil:
            return nil
        }
    }
}

struct TrixCallLifecycleState: Equatable, Sendable {
    let phase: TrixCallLifecyclePhase
    let roomID: String
    let callID: String?
    let kind: TrixCallKind?
    let startedAt: Date?
    let updatedAt: Date?
    let expiresAt: Date?
    let participantIDs: [String]
    let localAudioState: TrixCallLocalAudioState
    let localCameraState: TrixCallLocalCameraState
    let remoteMediaReadiness: TrixCallRemoteMediaReadiness
    let platformSurfaceState: TrixCallPlatformSurfaceState

    var isActing: Bool {
        phase.isTransient
    }

    var foregroundCue: TrixCallForegroundCue {
        guard phase == .incomingRinging,
              kind == .directVideo,
              let callID else {
            return .none
        }

        return .incomingDirectCall(callID: callID)
    }

    var e2eeState: TrixCallE2EEState {
        switch phase {
        case .idle, .ended:
            return .none
        case .failed:
            return .failed
        case .active:
            return .active
        case .outgoingPreparing, .outgoingRinging, .incomingRinging, .connecting, .reconnecting, .ending:
            return .required
        }
    }

    static func idle(roomID: String) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .idle,
            roomID: roomID,
            callID: nil,
            kind: nil,
            startedAt: nil,
            updatedAt: nil,
            expiresAt: nil,
            participantIDs: [],
            localAudioState: .unavailable,
            localCameraState: .unavailable,
            remoteMediaReadiness: .none,
            platformSurfaceState: .none
        )
    }
}

enum TrixCallForegroundCue: Equatable, Sendable {
    case none
    case incomingDirectCall(callID: String)
}

struct TrixCallJoinAuthorization: Equatable, Sendable {
    let callID: String
    let kind: TrixCallKind
    let liveKitURL: URL
    let liveKitRoom: String
    let liveKitToken: String
    let liveKitTokenExpiresAtUnix: UInt64
    let turn: TrixTurnCredentials
    let e2eeRequired: Bool
    let publishAudio: Bool
    let publishVideo: Bool
    let subscribeAudio: Bool
    let subscribeVideo: Bool
}

struct TrixTurnCredentials: Codable, Equatable, Sendable {
    let uris: [String]
    let username: String
    let credential: String
    let expiresAtUnix: UInt64

    private enum CodingKeys: String, CodingKey {
        case uris
        case username
        case credential
        case expiresAtUnix = "expires_at_unix"
    }
}

struct TrixActiveMediaCall: Equatable, Sendable {
    let callID: String
    let kind: TrixCallKind
    let liveKitRoom: String
    let startedAt: Date
    let publishesLocalAudio: Bool
    let publishesLocalVideo: Bool
    let subscribesRemoteAudio: Bool
    let subscribesRemoteVideo: Bool
}

struct TrixPreparedCall: Equatable, Sendable {
    let authorization: TrixCallJoinAuthorization
    let mediaKey: TrixCallMediaKey
    let invite: TrixCallInvite

    var roomID: String {
        invite.roomID
    }
}

struct TrixVoIPCallPayload: Equatable, Sendable {
    let callID: String?
    let accountID: String?
    let isCallNotification: Bool

    init(userInfo: [AnyHashable: Any]) {
        let root = Self.stringKeyedDictionary(userInfo)
        let trix = Self.dictionary(root["trix"])
        self.callID = Self.nonEmptyString(trix?["call_id"])
        self.accountID = Self.nonEmptyString(trix?["account"])
        self.isCallNotification =
            callID != nil &&
            Self.isAllowedVoIPPayloadShape(root, trix: trix) &&
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

    private static func isAllowedVoIPPayloadShape(_ root: [String: Any], trix: [String: Any]?) -> Bool {
        guard let trix else {
            return false
        }

        let rootKeys = Set(root.keys.map { $0.lowercased() })
        guard rootKeys.isSubset(of: ["aps", "trix"]) else {
            return false
        }

        if let aps = root["aps"] {
            guard let apsDictionary = Self.dictionary(aps), apsDictionary.isEmpty else {
                return false
            }
        }

        let trixKeys = Set(trix.keys.map { $0.lowercased() })
        return trixKeys.isSubset(of: ["call_id", "account"])
    }

    private static func containsForbiddenPlaintextKey(_ dictionary: [String: Any]) -> Bool {
        for (key, value) in dictionary {
            let normalizedKey = key.lowercased()
            let compactKey = normalizedKey
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            if normalizedKey.contains("body") ||
                normalizedKey.contains("plaintext") ||
                normalizedKey.contains("decrypted") ||
                compactKey.contains("livekittoken") ||
                compactKey.contains("turncredential") ||
                compactKey.contains("mediakey") ||
                compactKey.contains("callkey") ||
                compactKey.contains("e2eekey") ||
                normalizedKey.contains("room") ||
                normalizedKey.contains("caller") {
                return true
            }

            if let nested = Self.dictionary(value), containsForbiddenPlaintextKey(nested) {
                return true
            }
        }

        return false
    }
}
