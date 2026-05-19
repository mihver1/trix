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
        XCTAssertNotNil(prepared)
        XCTAssertEqual(sentDescriptors.map(\.descriptor.event), [.invite])
        XCTAssertEqual(sentDescriptors.first?.roomID, "bob@trix.selfhost.ru")
        XCTAssertEqual(mediaConnects, [])
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
        } else {
            XCTFail("Expected a voice-room state descriptor")
        }
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

private actor RecordingCallControlService: TrixCallControlService {
    private var endedIDs: [String] = []
    private var joinedDirectIDs: [String] = []

    func prepareDirectVideoCall(
        peerUserID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization {
        authorization(kind: .directVideo, liveKitRoom: "dm-room")
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

    private func authorization(
        callID: String = "call-1",
        kind: TrixCallKind,
        liveKitRoom: String
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
            publishAudio: true,
            publishVideo: kind == .directVideo,
            subscribeAudio: true,
            subscribeVideo: kind == .directVideo
        )
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

private actor RecordingMediaCallService: TrixMediaCallService {
    private var connectedIDs: [String] = []
    private var disconnectedIDs: [String] = []

    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall {
        connectedIDs.append(authorization.callID)
        return TrixActiveMediaCall(
            callID: authorization.callID,
            kind: authorization.kind,
            liveKitRoom: authorization.liveKitRoom,
            startedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func disconnect(callID: String) async {
        disconnectedIDs.append(callID)
    }

    func connectedCallIDs() -> [String] {
        connectedIDs
    }

    func disconnectedCallIDs() -> [String] {
        disconnectedIDs
    }
}
