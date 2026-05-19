import Foundation
import OSLog

#if canImport(LiveKit)
import AVFoundation
import LiveKit
#endif

private let trixCallMediaLogger = Logger(subsystem: "com.softgrid.trixapp", category: "call-media")

enum TrixCallMediaConfiguration {
    static let forceRelayEnvironmentKey = "TRIX_CALL_FORCE_RELAY_ONLY"

    static func forceRelayOnly(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[forceRelayEnvironmentKey] else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

struct HTTPCallControlService: TrixCallControlService {
    private let directCallURL: URL
    private let directCallJoinURL: URL
    private let groupVoiceURL: URL
    private let endCallURL: URL
    private let turnURL: URL

    init(baseURL: URL = TrixClientConfiguration.callControlAPIBaseURL) {
        self.directCallURL = baseURL.appending(path: "v1/calls/dm-video")
        self.directCallJoinURL = baseURL.appending(path: "v1/calls/dm-video/join")
        self.groupVoiceURL = baseURL.appending(path: "v1/calls/group-voice/join")
        self.endCallURL = baseURL.appending(path: "v1/calls/end")
        self.turnURL = baseURL.appending(path: "v1/turn/credentials")
    }

    func prepareDirectVideoCall(
        peerUserID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        try await sendCallRequest(
            url: directCallURL,
            payload: DirectCallPayload(peerUserID: peerUserID),
            session: session
        )
    }

    func joinDirectVideoCall(
        callID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        try await sendCallRequest(
            url: directCallJoinURL,
            payload: DirectCallJoinPayload(callID: callID),
            session: session
        )
    }

    func joinGroupVoiceRoom(
        roomID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        try await sendCallRequest(
            url: groupVoiceURL,
            payload: GroupVoicePayload(roomID: roomID),
            session: session
        )
    }

    func endCall(callID: String, session: TrixSession) async throws {
        let _: EndCallResponse = try await sendRequest(
            url: endCallURL,
            payload: EndCallPayload(callID: callID),
            session: session
        )
    }

    func turnCredentials(session: TrixSession) async throws -> TrixTurnCredentials {
        try await sendRequest(
            url: turnURL,
            payload: EmptyPayload(),
            session: session
        )
    }

    private func sendCallRequest<T: Encodable & Sendable>(
        url: URL,
        payload: T,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        let response: CallJoinResponse = try await sendRequest(
            url: url,
            payload: payload,
            session: session
        )
        guard response.e2eeRequired,
              let liveKitURL = URL(string: response.liveKitURL),
              !response.liveKitToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.callControlInvalidResponse
        }

        return TrixCallJoinAuthorization(
            callID: response.callID,
            kind: response.kind,
            liveKitURL: liveKitURL,
            liveKitRoom: response.liveKitRoom,
            liveKitToken: response.liveKitToken,
            liveKitTokenExpiresAtUnix: response.liveKitTokenExpiresAtUnix,
            turn: response.turn,
            e2eeRequired: response.e2eeRequired,
            publishAudio: response.publishAudio,
            publishVideo: response.publishVideo,
            subscribeAudio: response.subscribeAudio,
            subscribeVideo: response.subscribeVideo
        )
    }

    private func sendRequest<T: Encodable & Sendable, U: Decodable & Sendable>(
        url: URL,
        payload: T,
        session: TrixSession
    ) async throws -> U {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TrixClientError.callControlNetworkUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.callControlInvalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw TrixClientError.callAuthenticationUnavailable
            }
            if httpResponse.statusCode == 403 {
                throw TrixClientError.callMembershipUnavailable
            }
            throw TrixClientError.callControlRejected(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(U.self, from: data)
        } catch {
            throw TrixClientError.callControlInvalidResponse
        }
    }

    private static func basicAuthorizationHeader(for session: TrixSession) throws -> String {
        let userID = try normalizedXMPPUserID(session.userID)
        let password = session.accessToken
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.callAuthenticationUnavailable
        }

        let credentials = "\(userID):\(password)"
        guard let data = credentials.data(using: .utf8) else {
            throw TrixClientError.callAuthenticationUnavailable
        }

        return "Basic \(data.base64EncodedString())"
    }

    private static func normalizedXMPPUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@"), let separator = trimmed.firstIndex(of: ":") {
            let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
            let server = String(trimmed[trimmed.index(after: separator)...])
            guard !localpart.isEmpty, server == TrixClientConfiguration.serverName else {
                throw TrixClientError.invalidTrixUserID
            }
            return "\(localpart)@\(server)"
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first,
              let domain = parts.last,
              !localpart.isEmpty,
              domain == TrixClientConfiguration.serverName,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TrixClientError.invalidTrixUserID
        }

        return trimmed
    }
}

#if canImport(LiveKit)
actor TrixLiveKitMediaCallService: TrixMediaCallService {
    private var roomsByCallID: [String: Room] = [:]
    private let forceRelayOnly: Bool

    init(forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly()) {
        self.forceRelayOnly = forceRelayOnly
    }

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        guard authorization.e2eeRequired else {
            throw TrixClientError.callE2EEKeyUnavailable
        }

        let keyProvider = BaseKeyProvider(options: KeyProviderOptions(
            sharedKey: true,
            keyRingSize: 2
        ))
        keyProvider.setKey(key: mediaKey.key, index: Int32(mediaKey.keyIndex))
        keyProvider.setCurrentKeyIndex(Int32(mediaKey.keyIndex))

        let room = Room()
        let roomOptions = RoomOptions(
            adaptiveStream: authorization.subscribeVideo,
            dynacast: authorization.publishVideo,
            encryptionOptions: EncryptionOptions(keyProvider: keyProvider)
        )
        let connectOptions = ConnectOptions(
            iceServers: Self.iceServers(from: authorization.turn),
            iceTransportPolicy: forceRelayOnly ? .relay : .all
        )

        if authorization.publishAudio {
            guard await LiveKitSDK.ensureDeviceAccess(for: [.audio]) else {
                throw TrixClientError.callMicrophonePermissionRequired
            }
        }
        if authorization.publishVideo {
            guard await LiveKitSDK.ensureDeviceAccess(for: [.video]) else {
                throw TrixClientError.callCameraPermissionRequired
            }
        }

        do {
            try await room.connect(
                url: authorization.liveKitURL.absoluteString,
                token: authorization.liveKitToken,
                connectOptions: connectOptions,
                roomOptions: roomOptions
            )
        } catch {
            await room.disconnect()
            Self.logMediaFailure(context: "connect", error: error)
            throw TrixClientError.callMediaUnavailable
        }

        if authorization.publishAudio {
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
            } catch {
                await room.disconnect()
                Self.logMediaFailure(context: "microphone", error: error)
                throw TrixClientError.callMicrophoneUnavailable
            }
        }
        if authorization.publishVideo {
            do {
                try await room.localParticipant.setCamera(enabled: true)
            } catch {
                await room.disconnect()
                Self.logMediaFailure(context: "camera", error: error)
                throw TrixClientError.callCameraUnavailable
            }
        }

        roomsByCallID[authorization.callID] = room
        return TrixActiveMediaCall(
            callID: authorization.callID,
            kind: authorization.kind,
            liveKitRoom: authorization.liveKitRoom,
            startedAt: Date()
        )
    }

    private static func iceServers(from credentials: TrixTurnCredentials) -> [IceServer] {
        let urls = credentials.uris
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else {
            return []
        }

        return [
            IceServer(
                urls: urls,
                username: credentials.username,
                credential: credentials.credential
            )
        ]
    }

    private static func logMediaFailure(context: String, error: Error) {
        let nsError = error as NSError
        trixCallMediaLogger.error(
            "LiveKit media \(context, privacy: .public) failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(sanitizeErrorDescription(nsError.localizedDescription), privacy: .public)"
        )
    }

    private static func sanitizeErrorDescription(_ value: String) -> String {
        let sensitivePatterns = [
            #"(?i)(token|jwt|credential|password|secret|authorization)=\S+"#,
            #"(?i)(token|jwt|credential|password|secret|authorization):\S+"#,
            #"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        ]

        return sensitivePatterns.reduce(value) { result, pattern in
            result.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: .regularExpression
            )
        }
    }

    func disconnect(callID: String) async {
        guard let room = roomsByCallID.removeValue(forKey: callID) else {
            return
        }
        await room.disconnect()
    }
}
#else
actor TrixLiveKitMediaCallService: TrixMediaCallService {
    init(forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly()) {}

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        throw TrixClientError.callMediaUnavailable
    }

    func disconnect(callID: String) async {}
}
#endif

private struct DirectCallPayload: Encodable, Sendable {
    let peerUserID: String

    private enum CodingKeys: String, CodingKey {
        case peerUserID = "peer_user_id"
    }
}

private struct DirectCallJoinPayload: Encodable, Sendable {
    let callID: String

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
    }
}

private struct GroupVoicePayload: Encodable, Sendable {
    let roomID: String

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }
}

private struct EndCallPayload: Encodable, Sendable {
    let callID: String

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
    }
}

private struct EndCallResponse: Decodable, Sendable {
    let callID: String
    let ended: Bool

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case ended
    }
}

private struct EmptyPayload: Encodable, Sendable {}

private struct CallJoinResponse: Decodable, Sendable {
    let callID: String
    let kind: TrixCallKind
    let liveKitURL: String
    let liveKitRoom: String
    let liveKitToken: String
    let liveKitTokenExpiresAtUnix: UInt64
    let turn: TrixTurnCredentials
    let e2eeRequired: Bool
    let publishAudio: Bool
    let publishVideo: Bool
    let subscribeAudio: Bool
    let subscribeVideo: Bool

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case kind
        case liveKitURL = "livekit_url"
        case liveKitRoom = "livekit_room"
        case liveKitToken = "livekit_token"
        case liveKitTokenExpiresAtUnix = "livekit_token_expires_at_unix"
        case turn
        case e2eeRequired = "e2ee_required"
        case publishAudio = "publish_audio"
        case publishVideo = "publish_video"
        case subscribeAudio = "subscribe_audio"
        case subscribeVideo = "subscribe_video"
    }
}
