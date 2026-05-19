import Foundation
import OSLog

#if canImport(LiveKit)
import AVFoundation
import LiveKit
#endif

private let trixCallMediaLogger = Logger(subsystem: "com.softgrid.trixapp", category: "call-media")

private func sanitizeCallMediaDescription(_ value: String) -> String {
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

enum TrixCallMediaConfiguration {
    static let forceRelayEnvironmentKey = "TRIX_CALL_FORCE_RELAY_ONLY"
    static let audioProbeEnvironmentKey = "TRIX_CALL_AUDIO_PROBE"

    static func forceRelayOnly(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        truthyEnvironmentValue(environment[forceRelayEnvironmentKey])
            || truthyInfoDictionaryValue("TrixCallForceRelayOnly")
    }

    static func audioProbeEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        truthyEnvironmentValue(environment[audioProbeEnvironmentKey])
            || truthyInfoDictionaryValue("TrixCallAudioProbe")
    }

    private static func truthyEnvironmentValue(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func truthyInfoDictionaryValue(_ key: String) -> Bool {
        switch Bundle.main.object(forInfoDictionaryKey: key) {
        case let value as Bool:
            return value
        case let value as String:
            return truthyEnvironmentValue(value)
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
            payload: DirectCallPayload(peerUserID: peerUserID, deviceID: session.deviceID),
            session: session
        )
    }

    func joinDirectVideoCall(
        callID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        try await sendCallRequest(
            url: directCallJoinURL,
            payload: DirectCallJoinPayload(callID: callID, deviceID: session.deviceID),
            session: session
        )
    }

    func joinGroupVoiceRoom(
        roomID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        try await sendCallRequest(
            url: groupVoiceURL,
            payload: GroupVoicePayload(roomID: roomID, deviceID: session.deviceID),
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
    private var sessionsByCallID: [String: LiveKitCallSession] = [:]
    private let forceRelayOnly: Bool
    private let audioProbeEnabled: Bool

    init(
        forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly(),
        audioProbeEnabled: Bool = TrixCallMediaConfiguration.audioProbeEnabled()
    ) {
        self.forceRelayOnly = forceRelayOnly
        self.audioProbeEnabled = audioProbeEnabled
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
        let observer = TrixLiveKitRoomObserver(audioProbeEnabled: audioProbeEnabled)
        room.add(delegate: observer)
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
            room.remove(delegate: observer)
            await room.disconnect()
            Self.logMediaFailure(context: "connect", error: error)
            throw TrixClientError.callMediaUnavailable
        }

        if authorization.publishAudio {
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
            } catch {
                room.remove(delegate: observer)
                await room.disconnect()
                Self.logMediaFailure(context: "microphone", error: error)
                throw TrixClientError.callMicrophoneUnavailable
            }
        }
        if authorization.publishVideo {
            do {
                try await room.localParticipant.setCamera(enabled: true)
            } catch {
                room.remove(delegate: observer)
                await room.disconnect()
                Self.logMediaFailure(context: "camera", error: error)
                throw TrixClientError.callCameraUnavailable
            }
        }

        observer.attachExistingRemoteTracks(in: room)
        sessionsByCallID[authorization.callID] = LiveKitCallSession(room: room, observer: observer)
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
            "LiveKit media \(context, privacy: .public) failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(sanitizeCallMediaDescription(nsError.localizedDescription), privacy: .public)"
        )
    }

    func disconnect(callID: String) async {
        guard let session = sessionsByCallID.removeValue(forKey: callID) else {
            return
        }
        session.room.remove(delegate: session.observer)
        await session.room.disconnect()
    }
}

private struct LiveKitCallSession {
    let room: Room
    let observer: TrixLiveKitRoomObserver
}

private final class TrixLiveKitRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let audioProbeEnabled: Bool
    private var audioProbes: [String: TrixLiveKitAudioProbe] = [:]

    init(audioProbeEnabled: Bool = false) {
        self.audioProbeEnabled = audioProbeEnabled
    }

    func attachExistingRemoteTracks(in room: Room) {
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values.compactMap({ $0 as? RemoteTrackPublication }) {
                configureRemotePublication(publication, context: "existing")
            }
        }
    }

    func roomDidConnect(_ room: Room) {
        trixCallMediaLogger.info("LiveKit room connected")
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error {
            logLiveKitError(context: "disconnect", error: error)
        } else {
            trixCallMediaLogger.info("LiveKit room disconnected")
        }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        trixCallMediaLogger.info("LiveKit remote participant connected")
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        trixCallMediaLogger.info("LiveKit remote participant disconnected")
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        trixCallMediaLogger.info(
            "LiveKit remote track published kind=\(String(describing: publication.kind), privacy: .public) encrypted=\(publication.encryptionType != .none, privacy: .public) subscribed=\(publication.isSubscribed, privacy: .public)"
        )
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        configureRemotePublication(publication, context: "subscribe")
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        audioProbes[String(describing: publication.sid)] = nil
        trixCallMediaLogger.info(
            "LiveKit remote track unsubscribed kind=\(String(describing: publication.kind), privacy: .public)"
        )
    }

    func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        logLiveKitError(context: "subscribe", error: error)
    }

    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        let stateDescription = state.toString()
        switch state {
        case .ok, .key_ratcheted:
            trixCallMediaLogger.info(
                "LiveKit track E2EE state=\(stateDescription, privacy: .public) kind=\(String(describing: trackPublication.kind), privacy: .public)"
            )
        default:
            trixCallMediaLogger.error(
                "LiveKit track E2EE state=\(stateDescription, privacy: .public) kind=\(String(describing: trackPublication.kind), privacy: .public)"
            )
        }
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        trackPublication: RemoteTrackPublication,
        didUpdateStreamState streamState: StreamState
    ) {
        trixCallMediaLogger.info(
            "LiveKit remote track stream state=\(String(describing: streamState), privacy: .public) kind=\(String(describing: trackPublication.kind), privacy: .public)"
        )
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        trixCallMediaLogger.info(
            "LiveKit speaking participants count=\(participants.count, privacy: .public)"
        )
    }

    private func configureRemotePublication(_ publication: RemoteTrackPublication, context: String) {
        let audioReady: Bool
        if let audioTrack = publication.track as? RemoteAudioTrack {
            audioTrack.volume = 1.0
            attachAudioProbeIfNeeded(to: audioTrack, publication: publication)
            audioReady = true
        } else {
            audioReady = false
        }

        trixCallMediaLogger.info(
            "LiveKit remote track \(context, privacy: .public) kind=\(String(describing: publication.kind), privacy: .public) encrypted=\(publication.encryptionType != .none, privacy: .public) muted=\(publication.isMuted, privacy: .public) stream=\(String(describing: publication.streamState), privacy: .public) audio_ready=\(audioReady, privacy: .public)"
        )
    }

    private func attachAudioProbeIfNeeded(to audioTrack: RemoteAudioTrack, publication: RemoteTrackPublication) {
        guard audioProbeEnabled else {
            return
        }

        let key = String(describing: publication.sid)
        guard audioProbes[key] == nil else {
            return
        }

        let probe = TrixLiveKitAudioProbe()
        audioTrack.add(audioRenderer: probe)
        audioProbes[key] = probe
        trixCallMediaLogger.info("LiveKit remote audio probe attached")
    }

    private func logLiveKitError(context: String, error: LiveKitError) {
        let nsError = error as NSError
        trixCallMediaLogger.error(
            "LiveKit media \(context, privacy: .public) failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(sanitizeCallMediaDescription(nsError.localizedDescription), privacy: .public)"
        )
    }
}

private final class TrixLiveKitAudioProbe: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var framesSinceLastLog: AVAudioFramePosition = 0

    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock()
        framesSinceLastLog += AVAudioFramePosition(pcmBuffer.frameLength)
        let shouldLog = framesSinceLastLog >= 48_000
        if shouldLog {
            framesSinceLastLog = 0
        }
        lock.unlock()

        if shouldLog {
            trixCallMediaLogger.info("LiveKit remote audio frames received")
        }
    }
}
#else
actor TrixLiveKitMediaCallService: TrixMediaCallService {
    init(
        forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly(),
        audioProbeEnabled: Bool = TrixCallMediaConfiguration.audioProbeEnabled()
    ) {}

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
    let deviceID: String

    private enum CodingKeys: String, CodingKey {
        case peerUserID = "peer_user_id"
        case deviceID = "device_id"
    }
}

private struct DirectCallJoinPayload: Encodable, Sendable {
    let callID: String
    let deviceID: String

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case deviceID = "device_id"
    }
}

private struct GroupVoicePayload: Encodable, Sendable {
    let roomID: String
    let deviceID: String

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case deviceID = "device_id"
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
