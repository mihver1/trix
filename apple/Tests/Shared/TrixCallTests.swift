import Foundation
import Security
import XCTest
@testable import Trix

final class TrixCallTests: XCTestCase {
    func testCallInviteDescriptorCarriesMediaKeyOnlyInsideEncryptedCallDescriptor() throws {
        let mediaKey = try TrixCallMediaKey(
            keyID: "key-1",
            key: "base64-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let invite = TrixCallInvite(
            callID: "call-1",
            kind: .directVideo,
            roomID: "friend@trix.selfhost.ru",
            senderID: "alice@trix.selfhost.ru",
            liveKitRoom: "trix-dm-room",
            createdAtUnix: 100,
            expiresAtUnix: 200,
            mediaKey: mediaKey
        )

        let data = try JSONEncoder().encode(invite)
        let decoded = try JSONDecoder().decode(TrixCallInvite.self, from: data)

        XCTAssertEqual(decoded.event, .invite)
        XCTAssertEqual(decoded.kind, .directVideo)
        XCTAssertEqual(decoded.mediaKey, mediaKey)
    }

    func testVoipPayloadAcceptsOnlyOpaqueCallID() {
        let payload = TrixVoIPCallPayload(userInfo: [
            "aps": [:],
            "trix": [
                "call_id": "call-opaque-id",
                "account": "alice@trix.selfhost.ru",
            ],
        ])

        XCTAssertTrue(payload.isCallNotification)
        XCTAssertEqual(payload.callID, "call-opaque-id")
        XCTAssertEqual(payload.accountID, "alice@trix.selfhost.ru")
    }

    func testVoipPayloadRejectsMediaSecretsAndRoomMetadata() {
        let payload = TrixVoIPCallPayload(userInfo: [
            "aps": [:],
            "trix": [
                "call_id": "call-opaque-id",
                "livekit_token": "server-token",
                "media_key": "secret",
                "room": "friend@trix.selfhost.ru",
            ],
        ])

        XCTAssertFalse(payload.isCallNotification)
    }

    func testRegularPushPayloadRejectsCallMediaSecrets() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "content-available": 1,
            ],
            "trix": [
                "type": "sync",
                "livekit_token": "server-token",
            ],
        ])

        XCTAssertFalse(payload.isSyncNotification)
    }

    func testCallMediaRelayOnlySmokeFlagIsOptIn() {
        XCTAssertFalse(TrixCallMediaConfiguration.forceRelayOnly(environment: [:]))
        XCTAssertFalse(TrixCallMediaConfiguration.forceRelayOnly(environment: [
            TrixCallMediaConfiguration.forceRelayEnvironmentKey: "0",
        ]))
        XCTAssertFalse(TrixCallMediaConfiguration.forceRelayOnly(environment: [
            TrixCallMediaConfiguration.forceRelayEnvironmentKey: "false",
        ]))
        XCTAssertTrue(TrixCallMediaConfiguration.forceRelayOnly(environment: [
            TrixCallMediaConfiguration.forceRelayEnvironmentKey: "1",
        ]))
        XCTAssertTrue(TrixCallMediaConfiguration.forceRelayOnly(environment: [
            TrixCallMediaConfiguration.forceRelayEnvironmentKey: " yes ",
        ]))
    }

    func testCallAudioPublishProfileDefaultsToVoiceProfile() {
        let profile = TrixCallMediaConfiguration.audioPublishProfile(environment: [:])

        XCTAssertEqual(profile, .voice)
        XCTAssertEqual(profile.maxBitrate, 48_000)
        XCTAssertFalse(profile.dtx)
        XCTAssertFalse(profile.red)
    }

    func testCallAudioPublishProfileCanSelectLossResilientAndLiveKitDefault() {
        let lossResilient = TrixCallMediaConfiguration.audioPublishProfile(environment: [
            TrixCallMediaConfiguration.audioProfileEnvironmentKey: " loss-resilient ",
        ])
        XCTAssertEqual(lossResilient, .lossResilient)
        XCTAssertFalse(lossResilient.dtx)
        XCTAssertTrue(lossResilient.red)

        let liveKitDefault = TrixCallMediaConfiguration.audioPublishProfile(environment: [
            TrixCallMediaConfiguration.audioProfileEnvironmentKey: "livekit-default",
        ])
        XCTAssertEqual(liveKitDefault, .livekitDefault)
        XCTAssertTrue(liveKitDefault.dtx)
        XCTAssertTrue(liveKitDefault.red)
    }

    func testCallAudioPublishProfileFallsBackToVoiceForUnknownValue() {
        XCTAssertEqual(
            TrixCallMediaConfiguration.audioPublishProfile(environment: [
                TrixCallMediaConfiguration.audioProfileEnvironmentKey: "unknown",
            ]),
            .voice
        )
    }

    func testCallVideoPublishProfileDefaultsToAppleH264() {
        let profile = TrixCallMediaConfiguration.videoPublishProfile(environment: [:])

        XCTAssertEqual(profile, .appleH264)
        XCTAssertEqual(profile.codecName, "h264")
        XCTAssertEqual(profile.backupCodecName, "vp8")
        XCTAssertEqual(profile.maxBitrate, 800_000)
        XCTAssertEqual(profile.maxFps, 24)
        XCTAssertEqual(profile.captureWidth, 960)
        XCTAssertEqual(profile.captureHeight, 540)
        XCTAssertEqual(profile.captureFps, 24)
        XCTAssertFalse(profile.simulcast)
    }

    func testCallVideoPublishProfileCanSelectDiagnosticProfiles() {
        let low = TrixCallMediaConfiguration.videoPublishProfile(environment: [
            TrixCallMediaConfiguration.videoProfileEnvironmentKey: " apple-h264-low ",
        ])
        XCTAssertEqual(low, .appleH264Low)
        XCTAssertEqual(low.codecName, "h264")
        XCTAssertEqual(low.maxBitrate, 450_000)
        XCTAssertEqual(low.maxFps, 20)
        XCTAssertEqual(low.captureWidth, 640)
        XCTAssertEqual(low.captureHeight, 360)
        XCTAssertFalse(low.simulcast)

        let hevc = TrixCallMediaConfiguration.videoPublishProfile(environment: [
            TrixCallMediaConfiguration.videoProfileEnvironmentKey: "apple-hevc",
        ])
        XCTAssertEqual(hevc, .appleHEVC)
        XCTAssertEqual(hevc.codecName, "h265")
        XCTAssertEqual(hevc.backupCodecName, "h264")
        XCTAssertEqual(hevc.maxBitrate, 600_000)
        XCTAssertEqual(hevc.maxFps, 24)
        XCTAssertEqual(hevc.captureWidth, 960)
        XCTAssertEqual(hevc.captureHeight, 540)
        XCTAssertFalse(hevc.simulcast)

        let liveKitDefault = TrixCallMediaConfiguration.videoPublishProfile(environment: [
            TrixCallMediaConfiguration.videoProfileEnvironmentKey: "livekit-default",
        ])
        XCTAssertEqual(liveKitDefault, .livekitDefault)
        XCTAssertNil(liveKitDefault.codecName)
        XCTAssertNil(liveKitDefault.backupCodecName)
        XCTAssertNil(liveKitDefault.maxBitrate)
        XCTAssertNil(liveKitDefault.maxFps)
        XCTAssertEqual(liveKitDefault.captureWidth, 1280)
        XCTAssertEqual(liveKitDefault.captureHeight, 720)
        XCTAssertEqual(liveKitDefault.captureFps, 30)
        XCTAssertTrue(liveKitDefault.simulcast)
    }

    func testCallVideoPublishProfileFallsBackToAppleH264ForUnknownValue() {
        XCTAssertEqual(
            TrixCallMediaConfiguration.videoPublishProfile(environment: [
                TrixCallMediaConfiguration.videoProfileEnvironmentKey: "unknown",
            ]),
            .appleH264
        )
    }

    @MainActor
    func testCallAudioLevelRegistryFlagsLowMicInputAfterGracePeriod() {
        let registry = TrixCallAudioLevelRegistry.shared
        let callID = "call-low-mic-\(UUID().uuidString)"
        let startedAt = Date(timeIntervalSince1970: 100)
        defer {
            registry.clear(callID: callID)
        }

        XCTAssertEqual(
            registry.localInputSignalState(
                callID: callID,
                audioState: .unmuted,
                startedAt: startedAt,
                now: Date(timeIntervalSince1970: 103)
            ),
            .detecting
        )
        XCTAssertEqual(
            registry.localInputSignalState(
                callID: callID,
                audioState: .unmuted,
                startedAt: startedAt,
                now: Date(timeIntervalSince1970: 106)
            ),
            .low
        )

        registry.setLevel(0.18, callID: callID, now: Date(timeIntervalSince1970: 107))
        XCTAssertEqual(
            registry.localInputSignalState(
                callID: callID,
                audioState: .unmuted,
                startedAt: startedAt,
                now: Date(timeIntervalSince1970: 108)
            ),
            .active
        )

        registry.setLevel(0, callID: callID, now: Date(timeIntervalSince1970: 109))
        XCTAssertEqual(
            registry.localInputSignalState(
                callID: callID,
                audioState: .unmuted,
                startedAt: startedAt,
                now: Date(timeIntervalSince1970: 112)
            ),
            .low
        )
        XCTAssertEqual(
            registry.localInputSignalState(
                callID: callID,
                audioState: .muted,
                startedAt: startedAt,
                now: Date(timeIntervalSince1970: 112)
            ),
            .muted
        )
    }

    @MainActor
    func testCallMediaQualityRegistryTracksRemoteMediaAndRelayStatus() {
        let registry = TrixCallMediaQualityRegistry.shared
        let callID = "call-quality-\(UUID().uuidString)"
        defer {
            registry.clear(callID: callID)
        }

        registry.configure(
            callID: callID,
            expectsRemoteAudio: true,
            expectsRemoteVideo: false,
            relayOnly: true,
            audioProbeEnabled: true,
            now: Date(timeIntervalSince1970: 100)
        )
        var snapshot = registry.snapshot(for: callID)
        XCTAssertTrue(snapshot.relayOnly)
        XCTAssertTrue(snapshot.audioProbeEnabled)
        XCTAssertEqual(snapshot.remoteAudioStatus, .waiting)
        XCTAssertEqual(snapshot.remoteVideoStatus, .unavailable)

        registry.updateRemoteMedia(
            callID: callID,
            kind: .audio,
            status: .receiving,
            now: Date(timeIntervalSince1970: 101)
        )
        snapshot = registry.snapshot(for: callID)
        XCTAssertEqual(snapshot.remoteAudioStatus, .receiving)
        XCTAssertNil(snapshot.lastRemoteAudioFrameAt)

        registry.noteRemoteAudioFrame(callID: callID, now: Date(timeIntervalSince1970: 102))
        snapshot = registry.snapshot(for: callID)
        XCTAssertEqual(snapshot.remoteAudioStatus, .receiving)
        XCTAssertEqual(snapshot.lastRemoteAudioFrameAt, Date(timeIntervalSince1970: 102))

        registry.updateRemoteMedia(
            callID: callID,
            kind: .audio,
            status: .paused,
            now: Date(timeIntervalSince1970: 103)
        )
        XCTAssertEqual(registry.snapshot(for: callID).remoteAudioStatus, .paused)
    }

    func testCallControlFailuresExposeLayerSpecificMessages() {
        let removedGenericMessage = "Encrypted calls are not available yet."

        XCTAssertNotEqual(TrixClientError.callAuthenticationUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callControlNetworkUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callControlInvalidResponse.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callControlRejected(422).trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callDescriptorUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callMicrophonePermissionRequired.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callCameraPermissionRequired.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callMicrophoneUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertNotEqual(TrixClientError.callCameraUnavailable.trixUserFacingMessage, removedGenericMessage)
        XCTAssertEqual(
            TrixClientError.callControlRejected(422).trixUserFacingMessage,
            "Call control rejected the request (HTTP 422)."
        )
        XCTAssertEqual(
            TrixClientError.callMicrophonePermissionRequired.trixUserFacingMessage,
            "Allow microphone access before joining encrypted calls."
        )
    }

    @MainActor
    func testExpiredIncomingInviteProducesIdleLifecycleState() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "bob@trix.selfhost.ru", kind: .direct)
        let mediaKey = try TrixCallMediaKey(
            keyID: "expired-key",
            key: "base64-call-key",
            keyIndex: 0,
            createdAtUnix: 10
        )
        let invite = TrixCallInvite(
            callID: "expired-call",
            kind: .directVideo,
            roomID: room.id,
            senderID: "bob@trix.selfhost.ru",
            liveKitRoom: "dm-room",
            createdAtUnix: 10,
            expiresAtUnix: 11,
            mediaKey: mediaKey
        )
        await descriptors.appendRemote(.invite(invite), roomID: room.id, senderID: invite.senderID)

        await viewModel.loadRoomCallState(room: room, session: session)

        let state = viewModel.callLifecycleState(roomID: room.id)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.callID)
        XCTAssertEqual(state.platformSurfaceState, .none)
        XCTAssertNil(viewModel.incomingDirectCall(roomID: room.id))
    }

    @MainActor
    func testAcceptIncomingDirectCallAndEndTransitionsLifecycleAndClearsIncomingSurface() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "bob@trix.selfhost.ru", kind: .direct)
        let mediaKey = try TrixCallMediaKey(
            keyID: "incoming-key",
            key: "base64-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let invite = TrixCallInvite(
            callID: "incoming-call",
            kind: .directVideo,
            roomID: room.id,
            senderID: "bob@trix.selfhost.ru",
            liveKitRoom: "dm-room",
            createdAtUnix: 100,
            expiresAtUnix: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970),
            mediaKey: mediaKey
        )
        await descriptors.appendRemote(.invite(invite), roomID: room.id, senderID: invite.senderID)

        await viewModel.loadRoomCallState(room: room, session: session)
        let ringingState = viewModel.callLifecycleState(roomID: room.id)
        XCTAssertEqual(ringingState.phase, .incomingRinging)
        XCTAssertEqual(ringingState.callID, "incoming-call")
        XCTAssertEqual(ringingState.kind, .directVideo)
        XCTAssertEqual(ringingState.platformSurfaceState, .incomingDirectCallBar)

        let incomingCall = try XCTUnwrap(viewModel.incomingDirectCall(roomID: room.id))
        let accepted = await viewModel.acceptIncomingDirectCall(incomingCall, session: session)

        let activeState = viewModel.callLifecycleState(roomID: room.id)
        XCTAssertTrue(accepted)
        XCTAssertEqual(activeState.phase, .active)
        XCTAssertEqual(activeState.callID, "incoming-call")
        XCTAssertEqual(activeState.startedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(activeState.localAudioState, .unmuted)
        XCTAssertEqual(activeState.localCameraState, .on)
        XCTAssertEqual(activeState.remoteMediaReadiness, .waiting)
        XCTAssertEqual(activeState.platformSurfaceState, .directCallBar)
        XCTAssertNil(viewModel.incomingDirectCall(roomID: room.id))

        let ended = await viewModel.endCall(roomID: room.id, session: session)
        let endedState = viewModel.callLifecycleState(roomID: room.id)
        XCTAssertTrue(ended)
        XCTAssertEqual(endedState.phase, .ended)
        XCTAssertEqual(endedState.callID, "incoming-call")
        XCTAssertEqual(endedState.platformSurfaceState, .none)
        XCTAssertNil(viewModel.currentCall(roomID: room.id, kind: .directVideo))
    }

    @MainActor
    func testStartingCallInAnotherRoomEndsPreviousLifecycleAndActivatesNewRoom() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()

        await viewModel.startDirectVideoCall(
            peerUserID: "bob@trix.selfhost.ru",
            roomID: "bob@trix.selfhost.ru",
            session: session
        )
        await viewModel.startDirectVideoCall(
            peerUserID: "carol@trix.selfhost.ru",
            roomID: "carol@trix.selfhost.ru",
            session: session
        )

        let firstState = viewModel.callLifecycleState(roomID: "bob@trix.selfhost.ru")
        let secondState = viewModel.callLifecycleState(roomID: "carol@trix.selfhost.ru")
        let endedCallIDs = await callControl.endedCallIDs()
        let disconnectedCallIDs = await media.disconnectedCallIDs()
        XCTAssertEqual(firstState.phase, .ended)
        XCTAssertEqual(firstState.callID, "call-1")
        XCTAssertEqual(secondState.phase, .active)
        XCTAssertEqual(secondState.callID, "call-2")
        XCTAssertEqual(viewModel.currentCall(roomID: "carol@trix.selfhost.ru", kind: .directVideo)?.callID, "call-2")
        XCTAssertEqual(endedCallIDs, ["call-1"])
        XCTAssertEqual(disconnectedCallIDs, ["call-1"])
    }

    @MainActor
    func testGroupVoiceLifecycleConvergesParticipantsFromLatestDescriptor() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "friends@conference.trix.selfhost.ru", kind: .group)
        let mediaKey = try TrixCallMediaKey(
            keyID: "group-key",
            key: "base64-group-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let staleState = TrixVoiceRoomState(
            callID: "group-call",
            roomID: room.id,
            activeParticipantIDs: ["alice@trix.selfhost.ru"],
            mediaKey: mediaKey,
            updatedAtUnix: 100
        )
        let latestState = TrixVoiceRoomState(
            callID: "group-call",
            roomID: room.id,
            activeParticipantIDs: [
                " bob@trix.selfhost.ru ",
                "BOB@trix.selfhost.ru",
                "carol@trix.selfhost.ru",
            ],
            mediaKey: mediaKey,
            updatedAtUnix: 200
        )
        await descriptors.appendRemote(.voiceRoomState(staleState), roomID: room.id, senderID: "alice@trix.selfhost.ru")
        await descriptors.appendRemote(.voiceRoomState(latestState), roomID: room.id, senderID: "bob@trix.selfhost.ru")

        await viewModel.loadRoomCallState(room: room, session: session)

        let state = viewModel.callLifecycleState(roomID: room.id)
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.callID, "group-call")
        XCTAssertEqual(state.kind, .groupVoice)
        XCTAssertEqual(state.participantIDs, ["bob@trix.selfhost.ru", "carol@trix.selfhost.ru"])
        XCTAssertEqual(state.platformSurfaceState, .groupVoiceRoomBar)
    }

    @MainActor
    func testDirectVideoMediaControlsUpdateLifecycleWithoutDisconnecting() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let roomID = "bob@trix.selfhost.ru"

        await viewModel.startDirectVideoCall(
            peerUserID: "bob@trix.selfhost.ru",
            roomID: roomID,
            session: session
        )

        let didMuteMicrophone = await viewModel.setMicrophoneMuted(true, roomID: roomID)
        let didDisableCamera = await viewModel.setCameraEnabled(false, roomID: roomID)
        let didUnmuteMicrophone = await viewModel.setMicrophoneMuted(false, roomID: roomID)
        let didEnableCamera = await viewModel.setCameraEnabled(true, roomID: roomID)
        XCTAssertTrue(didMuteMicrophone)
        XCTAssertTrue(didDisableCamera)
        XCTAssertTrue(didUnmuteMicrophone)
        XCTAssertTrue(didEnableCamera)

        let state = viewModel.callLifecycleState(roomID: roomID)
        let microphoneChanges = await media.microphoneChanges()
        let cameraChanges = await media.cameraChanges()
        let disconnectedCallIDs = await media.disconnectedCallIDs()
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.localAudioState, .unmuted)
        XCTAssertEqual(state.localCameraState, .on)
        XCTAssertEqual(microphoneChanges, [
            RecordingMediaChange(callID: "call-1", enabled: false),
            RecordingMediaChange(callID: "call-1", enabled: true),
        ])
        XCTAssertEqual(cameraChanges, [
            RecordingMediaChange(callID: "call-1", enabled: false),
            RecordingMediaChange(callID: "call-1", enabled: true),
        ])
        XCTAssertEqual(disconnectedCallIDs, [])
    }

    @MainActor
    func testActiveMediaStateMapsPublishSubscribeCapabilities() async throws {
        let callControl = RecordingCallControlService(
            directVideoAuthorization: RecordingCallControlService.authorization(
                kind: .directVideo,
                liveKitRoom: "dm-room",
                publishAudio: false,
                publishVideo: true,
                subscribeAudio: false,
                subscribeVideo: false
            )
        )
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )

        await viewModel.startDirectVideoCall(
            peerUserID: "bob@trix.selfhost.ru",
            roomID: "bob@trix.selfhost.ru",
            session: Self.session()
        )

        let state = viewModel.callLifecycleState(roomID: "bob@trix.selfhost.ru")
        XCTAssertEqual(state.phase, .active)
        XCTAssertEqual(state.localAudioState, .unavailable)
        XCTAssertEqual(state.localCameraState, .on)
        XCTAssertEqual(state.remoteMediaReadiness, .none)
    }

    func testForegroundCallCueRingsOnlyForIncomingDirectCalls() {
        let incomingDirect = TrixCallLifecycleState(
            phase: .incomingRinging,
            roomID: "bob@trix.selfhost.ru",
            callID: "incoming-call",
            kind: .directVideo,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101),
            expiresAt: Date(timeIntervalSince1970: 160),
            participantIDs: ["bob@trix.selfhost.ru"],
            localAudioState: .unavailable,
            localCameraState: .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .incomingDirectCallBar
        )
        let groupVoice = TrixCallLifecycleState(
            phase: .active,
            roomID: "friends@conference.trix.selfhost.ru",
            callID: "group-call",
            kind: .groupVoice,
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: nil,
            participantIDs: ["bob@trix.selfhost.ru"],
            localAudioState: .unavailable,
            localCameraState: .unavailable,
            remoteMediaReadiness: .none,
            platformSurfaceState: .groupVoiceRoomBar
        )

        XCTAssertEqual(incomingDirect.foregroundCue, .incomingDirectCall(callID: "incoming-call"))
        XCTAssertEqual(groupVoice.foregroundCue, .none)
    }

    func testRoomListCallIndicatorShowsIncomingAndActiveDirectCalls() {
        let incomingState = TrixCallLifecycleState(
            phase: .incomingRinging,
            roomID: "bob@trix.selfhost.ru",
            callID: "incoming-call",
            kind: .directVideo,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101),
            expiresAt: Date(timeIntervalSince1970: 160),
            participantIDs: ["bob@trix.selfhost.ru"],
            localAudioState: .unavailable,
            localCameraState: .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .incomingDirectCallBar
        )
        let activeState = TrixCallLifecycleState(
            phase: .active,
            roomID: "carol@trix.selfhost.ru",
            callID: "active-call",
            kind: .directVideo,
            startedAt: Date(timeIntervalSince1970: 120),
            updatedAt: Date(timeIntervalSince1970: 121),
            expiresAt: nil,
            participantIDs: ["alice@trix.selfhost.ru", "carol@trix.selfhost.ru"],
            localAudioState: .unmuted,
            localCameraState: .on,
            remoteMediaReadiness: .waiting,
            platformSurfaceState: .directCallBar
        )

        XCTAssertEqual(TrixRoomCallIndicator(state: incomingState)?.kind, .incomingDirect)
        XCTAssertEqual(TrixRoomCallIndicator(state: incomingState)?.title, "Incoming")
        XCTAssertTrue(TrixRoomCallIndicator(state: incomingState)?.isRinging == true)
        XCTAssertEqual(TrixRoomCallIndicator(state: activeState)?.kind, .directCall)
        XCTAssertEqual(TrixRoomCallIndicator(state: activeState)?.title, "In call")
        XCTAssertFalse(TrixRoomCallIndicator(state: activeState)?.isRinging == true)
    }

    func testRoomListCallIndicatorShowsJoinableGroupVoiceWithoutRinging() {
        let state = TrixCallLifecycleState(
            phase: .active,
            roomID: "friends@conference.trix.selfhost.ru",
            callID: "group-call",
            kind: .groupVoice,
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 200),
            expiresAt: nil,
            participantIDs: [
                "bob@trix.selfhost.ru",
                "carol@trix.selfhost.ru",
            ],
            localAudioState: .unavailable,
            localCameraState: .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .groupVoiceRoomBar
        )

        let indicator = TrixRoomCallIndicator(state: state)

        XCTAssertEqual(indicator?.kind, .groupVoice)
        XCTAssertEqual(indicator?.title, "Voice live")
        XCTAssertEqual(indicator?.participantCount, 2)
        XCTAssertFalse(indicator?.isRinging == true)
    }

    @MainActor
    func testPrepareDirectVideoCallSendsInviteDescriptorBeforeMediaConnect() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()

        let prepared = await viewModel.prepareDirectVideoCall(
            peerUserID: "bob@trix.selfhost.ru",
            roomID: "bob@trix.selfhost.ru",
            session: session
        )

        let sentDescriptors = await descriptors.sentDescriptors()
        let mediaConnects = await media.connectedCallIDs()
        let state = viewModel.callLifecycleState(roomID: "bob@trix.selfhost.ru")
        XCTAssertNotNil(prepared)
        XCTAssertEqual(sentDescriptors.map(\.descriptor.event), [.invite])
        XCTAssertEqual(sentDescriptors.first?.roomID, "bob@trix.selfhost.ru")
        XCTAssertEqual(mediaConnects, [])
        XCTAssertEqual(state.phase, .outgoingRinging)
        XCTAssertEqual(state.callID, "call-1")
        XCTAssertEqual(state.kind, .directVideo)
    }

    @MainActor
    func testDisconnectSendsEncryptedCallEndDescriptor() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()

        _ = await viewModel.prepareDirectVideoCall(
            peerUserID: "bob@trix.selfhost.ru",
            roomID: "bob@trix.selfhost.ru",
            session: session
        )
        await viewModel.connectPreparedCall()
        await viewModel.disconnect(session: session)

        let sentDescriptors = await descriptors.sentDescriptors()
        let endedCallIDs = await callControl.endedCallIDs()
        let disconnectedCallIDs = await media.disconnectedCallIDs()
        XCTAssertEqual(sentDescriptors.map(\.descriptor.event), [.invite, .end])
        XCTAssertEqual(endedCallIDs, ["call-1"])
        XCTAssertEqual(disconnectedCallIDs, ["call-1"])
    }

    @MainActor
    func testAcceptIncomingDirectCallJoinsExistingCallAndSendsAnswer() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "bob@trix.selfhost.ru", kind: .direct)
        let mediaKey = try TrixCallMediaKey(
            keyID: "incoming-key",
            key: "base64-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let invite = TrixCallInvite(
            callID: "incoming-call",
            kind: .directVideo,
            roomID: room.id,
            senderID: "bob@trix.selfhost.ru",
            liveKitRoom: "dm-room",
            createdAtUnix: 100,
            expiresAtUnix: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970),
            mediaKey: mediaKey
        )
        await descriptors.appendRemote(.invite(invite), roomID: room.id, senderID: invite.senderID)

        await viewModel.loadRoomCallState(room: room, session: session)
        let incomingCall = try XCTUnwrap(viewModel.incomingDirectCall(roomID: room.id))
        let accepted = await viewModel.acceptIncomingDirectCall(incomingCall, session: session)

        let sentDescriptors = await descriptors.sentDescriptors()
        let joinedCallIDs = await callControl.joinedDirectCallIDs()
        let mediaConnects = await media.connectedCallIDs()
        XCTAssertTrue(accepted)
        XCTAssertEqual(joinedCallIDs, ["incoming-call"])
        XCTAssertEqual(mediaConnects, ["incoming-call"])
        XCTAssertEqual(sentDescriptors.map(\.descriptor.event), [.invite, .answer])
    }

    @MainActor
    func testJoinGroupVoiceRoomSendsVoiceStateWithoutGroupInvite() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "friends@conference.trix.selfhost.ru", kind: .group)

        await viewModel.joinGroupVoiceRoom(roomID: room.id, session: session)

        let sentDescriptors = await descriptors.sentDescriptors()
        let mediaConnects = await media.connectedCallIDs()
        XCTAssertEqual(sentDescriptors.map(\.descriptor.event), [.voiceRoomState])
        XCTAssertEqual(mediaConnects, ["call-1"])
        if case .voiceRoomState(let state) = sentDescriptors.first?.descriptor {
            XCTAssertEqual(state.activeParticipantIDs, [session.userID])
            let mediaKey = try XCTUnwrap(state.mediaKey)
            let connectedMediaKeys = await media.connectedMediaKeys()
            XCTAssertEqual(connectedMediaKeys, [mediaKey])
        } else {
            XCTFail("Expected a voice-room state descriptor")
        }
    }

    @MainActor
    func testJoinGroupVoiceRoomReusesExistingEncryptedMediaKey() async throws {
        let callControl = RecordingCallControlService()
        let descriptors = RecordingCallDescriptorService()
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )
        let session = Self.session()
        let room = Self.room(id: "friends@conference.trix.selfhost.ru", kind: .group)
        let existingMediaKey = try TrixCallMediaKey(
            keyID: "group-key",
            key: "base64-group-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let existingState = TrixVoiceRoomState(
            callID: "group-call",
            roomID: room.id,
            activeParticipantIDs: ["bob@trix.selfhost.ru"],
            mediaKey: existingMediaKey,
            updatedAtUnix: 100
        )
        await descriptors.appendRemote(
            .voiceRoomState(existingState),
            roomID: room.id,
            senderID: "bob@trix.selfhost.ru"
        )

        await viewModel.joinGroupVoiceRoom(roomID: room.id, session: session)

        let sentDescriptors = await descriptors.sentDescriptors()
        let connectedMediaKeys = await media.connectedMediaKeys()
        XCTAssertEqual(connectedMediaKeys, [existingMediaKey])
        if case .voiceRoomState(let state) = sentDescriptors.last?.descriptor {
            XCTAssertEqual(state.mediaKey, existingMediaKey)
            XCTAssertEqual(
                Set(state.activeParticipantIDs.map { $0.lowercased() }),
                Set(["bob@trix.selfhost.ru", session.userID.lowercased()])
            )
        } else {
            XCTFail("Expected the latest descriptor to be a voice-room state")
        }
    }

    @MainActor
    func testJoinGroupVoiceRoomRefreshesMediaKeyAfterAuthorization() async throws {
        let callControl = RecordingCallControlService()
        let room = Self.room(id: "friends@conference.trix.selfhost.ru", kind: .group)
        let session = Self.session()
        let existingMediaKey = try TrixCallMediaKey(
            keyID: "group-key",
            key: "base64-group-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let existingState = TrixVoiceRoomState(
            callID: "group-call",
            roomID: room.id,
            activeParticipantIDs: ["bob@trix.selfhost.ru"],
            mediaKey: existingMediaKey,
            updatedAtUnix: 100
        )
        let descriptors = DelayedGroupVoiceDescriptorService(
            roomID: room.id,
            senderID: "bob@trix.selfhost.ru",
            descriptorAfterFirstRead: .voiceRoomState(existingState)
        )
        let media = RecordingMediaCallService()
        let viewModel = TrixCallViewModel(
            callControlService: callControl,
            callDescriptorService: descriptors,
            mediaCallService: media
        )

        await viewModel.joinGroupVoiceRoom(roomID: room.id, session: session)

        let connectedMediaKeys = await media.connectedMediaKeys()
        let sentDescriptors = await descriptors.sentDescriptors()
        XCTAssertEqual(connectedMediaKeys, [existingMediaKey])
        if case .voiceRoomState(let state) = sentDescriptors.last?.descriptor {
            XCTAssertEqual(state.mediaKey, existingMediaKey)
            XCTAssertEqual(
                Set(state.activeParticipantIDs.map { $0.lowercased() }),
                Set(["bob@trix.selfhost.ru", session.userID.lowercased()])
            )
        } else {
            XCTFail("Expected the latest descriptor to be a voice-room state")
        }
    }

    @MainActor
    func testForegroundRefreshLoadsIncomingCallDescriptorForUnselectedRoom() async throws {
        let accountID = "@me:trix.selfhost.ru"
        let directRoomID = "!dm-alice:trix.selfhost.ru"
        let service = MockTrixService(now: Date(timeIntervalSince1970: 100))
        let stickerKeychainService = "com.softgrid.trix.tests.calls.stickers.\(UUID().uuidString)"
        let mediaKeychainService = "com.softgrid.trix.tests.calls.media.\(UUID().uuidString)"
        let notificationKeychainService = "com.softgrid.trix.tests.calls.notifications.\(UUID().uuidString)"
        let mediaSettingsSuiteName = "com.softgrid.trix.tests.calls.media-settings.\(UUID().uuidString)"
        let mediaSettingsUserDefaults = try XCTUnwrap(UserDefaults(suiteName: mediaSettingsSuiteName))
        let stickerStore = TrixStickerLibraryStore(
            keychainService: stickerKeychainService,
            keychainAccount: "key",
            directoryName: "CallStickerLibraryTests-\(UUID().uuidString)"
        )
        let mediaStore = TrixMediaCacheStore(
            keychainService: mediaKeychainService,
            keychainAccount: "key",
            directoryName: "CallMediaCacheTests-\(UUID().uuidString)"
        )
        let notificationStore = TrixRoomNotificationProfileStore(
            keychainService: notificationKeychainService,
            keychainAccount: "key",
            directoryName: "CallNotificationProfileTests-\(UUID().uuidString)"
        )
        defer {
            try? stickerStore.clear(accountID: accountID)
            _ = try? mediaStore.clearAll(accountID: accountID)
            try? notificationStore.clear(accountID: accountID)
            mediaSettingsUserDefaults.removePersistentDomain(forName: mediaSettingsSuiteName)
            deleteCallTestKeychainItem(service: stickerKeychainService)
            deleteCallTestKeychainItem(service: mediaKeychainService)
            deleteCallTestKeychainItem(service: notificationKeychainService)
        }

        let model = TrixAppModel(
            sessionStore: CallTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            stickerLibraryStore: stickerStore,
            mediaCacheStore: mediaStore,
            mediaCacheSettingsStore: UserDefaultsTrixMediaCacheSettingsStore(userDefaults: mediaSettingsUserDefaults),
            roomNotificationProfileStore: notificationStore,
            trixService: service
        )
        await model.login(userID: accountID, password: "test-password")
        XCTAssertNil(model.errorMessage)

        let mediaKey = try TrixCallMediaKey(
            keyID: "incoming-key",
            key: "base64-call-key",
            keyIndex: 0,
            createdAtUnix: 100
        )
        let invite = TrixCallInvite(
            callID: "incoming-call",
            kind: .directVideo,
            roomID: directRoomID,
            senderID: "@alice:trix.selfhost.ru",
            liveKitRoom: "dm-room",
            createdAtUnix: 100,
            expiresAtUnix: UInt64(Date().addingTimeInterval(60).timeIntervalSince1970),
            mediaKey: mediaKey
        )
        _ = try await service.appendRemoteCallDescriptor(
            .invite(invite),
            roomID: directRoomID,
            senderID: invite.senderID
        )

        XCTAssertNil(model.callViewModel.incomingDirectCall(roomID: directRoomID))
        await model.refreshForeground(markSelectedRoomRead: false, reloadSelectedTimeline: false)

        let incomingCall = try XCTUnwrap(model.callViewModel.incomingDirectCall(roomID: directRoomID))
        XCTAssertEqual(incomingCall.callID, "incoming-call")
        XCTAssertEqual(incomingCall.callerID, "@alice:trix.selfhost.ru")
    }

    private static func session() -> TrixSession {
        TrixSession(
            userID: "alice@trix.selfhost.ru",
            deviceID: "device-1",
            homeserverURL: URL(string: "https://trix.selfhost.ru")!,
            accessToken: "test-password",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "test",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func room(id: String, kind: TrixRoomKind) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: id,
            kind: kind,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "",
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private final class CallTestSessionStore: TrixSessionStore {
    private var savedSession: TrixSession?

    func loadSession() throws -> TrixSession? {
        savedSession
    }

    func saveSession(_ session: TrixSession) throws {
        savedSession = session
    }

    func clearSession() throws {
        savedSession = nil
    }
}

private func deleteCallTestKeychainItem(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "key",
    ] as CFDictionary)
}

private actor RecordingCallControlService: TrixCallControlService {
    private let directVideoAuthorization: TrixCallJoinAuthorization?
    private var endedIDs: [String] = []
    private var joinedDirectIDs: [String] = []
    private var preparedDirectCount = 0

    init(directVideoAuthorization: TrixCallJoinAuthorization? = nil) {
        self.directVideoAuthorization = directVideoAuthorization
    }

    func prepareDirectVideoCall(
        peerUserID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        preparedDirectCount += 1
        if let directVideoAuthorization {
            return directVideoAuthorization
        }
        return authorization(callID: "call-\(preparedDirectCount)", kind: .directVideo, liveKitRoom: "dm-room")
    }

    func joinDirectVideoCall(
        callID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        joinedDirectIDs.append(callID)
        return authorization(callID: callID, kind: .directVideo, liveKitRoom: "dm-room")
    }

    func joinGroupVoiceRoom(
        roomID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        authorization(kind: .groupVoice, liveKitRoom: "group-room")
    }

    func endCall(callID: String, session: TrixSession) async throws {
        endedIDs.append(callID)
    }

    func turnCredentials(session: TrixSession) async throws -> TrixTurnCredentials {
        TrixTurnCredentials(
            uris: ["turn:turn.trix.selfhost.ru"],
            username: "turn-user",
            credential: "turn-credential",
            expiresAtUnix: 200
        )
    }

    func endedCallIDs() -> [String] {
        endedIDs
    }

    func joinedDirectCallIDs() -> [String] {
        joinedDirectIDs
    }

    static func authorization(
        callID: String = "call-1",
        kind: TrixCallKind,
        liveKitRoom: String,
        publishAudio: Bool = true,
        publishVideo: Bool? = nil,
        subscribeAudio: Bool = true,
        subscribeVideo: Bool? = nil
    ) -> TrixCallJoinAuthorization {
        TrixCallJoinAuthorization(
            callID: callID,
            kind: kind,
            liveKitURL: URL(string: "wss://calls.trix.selfhost.ru")!,
            liveKitRoom: liveKitRoom,
            liveKitToken: "livekit-token",
            liveKitTokenExpiresAtUnix: 200,
            turn: TrixTurnCredentials(
                uris: ["turn:turn.trix.selfhost.ru"],
                username: "turn-user",
                credential: "turn-credential",
                expiresAtUnix: 200
            ),
            e2eeRequired: true,
            publishAudio: publishAudio,
            publishVideo: publishVideo ?? (kind == .directVideo),
            subscribeAudio: subscribeAudio,
            subscribeVideo: subscribeVideo ?? (kind == .directVideo)
        )
    }

    private func authorization(
        callID: String = "call-1",
        kind: TrixCallKind,
        liveKitRoom: String
    ) -> TrixCallJoinAuthorization {
        Self.authorization(callID: callID, kind: kind, liveKitRoom: liveKitRoom)
    }
}

private actor RecordingCallDescriptorService: TrixCallDescriptorService {
    private var descriptors: [TrixReceivedCallDescriptor] = []

    func callDescriptors(roomID: String, session: TrixSession) async throws -> [TrixReceivedCallDescriptor] {
        descriptors.filter { $0.roomID == roomID }
    }

    func sendCallInvite(
        _ invite: TrixCallInvite,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.invite(invite), roomID: roomID, session: session)
    }

    func sendCallAnswer(
        _ answer: TrixCallAnswer,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.answer(answer), roomID: roomID, session: session)
    }

    func sendCallEnd(
        _ end: TrixCallEnd,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.end(end), roomID: roomID, session: session)
    }

    func sendVoiceRoomState(
        _ state: TrixVoiceRoomState,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.voiceRoomState(state), roomID: roomID, session: session)
    }

    func sendCallKeyRotation(
        _ rotation: TrixCallKeyRotation,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.keyRotation(rotation), roomID: roomID, session: session)
    }

    func sentDescriptors() -> [TrixReceivedCallDescriptor] {
        descriptors
    }

    func appendRemote(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        senderID: String
    ) {
        let item = TrixReceivedCallDescriptor(
            id: "remote-descriptor-\(descriptors.count + 1)",
            roomID: roomID,
            senderID: senderID,
            timestamp: Date(timeIntervalSince1970: Double(descriptors.count + 1)),
            descriptor: descriptor,
            isLocalEcho: false
        )
        descriptors.append(item)
    }

    private func store(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        session: TrixSession
    ) -> TrixReceivedCallDescriptor {
        let item = TrixReceivedCallDescriptor(
            id: "descriptor-\(descriptors.count + 1)",
            roomID: roomID,
            senderID: session.userID,
            timestamp: Date(timeIntervalSince1970: Double(descriptors.count + 1)),
            descriptor: descriptor,
            isLocalEcho: true
        )
        descriptors.append(item)
        return item
    }
}

private actor DelayedGroupVoiceDescriptorService: TrixCallDescriptorService {
    private let roomID: String
    private let senderID: String
    private let descriptorAfterFirstRead: TrixCallDescriptor
    private var reads = 0
    private var descriptors: [TrixReceivedCallDescriptor] = []

    init(roomID: String, senderID: String, descriptorAfterFirstRead: TrixCallDescriptor) {
        self.roomID = roomID
        self.senderID = senderID
        self.descriptorAfterFirstRead = descriptorAfterFirstRead
    }

    func callDescriptors(roomID: String, session: TrixSession) async throws -> [TrixReceivedCallDescriptor] {
        reads += 1
        if reads == 2, roomID == self.roomID {
            appendRemote(descriptorAfterFirstRead, roomID: roomID, senderID: senderID)
        }
        return descriptors.filter { $0.roomID == roomID }
    }

    func sendCallInvite(
        _ invite: TrixCallInvite,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.invite(invite), roomID: roomID, session: session)
    }

    func sendCallAnswer(
        _ answer: TrixCallAnswer,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.answer(answer), roomID: roomID, session: session)
    }

    func sendCallEnd(
        _ end: TrixCallEnd,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.end(end), roomID: roomID, session: session)
    }

    func sendVoiceRoomState(
        _ state: TrixVoiceRoomState,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.voiceRoomState(state), roomID: roomID, session: session)
    }

    func sendCallKeyRotation(
        _ rotation: TrixCallKeyRotation,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        store(.keyRotation(rotation), roomID: roomID, session: session)
    }

    func sentDescriptors() -> [TrixReceivedCallDescriptor] {
        descriptors
    }

    private func appendRemote(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        senderID: String
    ) {
        let item = TrixReceivedCallDescriptor(
            id: "remote-descriptor-\(descriptors.count + 1)",
            roomID: roomID,
            senderID: senderID,
            timestamp: Date(timeIntervalSince1970: Double(descriptors.count + 1)),
            descriptor: descriptor,
            isLocalEcho: false
        )
        descriptors.append(item)
    }

    private func store(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        session: TrixSession
    ) -> TrixReceivedCallDescriptor {
        let item = TrixReceivedCallDescriptor(
            id: "descriptor-\(descriptors.count + 1)",
            roomID: roomID,
            senderID: session.userID,
            timestamp: Date(timeIntervalSince1970: Double(descriptors.count + 1)),
            descriptor: descriptor,
            isLocalEcho: true
        )
        descriptors.append(item)
        return item
    }
}

private struct RecordingMediaChange: Equatable {
    let callID: String
    let enabled: Bool
}

private actor RecordingMediaCallService: TrixMediaCallService {
    private var connectedIDs: [String] = []
    private var connectedKeys: [TrixCallMediaKey] = []
    private var disconnectedIDs: [String] = []
    private var microphoneUpdates: [RecordingMediaChange] = []
    private var cameraUpdates: [RecordingMediaChange] = []

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        connectedIDs.append(authorization.callID)
        connectedKeys.append(mediaKey)
        return TrixActiveMediaCall(
            callID: authorization.callID,
            kind: authorization.kind,
            liveKitRoom: authorization.liveKitRoom,
            startedAt: Date(timeIntervalSince1970: 10),
            publishesLocalAudio: authorization.publishAudio,
            publishesLocalVideo: authorization.publishVideo,
            subscribesRemoteAudio: authorization.subscribeAudio,
            subscribesRemoteVideo: authorization.subscribeVideo
        )
    }

    func disconnect(callID: String) async {
        disconnectedIDs.append(callID)
    }

    func setMicrophoneEnabled(_ enabled: Bool, callID: String) async throws {
        microphoneUpdates.append(RecordingMediaChange(callID: callID, enabled: enabled))
    }

    func setCameraEnabled(_ enabled: Bool, callID: String) async throws {
        cameraUpdates.append(RecordingMediaChange(callID: callID, enabled: enabled))
    }

    func connectedCallIDs() -> [String] {
        connectedIDs
    }

    func connectedMediaKeys() -> [TrixCallMediaKey] {
        connectedKeys
    }

    func disconnectedCallIDs() -> [String] {
        disconnectedIDs
    }

    func microphoneChanges() -> [RecordingMediaChange] {
        microphoneUpdates
    }

    func cameraChanges() -> [RecordingMediaChange] {
        cameraUpdates
    }
}
