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

private actor RecordingMediaCallService: TrixMediaCallService {
    private var connectedIDs: [String] = []
    private var connectedKeys: [TrixCallMediaKey] = []
    private var disconnectedIDs: [String] = []

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
            startedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func disconnect(callID: String) async {
        disconnectedIDs.append(callID)
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
}
