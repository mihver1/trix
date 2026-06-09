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
    static let audioProfileEnvironmentKey = "TRIX_CALL_AUDIO_PROFILE"
    static let videoProfileEnvironmentKey = "TRIX_CALL_VIDEO_PROFILE"

    static func forceRelayOnly(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        truthyEnvironmentValue(environment[forceRelayEnvironmentKey])
            || truthyInfoDictionaryValue("TrixCallForceRelayOnly")
    }

    static func audioProbeEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        truthyEnvironmentValue(environment[audioProbeEnvironmentKey])
            || truthyInfoDictionaryValue("TrixCallAudioProbe")
    }

    static func audioPublishProfile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TrixCallAudioPublishProfile {
        if let profile = TrixCallAudioPublishProfile(
            rawValue: environment[audioProfileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ) {
            return profile
        }

        if let infoDictionaryValue = stringInfoDictionaryValue("TrixCallAudioProfile"),
           let profile = TrixCallAudioPublishProfile(rawValue: infoDictionaryValue) {
            return profile
        }

        return .voice
    }

    static func videoPublishProfile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TrixCallVideoPublishProfile {
        if let profile = TrixCallVideoPublishProfile(
            rawValue: environment[videoProfileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        ) {
            return profile
        }

        if let infoDictionaryValue = stringInfoDictionaryValue("TrixCallVideoProfile"),
           let profile = TrixCallVideoPublishProfile(rawValue: infoDictionaryValue) {
            return profile
        }

        return .appleH264
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

    private static func stringInfoDictionaryValue(_ key: String) -> String? {
        switch Bundle.main.object(forInfoDictionaryKey: key) {
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        default:
            return nil
        }
    }
}

enum TrixCallAudioPublishProfile: String, Equatable, Sendable {
    case voice
    case lossResilient = "loss-resilient"
    case livekitDefault = "livekit-default"

    var maxBitrate: Int {
        switch self {
        case .voice, .lossResilient, .livekitDefault:
            return 48_000
        }
    }

    var dtx: Bool {
        switch self {
        case .voice, .lossResilient:
            return false
        case .livekitDefault:
            return true
        }
    }

    var red: Bool {
        switch self {
        case .voice:
            return false
        case .lossResilient, .livekitDefault:
            return true
        }
    }
}

enum TrixCallVideoPublishProfile: String, Equatable, Sendable {
    case appleH264 = "apple-h264"
    case appleH264Low = "apple-h264-low"
    case appleHEVC = "apple-hevc"
    case livekitDefault = "livekit-default"

    var codecName: String? {
        switch self {
        case .appleH264, .appleH264Low:
            return "h264"
        case .appleHEVC:
            return "h265"
        case .livekitDefault:
            return nil
        }
    }

    var backupCodecName: String? {
        switch self {
        case .appleH264, .appleH264Low:
            return "vp8"
        case .appleHEVC:
            return "h264"
        case .livekitDefault:
            return nil
        }
    }

    var maxBitrate: Int? {
        switch self {
        case .appleH264:
            return 800_000
        case .appleH264Low:
            return 450_000
        case .appleHEVC:
            return 600_000
        case .livekitDefault:
            return nil
        }
    }

    var maxFps: Int? {
        switch self {
        case .appleH264, .appleHEVC:
            return 24
        case .appleH264Low:
            return 20
        case .livekitDefault:
            return nil
        }
    }

    var captureWidth: Int32 {
        switch self {
        case .appleH264, .appleHEVC:
            return 960
        case .appleH264Low:
            return 640
        case .livekitDefault:
            return 1280
        }
    }

    var captureHeight: Int32 {
        switch self {
        case .appleH264, .appleHEVC:
            return 540
        case .appleH264Low:
            return 360
        case .livekitDefault:
            return 720
        }
    }

    var captureFps: Int {
        maxFps ?? 30
    }

    var simulcast: Bool {
        switch self {
        case .appleH264, .appleH264Low, .appleHEVC:
            return false
        case .livekitDefault:
            return true
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
    private let audioPublishProfile: TrixCallAudioPublishProfile
    private let videoPublishProfile: TrixCallVideoPublishProfile
    private static let debugLoggingConfiguredLock = NSLock()
    nonisolated(unsafe) private static var debugLoggingConfigured = false

    init(
        forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly(),
        audioProbeEnabled: Bool = TrixCallMediaConfiguration.audioProbeEnabled(),
        audioPublishProfile: TrixCallAudioPublishProfile = TrixCallMediaConfiguration.audioPublishProfile(),
        videoPublishProfile: TrixCallVideoPublishProfile = TrixCallMediaConfiguration.videoPublishProfile()
    ) {
        self.forceRelayOnly = forceRelayOnly
        self.audioProbeEnabled = audioProbeEnabled
        self.audioPublishProfile = audioPublishProfile
        self.videoPublishProfile = videoPublishProfile
    }

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        Self.configureDebugLoggingIfNeeded()
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
        let observer = TrixLiveKitRoomObserver(
            callID: authorization.callID,
            audioProbeEnabled: audioProbeEnabled
        )
        await MainActor.run {
            TrixCallMediaQualityRegistry.shared.configure(
                callID: authorization.callID,
                expectsRemoteAudio: authorization.subscribeAudio,
                expectsRemoteVideo: authorization.subscribeVideo,
                relayOnly: forceRelayOnly,
                audioProbeEnabled: audioProbeEnabled
            )
        }
        room.add(delegate: observer)
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: Self.cameraCaptureOptions(for: videoPublishProfile),
            defaultVideoPublishOptions: Self.videoPublishOptions(for: videoPublishProfile),
            defaultAudioPublishOptions: Self.audioPublishOptions(for: audioPublishProfile),
            adaptiveStream: authorization.subscribeVideo,
            dynacast: authorization.publishVideo,
            encryptionOptions: EncryptionOptions(keyProvider: keyProvider)
        )
        let connectOptions = ConnectOptions(
            iceServers: Self.iceServers(from: authorization.turn),
            iceTransportPolicy: forceRelayOnly ? .relay : .all
        )
        trixCallMediaLogger.info(
            "LiveKit media connect start kind=\(authorization.kind.rawValue, privacy: .public) relay_only=\(self.forceRelayOnly, privacy: .public) publish_audio=\(authorization.publishAudio, privacy: .public) publish_video=\(authorization.publishVideo, privacy: .public) subscribe_audio=\(authorization.subscribeAudio, privacy: .public) subscribe_video=\(authorization.subscribeVideo, privacy: .public) audio_profile=\(self.audioPublishProfile.rawValue, privacy: .public) audio_bitrate=\(self.audioPublishProfile.maxBitrate, privacy: .public) audio_dtx=\(self.audioPublishProfile.dtx, privacy: .public) audio_red=\(self.audioPublishProfile.red, privacy: .public) video_profile=\(self.videoPublishProfile.rawValue, privacy: .public) video_codec=\(self.videoPublishProfile.codecName ?? "sdk-default", privacy: .public) video_bitrate=\(self.videoPublishProfile.maxBitrate ?? 0, privacy: .public) video_fps=\(self.videoPublishProfile.maxFps ?? 0, privacy: .public) video_capture=\(self.videoPublishProfile.captureWidth, privacy: .public)x\(self.videoPublishProfile.captureHeight, privacy: .public) video_simulcast=\(self.videoPublishProfile.simulcast, privacy: .public) turn_uris=\(authorization.turn.uris.count, privacy: .public)"
        )

        let shouldPublishMicrophone = authorization.publishAudio && !audioProbeEnabled
        if authorization.publishAudio && audioProbeEnabled {
            trixCallMediaLogger.info("LiveKit media microphone skipped audio_probe=true")
        }

        if shouldPublishMicrophone {
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
            await MainActor.run {
                TrixCallMediaQualityRegistry.shared.clear(callID: authorization.callID)
            }
            Self.logMediaFailure(context: "connect", error: error)
            throw TrixClientError.callMediaUnavailable
        }

        if shouldPublishMicrophone {
            do {
                try await room.localParticipant.setMicrophone(
                    enabled: true,
                    publishOptions: Self.audioPublishOptions(for: audioPublishProfile)
                )
            } catch {
                room.remove(delegate: observer)
                await room.disconnect()
                await MainActor.run {
                    TrixCallMediaQualityRegistry.shared.clear(callID: authorization.callID)
                }
                Self.logMediaFailure(context: "microphone", error: error)
                throw TrixClientError.callMicrophoneUnavailable
            }
        }
        if authorization.publishVideo {
            do {
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: Self.cameraCaptureOptions(for: videoPublishProfile),
                    publishOptions: Self.videoPublishOptions(for: videoPublishProfile)
                )
            } catch {
                room.remove(delegate: observer)
                await room.disconnect()
                await MainActor.run {
                    TrixCallMediaQualityRegistry.shared.clear(callID: authorization.callID)
                }
                Self.logMediaFailure(context: "camera", error: error)
                throw TrixClientError.callCameraUnavailable
            }
        }

        observer.attachExistingTracks(in: room)
        sessionsByCallID[authorization.callID] = LiveKitCallSession(room: room, observer: observer)
        return TrixActiveMediaCall(
            callID: authorization.callID,
            kind: authorization.kind,
            liveKitRoom: authorization.liveKitRoom,
            startedAt: Date(),
            publishesLocalAudio: shouldPublishMicrophone,
            publishesLocalVideo: authorization.publishVideo,
            subscribesRemoteAudio: authorization.subscribeAudio,
            subscribesRemoteVideo: authorization.subscribeVideo
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

    private static func audioPublishOptions(for profile: TrixCallAudioPublishProfile) -> AudioPublishOptions {
        AudioPublishOptions(
            encoding: AudioEncoding(maxBitrate: profile.maxBitrate),
            dtx: profile.dtx,
            red: profile.red
        )
    }

    private static func cameraCaptureOptions(for profile: TrixCallVideoPublishProfile) -> CameraCaptureOptions {
        CameraCaptureOptions(
            dimensions: Dimensions(width: profile.captureWidth, height: profile.captureHeight),
            fps: profile.captureFps
        )
    }

    private static func videoPublishOptions(for profile: TrixCallVideoPublishProfile) -> VideoPublishOptions {
        guard profile != .livekitDefault else {
            return VideoPublishOptions()
        }

        return VideoPublishOptions(
            encoding: VideoEncoding(maxBitrate: profile.maxBitrate ?? 0, maxFps: profile.maxFps ?? 30),
            simulcast: profile.simulcast,
            preferredCodec: videoCodec(named: profile.codecName),
            preferredBackupCodec: videoCodec(named: profile.backupCodecName),
            degradationPreference: .maintainFramerate
        )
    }

    private static func videoCodec(named name: String?) -> VideoCodec? {
        guard let name else {
            return nil
        }

        return VideoCodec.from(name: name)
    }

    private static func configureDebugLoggingIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard truthyEnvironmentValue(environment["TRIX_CALL_LIVEKIT_DEBUG_LOGS"]) else {
            return
        }

        debugLoggingConfiguredLock.lock()
        defer {
            debugLoggingConfiguredLock.unlock()
        }
        guard !debugLoggingConfigured else {
            return
        }

        LiveKitSDK.setLogger(OSLogger(minLevel: .debug, rtc: true))
        debugLoggingConfigured = true
        trixCallMediaLogger.info("LiveKit debug logging enabled")
    }

    private static func truthyEnvironmentValue(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(normalized)
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
        session.observer.detachLocalAudioLevelProbe()
        session.room.remove(delegate: session.observer)
        await session.room.disconnect()
        await MainActor.run {
            TrixLiveKitVideoTrackRegistry.shared.clear(callID: callID)
            TrixCallAudioLevelRegistry.shared.clear(callID: callID)
            TrixCallMediaQualityRegistry.shared.clear(callID: callID)
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool, callID: String) async throws {
        guard let session = sessionsByCallID[callID] else {
            throw TrixClientError.callUnavailable
        }

        do {
            try await session.room.localParticipant.setMicrophone(
                enabled: enabled,
                publishOptions: Self.audioPublishOptions(for: audioPublishProfile)
            )
            if enabled {
                session.observer.attachExistingLocalAudioTrack(in: session.room)
            } else {
                session.observer.detachLocalAudioLevelProbe()
            }
        } catch {
            Self.logMediaFailure(context: "microphone-toggle", error: error)
            throw TrixClientError.callMicrophoneUnavailable
        }
    }

    func setCameraEnabled(_ enabled: Bool, callID: String) async throws {
        guard let session = sessionsByCallID[callID] else {
            throw TrixClientError.callUnavailable
        }

        do {
            try await session.room.localParticipant.setCamera(
                enabled: enabled,
                captureOptions: Self.cameraCaptureOptions(for: videoPublishProfile),
                publishOptions: Self.videoPublishOptions(for: videoPublishProfile)
            )
            if enabled {
                session.observer.attachExistingLocalVideoTrack(in: session.room)
            } else {
                await MainActor.run {
                    TrixLiveKitVideoTrackRegistry.shared.setLocalTrack(nil, callID: callID)
                }
            }
        } catch {
            Self.logMediaFailure(context: "camera-toggle", error: error)
            throw TrixClientError.callCameraUnavailable
        }
    }
}

private struct LiveKitCallSession {
    let room: Room
    let observer: TrixLiveKitRoomObserver
}

private final class TrixLiveKitRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let callID: String
    private let audioProbeEnabled: Bool
    private var audioProbes: [String: TrixLiveKitAudioProbe] = [:]
    private var localAudioTrack: LocalAudioTrack?
    private var localAudioLevelProbe: TrixLiveKitLocalAudioLevelProbe?

    init(callID: String, audioProbeEnabled: Bool = false) {
        self.callID = callID
        self.audioProbeEnabled = audioProbeEnabled
    }

    func attachExistingTracks(in room: Room) {
        attachExistingLocalVideoTrack(in: room)
        attachExistingLocalAudioTrack(in: room)
        attachExistingRemoteTracks(in: room)
    }

    func attachExistingLocalVideoTrack(in room: Room) {
        let track = room.localParticipant.trackPublications.values
            .compactMap { $0 as? LocalTrackPublication }
            .compactMap { $0.track as? VideoTrack }
            .first
        setLocalVideoTrack(track)
    }

    func attachExistingLocalAudioTrack(in room: Room) {
        let track = room.localParticipant.trackPublications.values
            .compactMap { $0 as? LocalTrackPublication }
            .compactMap { $0.track as? LocalAudioTrack }
            .first
        setLocalAudioTrack(track)
    }

    func detachLocalAudioLevelProbe() {
        if let localAudioLevelProbe {
            localAudioTrack?.remove(audioRenderer: localAudioLevelProbe)
        }
        localAudioTrack = nil
        localAudioLevelProbe = nil
        setLocalAudioLevel(0)
    }

    private func attachExistingRemoteTracks(in room: Room) {
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

    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let track = publication.track as? VideoTrack {
            setLocalVideoTrack(track)
        }
        if let track = publication.track as? LocalAudioTrack {
            setLocalAudioTrack(track)
        }
    }

    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if publication.track is VideoTrack {
            setLocalVideoTrack(nil)
        }
        if publication.track is LocalAudioTrack {
            detachLocalAudioLevelProbe()
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        updateRemoteMediaStatus(from: publication)
        trixCallMediaLogger.info(
            "LiveKit remote track published kind=\(String(describing: publication.kind), privacy: .public) encrypted=\(publication.encryptionType != .none, privacy: .public) subscribed=\(publication.isSubscribed, privacy: .public)"
        )
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        configureRemotePublication(publication, context: "subscribe")
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        audioProbes[String(describing: publication.sid)] = nil
        if publication.track is VideoTrack {
            setRemoteVideoTrack(nil)
        }
        updateRemoteMediaStatus(kind: publication.kind, status: .waiting)
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
        updateRemoteMediaStatus(from: trackPublication)
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
        if let videoTrack = publication.track as? VideoTrack {
            setRemoteVideoTrack(videoTrack)
        }
        updateRemoteMediaStatus(from: publication)

        trixCallMediaLogger.info(
            "LiveKit remote track \(context, privacy: .public) kind=\(String(describing: publication.kind), privacy: .public) encrypted=\(publication.encryptionType != .none, privacy: .public) muted=\(publication.isMuted, privacy: .public) stream=\(String(describing: publication.streamState), privacy: .public) audio_ready=\(audioReady, privacy: .public)"
        )
    }

    private func setLocalVideoTrack(_ track: VideoTrack?) {
        Task { @MainActor [callID] in
            TrixLiveKitVideoTrackRegistry.shared.setLocalTrack(track, callID: callID)
        }
    }

    private func setRemoteVideoTrack(_ track: VideoTrack?) {
        Task { @MainActor [callID] in
            TrixLiveKitVideoTrackRegistry.shared.setRemoteTrack(track, callID: callID)
        }
    }

    private func setLocalAudioTrack(_ track: LocalAudioTrack?) {
        if localAudioTrack == nil, track == nil {
            return
        }
        if let localAudioTrack, let track, localAudioTrack === track {
            return
        }

        if let localAudioLevelProbe {
            localAudioTrack?.remove(audioRenderer: localAudioLevelProbe)
        }

        localAudioTrack = track
        guard let track else {
            localAudioLevelProbe = nil
            setLocalAudioLevel(0)
            return
        }

        let probe = TrixLiveKitLocalAudioLevelProbe(callID: callID)
        localAudioLevelProbe = probe
        track.add(audioRenderer: probe)
    }

    private func setLocalAudioLevel(_ level: Double) {
        Task { @MainActor [callID] in
            TrixCallAudioLevelRegistry.shared.setLevel(level, callID: callID)
        }
    }

    private func attachAudioProbeIfNeeded(to audioTrack: RemoteAudioTrack, publication: RemoteTrackPublication) {
        guard audioProbeEnabled else {
            return
        }

        let key = String(describing: publication.sid)
        guard audioProbes[key] == nil else {
            return
        }

        let probe = TrixLiveKitAudioProbe(callID: callID)
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

    private func updateRemoteMediaStatus(from publication: RemoteTrackPublication) {
        updateRemoteMediaStatus(kind: publication.kind, status: Self.status(from: publication))
    }

    private func updateRemoteMediaStatus(kind: Track.Kind, status: TrixCallMediaSignalStatus) {
        let mediaKind: TrixCallMediaKind?
        switch kind {
        case .audio:
            mediaKind = .audio
        case .video:
            mediaKind = .video
        case .none:
            mediaKind = nil
        @unknown default:
            mediaKind = nil
        }

        guard let mediaKind else {
            return
        }

        Task { @MainActor [callID] in
            TrixCallMediaQualityRegistry.shared.updateRemoteMedia(
                callID: callID,
                kind: mediaKind,
                status: status
            )
        }
    }

    private static func status(from publication: RemoteTrackPublication) -> TrixCallMediaSignalStatus {
        if publication.isMuted {
            return .muted
        }

        if publication.streamState == .paused {
            return .paused
        }

        guard publication.isSubscribed, publication.track != nil else {
            return .waiting
        }

        return .receiving
    }
}

private final class TrixLiveKitAudioProbe: NSObject, AudioRenderer, @unchecked Sendable {
    private let callID: String
    private let lock = NSLock()
    private var framesSinceLastLog: AVAudioFramePosition = 0

    init(callID: String) {
        self.callID = callID
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock()
        framesSinceLastLog += AVAudioFramePosition(pcmBuffer.frameLength)
        let shouldLog = framesSinceLastLog >= 48_000
        if shouldLog {
            framesSinceLastLog = 0
        }
        lock.unlock()

        if shouldLog {
            Task { @MainActor [callID] in
                TrixCallMediaQualityRegistry.shared.noteRemoteAudioFrame(callID: callID)
            }
            trixCallMediaLogger.info("LiveKit remote audio frames received")
        }
    }
}

private final class TrixLiveKitLocalAudioLevelProbe: NSObject, AudioRenderer, @unchecked Sendable {
    private let callID: String
    private let lock = NSLock()
    private var lastUpdateTime: TimeInterval = 0
    private var smoothedLevel: Double = 0

    init(callID: String) {
        self.callID = callID
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let rawLevel = Self.normalizedLevel(from: pcmBuffer)
        let now = Date().timeIntervalSinceReferenceDate
        var levelToEmit: Double?

        lock.lock()
        if rawLevel >= smoothedLevel {
            smoothedLevel = smoothedLevel * 0.35 + rawLevel * 0.65
        } else {
            smoothedLevel = smoothedLevel * 0.82 + rawLevel * 0.18
        }

        if now - lastUpdateTime >= 1.0 / 15.0 {
            lastUpdateTime = now
            levelToEmit = smoothedLevel < 0.02 ? 0 : smoothedLevel
        }
        lock.unlock()

        guard let levelToEmit else {
            return
        }

        Task { @MainActor [callID] in
            TrixCallAudioLevelRegistry.shared.setLevel(levelToEmit, callID: callID)
        }
    }

    private static func normalizedLevel(from pcmBuffer: AVAudioPCMBuffer) -> Double {
        let frameCount = Int(pcmBuffer.frameLength)
        let channelCount = Int(pcmBuffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return 0
        }

        if let floatChannelData = pcmBuffer.floatChannelData {
            var squareSum: Double = 0
            var sampleCount = 0
            for channelIndex in 0..<channelCount {
                let samples = floatChannelData[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = Double(samples[frameIndex])
                    squareSum += sample * sample
                }
                sampleCount += frameCount
            }
            return normalizedLevel(squareSum: squareSum, sampleCount: sampleCount)
        }

        if let int16ChannelData = pcmBuffer.int16ChannelData {
            var squareSum: Double = 0
            var sampleCount = 0
            for channelIndex in 0..<channelCount {
                let samples = int16ChannelData[channelIndex]
                for frameIndex in 0..<frameCount {
                    let sample = Double(samples[frameIndex]) / Double(Int16.max)
                    squareSum += sample * sample
                }
                sampleCount += frameCount
            }
            return normalizedLevel(squareSum: squareSum, sampleCount: sampleCount)
        }

        return 0
    }

    private static func normalizedLevel(squareSum: Double, sampleCount: Int) -> Double {
        guard squareSum > 0, sampleCount > 0 else {
            return 0
        }

        let rms = sqrt(squareSum / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 55) / 40, 0), 1)
    }
}
#else
actor TrixLiveKitMediaCallService: TrixMediaCallService {
    init(
        forceRelayOnly: Bool = TrixCallMediaConfiguration.forceRelayOnly(),
        audioProbeEnabled: Bool = TrixCallMediaConfiguration.audioProbeEnabled(),
        audioPublishProfile: TrixCallAudioPublishProfile = TrixCallMediaConfiguration.audioPublishProfile(),
        videoPublishProfile: TrixCallVideoPublishProfile = TrixCallMediaConfiguration.videoPublishProfile()
    ) {}

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        throw TrixClientError.callMediaUnavailable
    }

    func setMicrophoneEnabled(_ enabled: Bool, callID: String) async throws {
        throw TrixClientError.callMediaUnavailable
    }

    func setCameraEnabled(_ enabled: Bool, callID: String) async throws {
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
