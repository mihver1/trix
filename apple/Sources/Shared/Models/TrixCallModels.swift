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
    let updatedAtUnix: UInt64

    init(
        callID: String,
        roomID: String,
        activeParticipantIDs: [String],
        updatedAtUnix: UInt64
    ) {
        self.version = 1
        self.event = .voiceRoomState
        self.callID = callID
        self.roomID = roomID
        self.activeParticipantIDs = activeParticipantIDs
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
}

struct TrixPreparedCall: Equatable, Sendable {
    let authorization: TrixCallJoinAuthorization
    let mediaKey: TrixCallMediaKey
    let invite: TrixCallInvite
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
