import Combine
import Foundation

@MainActor
final class TrixCallViewModel: ObservableObject {
    @Published private(set) var lifecycleStatesByRoomID: [String: TrixCallLifecycleState] = [:]
    @Published private(set) var actionRoomID: String?
    @Published private(set) var errorMessage: String?

    private let callControlService: TrixCallControlService
    private let callDescriptorService: TrixCallDescriptorService
    private let mediaCallService: TrixMediaCallService
    private var activeMediaCallsByRoomID: [String: TrixActiveMediaCall] = [:]
    private var preparedCallsByRoomID: [String: TrixPreparedCall] = [:]
    private var incomingDirectCallDetailsByRoomID: [String: TrixIncomingDirectCall] = [:]
    private var groupVoiceMediaKeysByRoomID: [String: TrixCallMediaKey] = [:]

    var activeCall: TrixActiveMediaCall? {
        guard let activeRoomID else {
            return nil
        }

        return activeMediaCallsByRoomID[activeRoomID]
    }

    var activeRoomID: String? {
        activeMediaCallsByRoomID.keys
            .sorted()
            .first { roomID in
                callLifecycleState(roomID: roomID).phase.isActiveLike
            }
    }

    var preparedCall: TrixPreparedCall? {
        preparedCallsByRoomID
            .sorted { $0.key < $1.key }
            .first?
            .value
    }

    var incomingDirectCallsByRoomID: [String: TrixIncomingDirectCall] {
        incomingDirectCallDetailsByRoomID
    }

    var groupVoiceRoomsByRoomID: [String: TrixGroupVoiceRoomSnapshot] {
        lifecycleStatesByRoomID.reduce(into: [:]) { result, pair in
            guard pair.value.kind == .groupVoice else {
                return
            }

            result[pair.key] = Self.groupVoiceRoomSnapshot(from: pair.value)
        }
    }

    var isPreparing: Bool {
        lifecycleStatesByRoomID.values.contains { $0.phase == .outgoingPreparing }
    }

    var isConnecting: Bool {
        lifecycleStatesByRoomID.values.contains { $0.phase == .connecting || $0.phase == .reconnecting }
    }

    init(
        callControlService: TrixCallControlService = HTTPCallControlService(),
        callDescriptorService: TrixCallDescriptorService = XMPPMartinService(),
        mediaCallService: TrixMediaCallService = TrixLiveKitMediaCallService()
    ) {
        self.callControlService = callControlService
        self.callDescriptorService = callDescriptorService
        self.mediaCallService = mediaCallService
    }

    func callLifecycleState(roomID: String) -> TrixCallLifecycleState {
        lifecycleStatesByRoomID[roomID] ?? .idle(roomID: roomID)
    }

    func callLifecycleState(callID: String) -> TrixCallLifecycleState? {
        lifecycleStatesByRoomID.values.first { $0.callID == callID }
    }

    func incomingDirectCall(roomID: String) -> TrixIncomingDirectCall? {
        guard callLifecycleState(roomID: roomID).phase == .incomingRinging else {
            return nil
        }

        return incomingDirectCallDetailsByRoomID[roomID]
    }

    func incomingDirectCall(callID: String) -> TrixIncomingDirectCall? {
        incomingDirectCallDetailsByRoomID.values.first { call in
            call.callID == callID && callLifecycleState(roomID: call.roomID).phase == .incomingRinging
        }
    }

    func groupVoiceRoom(roomID: String) -> TrixGroupVoiceRoomSnapshot {
        let state = callLifecycleState(roomID: roomID)
        guard state.kind == .groupVoice else {
            return TrixGroupVoiceRoomSnapshot(
                roomID: roomID,
                callID: nil,
                activeParticipantIDs: [],
                updatedAt: nil
            )
        }

        return Self.groupVoiceRoomSnapshot(from: state)
    }

    func currentCall(roomID: String, kind: TrixCallKind? = nil) -> TrixActiveMediaCall? {
        guard let activeCall = activeMediaCallsByRoomID[roomID],
              callLifecycleState(roomID: roomID).phase.isActiveLike else {
            return nil
        }

        if let kind, activeCall.kind != kind {
            return nil
        }

        return activeCall
    }

    func isActing(roomID: String) -> Bool {
        actionRoomID == roomID || callLifecycleState(roomID: roomID).isActing
    }

    @discardableResult
    func setMicrophoneMuted(_ muted: Bool, roomID: String) async -> Bool {
        guard let activeCall = currentCall(roomID: roomID),
              callLifecycleState(roomID: roomID).localAudioState != .unavailable else {
            errorMessage = TrixClientError.callMicrophoneUnavailable.trixUserFacingMessage
            return false
        }

        do {
            try await mediaCallService.setMicrophoneEnabled(!muted, callID: activeCall.callID)
            updateLocalMediaState(
                roomID: roomID,
                localAudioState: muted ? .muted : .unmuted
            )
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
        }
    }

    @discardableResult
    func setCameraEnabled(_ enabled: Bool, roomID: String) async -> Bool {
        guard let activeCall = currentCall(roomID: roomID, kind: .directVideo),
              callLifecycleState(roomID: roomID).localCameraState != .unavailable else {
            errorMessage = TrixClientError.callCameraUnavailable.trixUserFacingMessage
            return false
        }

        do {
            try await mediaCallService.setCameraEnabled(enabled, callID: activeCall.callID)
            updateLocalMediaState(
                roomID: roomID,
                localCameraState: enabled ? .on : .off
            )
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
        }
    }

    func expireStaleCallInvites(now: Date = Date()) {
        for state in lifecycleStatesByRoomID.values where isExpiredRingingState(state, now: now) {
            incomingDirectCallDetailsByRoomID[state.roomID] = nil
            preparedCallsByRoomID[state.roomID] = nil
            setLifecycleState(endedState(from: state, updatedAt: now))
        }
    }

    func loadRoomCallState(
        room: TrixRoomSummary,
        session: TrixSession,
        reportsErrors: Bool = true
    ) async {
        do {
            let descriptors = try await callDescriptorService.callDescriptors(roomID: room.id, session: session)
            applyCallDescriptors(descriptors, room: room, session: session)
        } catch {
            if reportsErrors {
                errorMessage = error.trixUserFacingMessage
                setLifecycleState(failedState(roomID: room.id, previous: callLifecycleState(roomID: room.id)))
            }
        }
    }

    func prepareDirectVideoCall(
        peerUserID: String,
        roomID: String,
        session: TrixSession
    ) async -> TrixPreparedCall? {
        await prepareCall(roomID: roomID, session: session) {
            try await callControlService.prepareDirectVideoCall(
                peerUserID: peerUserID,
                session: session
            )
        }
    }

    func startDirectVideoCall(
        peerUserID: String,
        roomID: String,
        session: TrixSession
    ) async {
        await endActiveCallIfNeeded(beforeStartingRoomID: roomID, session: session)
        guard currentCall(roomID: roomID) == nil else {
            return
        }

        actionRoomID = roomID
        defer {
            actionRoomID = nil
        }

        guard await prepareDirectVideoCall(peerUserID: peerUserID, roomID: roomID, session: session) != nil else {
            return
        }

        await connectPreparedCall()
    }

    func joinGroupVoiceRoom(roomID: String, session: TrixSession) async {
        await endActiveCallIfNeeded(beforeStartingRoomID: roomID, session: session)
        guard currentCall(roomID: roomID, kind: .groupVoice) == nil else {
            return
        }

        actionRoomID = roomID
        errorMessage = nil
        setLifecycleState(connectingState(
            roomID: roomID,
            callID: callLifecycleState(roomID: roomID).callID,
            kind: .groupVoice,
            participantIDs: groupVoiceRoom(roomID: roomID).activeParticipantIDs,
            surface: .groupVoiceRoomBar
        ))
        defer {
            actionRoomID = nil
        }

        do {
            let descriptors = try await callDescriptorService.callDescriptors(roomID: roomID, session: session)
            let snapshot = Self.groupVoiceRoomSnapshot(
                from: descriptors,
                roomID: roomID,
                currentUserID: session.userID,
                activeCall: currentCall(roomID: roomID, kind: .groupVoice)
            )
            if !snapshot.activeParticipantIDs.isEmpty {
                setGroupVoiceLifecycleState(snapshot, activeCall: currentCall(roomID: roomID, kind: .groupVoice))
            }

            if let descriptorMediaKey = Self.groupVoiceRoomMediaKey(from: descriptors, roomID: roomID) {
                groupVoiceMediaKeysByRoomID[roomID] = descriptorMediaKey
            } else if !snapshot.activeParticipantIDs.isEmpty {
                throw TrixClientError.callE2EEKeyUnavailable
            }

            let authorization = try await callControlService.joinGroupVoiceRoom(roomID: roomID, session: session)
            setLifecycleState(connectingState(
                roomID: roomID,
                callID: authorization.callID,
                kind: .groupVoice,
                participantIDs: groupVoiceRoom(roomID: roomID).activeParticipantIDs,
                surface: .groupVoiceRoomBar
            ))

            let refreshedDescriptors = try await callDescriptorService.callDescriptors(roomID: roomID, session: session)
            let refreshedSnapshot = Self.groupVoiceRoomSnapshot(
                from: refreshedDescriptors,
                roomID: roomID,
                currentUserID: session.userID,
                activeCall: currentCall(roomID: roomID, kind: .groupVoice)
            )
            if !refreshedSnapshot.activeParticipantIDs.isEmpty {
                setGroupVoiceLifecycleState(refreshedSnapshot, activeCall: currentCall(roomID: roomID, kind: .groupVoice))
            }
            if let refreshedMediaKey = Self.groupVoiceRoomMediaKey(from: refreshedDescriptors, roomID: roomID) {
                groupVoiceMediaKeysByRoomID[roomID] = refreshedMediaKey
            } else if !refreshedSnapshot.activeParticipantIDs.isEmpty {
                throw TrixClientError.callE2EEKeyUnavailable
            }

            let mediaKey: TrixCallMediaKey
            if let existingMediaKey = groupVoiceMediaKeysByRoomID[roomID] {
                mediaKey = existingMediaKey
            } else {
                mediaKey = try TrixCallMediaKey.generate()
            }

            let participantIDs = Self.addingParticipant(
                session.userID,
                to: groupVoiceRoom(roomID: roomID).activeParticipantIDs
            )
            let state = TrixVoiceRoomState(
                callID: authorization.callID,
                roomID: roomID,
                activeParticipantIDs: participantIDs,
                mediaKey: mediaKey,
                updatedAtUnix: Self.unixNow()
            )
            _ = try await callDescriptorService.sendVoiceRoomState(state, roomID: roomID, session: session)
            groupVoiceMediaKeysByRoomID[roomID] = mediaKey
            setGroupVoiceLifecycleState(Self.groupVoiceRoomSnapshot(from: state), activeCall: nil)

            do {
                let activeCall = try await mediaCallService.connect(authorization: authorization, mediaKey: mediaKey)
                activeMediaCallsByRoomID[roomID] = activeCall
                preparedCallsByRoomID[roomID] = nil
                setLifecycleState(activeState(
                    roomID: roomID,
                    activeCall: activeCall,
                    participantIDs: participantIDs
                ))
            } catch {
                await sendGroupVoiceLeaveState(callID: authorization.callID, roomID: roomID, session: session)
                _ = try? await callControlService.endCall(callID: authorization.callID, session: session)
                throw error
            }
        } catch {
            errorMessage = error.trixUserFacingMessage
            setLifecycleState(failedState(roomID: roomID, previous: callLifecycleState(roomID: roomID)))
        }
    }

    func connectPreparedCall() async {
        guard let (roomID, preparedCall) = preparedCallsByRoomID.sorted(by: { $0.key < $1.key }).first else {
            errorMessage = TrixClientError.callUnavailable.trixUserFacingMessage
            return
        }

        errorMessage = nil
        setLifecycleState(connectingState(
            roomID: roomID,
            callID: preparedCall.authorization.callID,
            kind: preparedCall.authorization.kind,
            participantIDs: callLifecycleState(roomID: roomID).participantIDs,
            surface: preparedCall.authorization.kind == .groupVoice ? .groupVoiceRoomBar : .directCallBar,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(preparedCall.invite.expiresAtUnix))
        ))

        do {
            let activeCall = try await mediaCallService.connect(
                authorization: preparedCall.authorization,
                mediaKey: preparedCall.mediaKey
            )
            activeMediaCallsByRoomID[roomID] = activeCall
            preparedCallsByRoomID[roomID] = nil
            setLifecycleState(activeState(
                roomID: roomID,
                activeCall: activeCall,
                participantIDs: callLifecycleState(roomID: roomID).participantIDs
            ))
        } catch {
            preparedCallsByRoomID[roomID] = nil
            errorMessage = error.trixUserFacingMessage
            setLifecycleState(failedState(roomID: roomID, previous: callLifecycleState(roomID: roomID)))
        }
    }

    @discardableResult
    func acceptIncomingDirectCall(_ call: TrixIncomingDirectCall, session: TrixSession) async -> Bool {
        await endActiveCallIfNeeded(beforeStartingRoomID: call.roomID, session: session)
        actionRoomID = call.roomID
        errorMessage = nil
        setLifecycleState(connectingState(
            roomID: call.roomID,
            callID: call.callID,
            kind: .directVideo,
            participantIDs: [call.callerID],
            surface: .incomingDirectCallBar,
            expiresAt: call.expiresAt
        ))
        defer {
            actionRoomID = nil
        }

        do {
            let authorization = try await callControlService.joinDirectVideoCall(
                callID: call.callID,
                session: session
            )
            guard authorization.kind == .directVideo else {
                throw TrixClientError.callControlInvalidResponse
            }

            let activeCall = try await mediaCallService.connect(
                authorization: authorization,
                mediaKey: call.mediaKey
            )
            activeMediaCallsByRoomID[call.roomID] = activeCall
            preparedCallsByRoomID[call.roomID] = nil

            let answer = TrixCallAnswer(
                callID: call.callID,
                accepted: true,
                answeredAtUnix: Self.unixNow()
            )
            _ = try await callDescriptorService.sendCallAnswer(answer, roomID: call.roomID, session: session)
            incomingDirectCallDetailsByRoomID[call.roomID] = nil
            setLifecycleState(activeState(
                roomID: call.roomID,
                activeCall: activeCall,
                participantIDs: [call.callerID, session.userID]
            ))
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            setLifecycleState(failedState(roomID: call.roomID, previous: callLifecycleState(roomID: call.roomID)))
            return false
        }
    }

    @discardableResult
    func acceptIncomingDirectCall(callID: String, session: TrixSession) async -> Bool {
        guard let call = incomingDirectCall(callID: callID) else {
            errorMessage = TrixClientError.callUnavailable.trixUserFacingMessage
            return false
        }

        return await acceptIncomingDirectCall(call, session: session)
    }

    @discardableResult
    func declineIncomingDirectCall(_ call: TrixIncomingDirectCall, session: TrixSession) async -> Bool {
        actionRoomID = call.roomID
        errorMessage = nil
        setLifecycleState(endingState(
            roomID: call.roomID,
            callID: call.callID,
            kind: .directVideo,
            participantIDs: [call.callerID],
            surface: .incomingDirectCallBar,
            expiresAt: call.expiresAt
        ))
        defer {
            actionRoomID = nil
        }

        do {
            let answer = TrixCallAnswer(
                callID: call.callID,
                accepted: false,
                answeredAtUnix: Self.unixNow()
            )
            _ = try await callDescriptorService.sendCallAnswer(answer, roomID: call.roomID, session: session)
            incomingDirectCallDetailsByRoomID[call.roomID] = nil
            setLifecycleState(endedState(from: callLifecycleState(roomID: call.roomID)))
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            setLifecycleState(failedState(roomID: call.roomID, previous: callLifecycleState(roomID: call.roomID)))
            return false
        }
    }

    @discardableResult
    func endCall(roomID: String, session: TrixSession?) async -> Bool {
        let activeCall = currentCall(roomID: roomID)
        let preparedCall = preparedCallsByRoomID[roomID]
        guard activeCall != nil || preparedCall != nil else {
            return false
        }

        actionRoomID = roomID
        setLifecycleState(endingState(from: callLifecycleState(roomID: roomID)))
        defer {
            actionRoomID = nil
        }

        if let activeCall {
            await mediaCallService.disconnect(callID: activeCall.callID)
        }

        let callID = activeCall?.callID ?? preparedCall?.authorization.callID
        let isGroupVoiceCall = activeCall?.kind == .groupVoice || preparedCall?.authorization.kind == .groupVoice
        if let session, let callID {
            if isGroupVoiceCall {
                await sendGroupVoiceLeaveState(callID: callID, roomID: roomID, session: session)
            } else {
                let end = TrixCallEnd(
                    callID: callID,
                    endedAtUnix: Self.unixNow()
                )
                _ = try? await callDescriptorService.sendCallEnd(end, roomID: roomID, session: session)
            }
            _ = try? await callControlService.endCall(callID: callID, session: session)
        }

        activeMediaCallsByRoomID[roomID] = nil
        preparedCallsByRoomID[roomID] = nil
        incomingDirectCallDetailsByRoomID[roomID] = nil

        if isGroupVoiceCall, !groupVoiceRoom(roomID: roomID).activeParticipantIDs.isEmpty {
            setGroupVoiceLifecycleState(groupVoiceRoom(roomID: roomID), activeCall: nil)
        } else {
            setLifecycleState(endedState(
                roomID: roomID,
                callID: callID,
                kind: activeCall?.kind ?? preparedCall?.authorization.kind
            ))
        }
        return true
    }

    func disconnect(session: TrixSession?) async {
        guard let roomID = activeRoomID ?? preparedCallsByRoomID.keys.sorted().first else {
            return
        }

        _ = await endCall(roomID: roomID, session: session)
    }

    func clear() {
        activeMediaCallsByRoomID = [:]
        preparedCallsByRoomID = [:]
        incomingDirectCallDetailsByRoomID = [:]
        groupVoiceMediaKeysByRoomID = [:]
        lifecycleStatesByRoomID = [:]
        actionRoomID = nil
        errorMessage = nil
    }

    func dismissErrorMessage() {
        errorMessage = nil
    }

    private func prepareCall(
        roomID: String,
        session: TrixSession,
        authorization: () async throws -> TrixCallJoinAuthorization
    ) async -> TrixPreparedCall? {
        errorMessage = nil
        setLifecycleState(TrixCallLifecycleState(
            phase: .outgoingPreparing,
            roomID: roomID,
            callID: nil,
            kind: .directVideo,
            startedAt: nil,
            updatedAt: Date(),
            expiresAt: nil,
            participantIDs: [session.userID],
            localAudioState: .unavailable,
            localCameraState: .unavailable,
            remoteMediaReadiness: .none,
            platformSurfaceState: .none
        ))

        do {
            let authorization = try await authorization()
            let mediaKey = try TrixCallMediaKey.generate()
            let invite = TrixCallInvite(
                callID: authorization.callID,
                kind: authorization.kind,
                roomID: roomID,
                senderID: session.userID,
                liveKitRoom: authorization.liveKitRoom,
                createdAtUnix: mediaKey.createdAtUnix,
                expiresAtUnix: authorization.liveKitTokenExpiresAtUnix,
                mediaKey: mediaKey
            )
            _ = try await callDescriptorService.sendCallInvite(invite, roomID: roomID, session: session)
            let prepared = TrixPreparedCall(
                authorization: authorization,
                mediaKey: mediaKey,
                invite: invite
            )
            preparedCallsByRoomID = [roomID: prepared]
            setLifecycleState(TrixCallLifecycleState(
                phase: .outgoingRinging,
                roomID: roomID,
                callID: authorization.callID,
                kind: authorization.kind,
                startedAt: nil,
                updatedAt: Date(),
                expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAtUnix)),
                participantIDs: [session.userID],
                localAudioState: .unavailable,
                localCameraState: authorization.publishVideo ? .off : .unavailable,
                remoteMediaReadiness: .none,
                platformSurfaceState: authorization.kind == .groupVoice ? .groupVoiceRoomBar : .none
            ))
            return prepared
        } catch {
            errorMessage = error.trixUserFacingMessage
            preparedCallsByRoomID[roomID] = nil
            setLifecycleState(failedState(roomID: roomID, previous: callLifecycleState(roomID: roomID)))
            return nil
        }
    }

    private func applyCallDescriptors(
        _ descriptors: [TrixReceivedCallDescriptor],
        room: TrixRoomSummary,
        session: TrixSession
    ) {
        switch room.kind {
        case .direct:
            applyDirectCallDescriptors(descriptors, room: room, session: session)
        case .group:
            applyGroupVoiceDescriptors(descriptors, room: room, session: session)
        }
    }

    private func applyDirectCallDescriptors(
        _ descriptors: [TrixReceivedCallDescriptor],
        room: TrixRoomSummary,
        session: TrixSession
    ) {
        if let activeCall = activeMediaCallsByRoomID[room.id],
           Self.containsEndDescriptor(for: activeCall.callID, descriptors: descriptors) {
            activeMediaCallsByRoomID[room.id] = nil
            setLifecycleState(endedState(
                roomID: room.id,
                callID: activeCall.callID,
                kind: activeCall.kind
            ))
            return
        }

        if let incomingCall = Self.incomingDirectCall(
            from: descriptors,
            roomID: room.id,
            session: session,
            now: Date()
        ) {
            incomingDirectCallDetailsByRoomID[room.id] = incomingCall
            setLifecycleState(incomingDirectCallState(incomingCall))
            return
        }

        incomingDirectCallDetailsByRoomID[room.id] = nil
        guard currentCall(roomID: room.id) == nil,
              preparedCallsByRoomID[room.id] == nil else {
            return
        }

        let previous = callLifecycleState(roomID: room.id)
        if previous.phase == .idle {
            setLifecycleState(.idle(roomID: room.id))
        } else if previous.kind == .directVideo {
            setLifecycleState(endedState(from: previous))
        } else {
            setLifecycleState(.idle(roomID: room.id))
        }
    }

    private func applyGroupVoiceDescriptors(
        _ descriptors: [TrixReceivedCallDescriptor],
        room: TrixRoomSummary,
        session: TrixSession
    ) {
        let snapshot = Self.groupVoiceRoomSnapshot(
            from: descriptors,
            roomID: room.id,
            currentUserID: session.userID,
            activeCall: currentCall(roomID: room.id, kind: .groupVoice)
        )
        setGroupVoiceLifecycleState(snapshot, activeCall: currentCall(roomID: room.id, kind: .groupVoice))

        if let mediaKey = Self.groupVoiceRoomMediaKey(from: descriptors, roomID: room.id) {
            groupVoiceMediaKeysByRoomID[room.id] = mediaKey
        } else if snapshot.activeParticipantIDs.isEmpty {
            groupVoiceMediaKeysByRoomID[room.id] = nil
        }
    }

    private func sendGroupVoiceLeaveState(callID: String, roomID: String, session: TrixSession) async {
        let previous = groupVoiceRoom(roomID: roomID)
        let participantIDs = Self.removingParticipant(session.userID, from: previous.activeParticipantIDs)
        let state = TrixVoiceRoomState(
            callID: previous.callID ?? callID,
            roomID: roomID,
            activeParticipantIDs: participantIDs,
            mediaKey: participantIDs.isEmpty ? nil : groupVoiceMediaKeysByRoomID[roomID],
            updatedAtUnix: Self.unixNow()
        )
        _ = try? await callDescriptorService.sendVoiceRoomState(state, roomID: roomID, session: session)
        setGroupVoiceLifecycleState(Self.groupVoiceRoomSnapshot(from: state), activeCall: nil)
        if participantIDs.isEmpty {
            groupVoiceMediaKeysByRoomID[roomID] = nil
        }
    }

    private func endActiveCallIfNeeded(beforeStartingRoomID roomID: String, session: TrixSession) async {
        guard let activeRoomID, activeRoomID != roomID else {
            return
        }

        _ = await endCall(roomID: activeRoomID, session: session)
    }

    private func setGroupVoiceLifecycleState(
        _ snapshot: TrixGroupVoiceRoomSnapshot,
        activeCall: TrixActiveMediaCall?
    ) {
        if snapshot.activeParticipantIDs.isEmpty, activeCall == nil {
            let previous = callLifecycleState(roomID: snapshot.roomID)
            if previous.kind == .groupVoice, previous.phase != .idle {
                setLifecycleState(endedState(from: previous, updatedAt: snapshot.updatedAt ?? Date()))
            } else {
                setLifecycleState(.idle(roomID: snapshot.roomID))
            }
            return
        }

        setLifecycleState(TrixCallLifecycleState(
            phase: .active,
            roomID: snapshot.roomID,
            callID: snapshot.callID ?? activeCall?.callID,
            kind: .groupVoice,
            startedAt: activeCall?.startedAt,
            updatedAt: snapshot.updatedAt ?? Date(),
            expiresAt: nil,
            participantIDs: snapshot.activeParticipantIDs,
            localAudioState: activeCall?.publishesLocalAudio == true ? .unmuted : .unavailable,
            localCameraState: .unavailable,
            remoteMediaReadiness: Self.remoteReadiness(for: activeCall),
            platformSurfaceState: .groupVoiceRoomBar
        ))
    }

    private func setLifecycleState(_ state: TrixCallLifecycleState) {
        var states = lifecycleStatesByRoomID
        states[state.roomID] = state
        lifecycleStatesByRoomID = states
    }

    private func isExpiredRingingState(_ state: TrixCallLifecycleState, now: Date) -> Bool {
        guard state.phase == .incomingRinging || state.phase == .outgoingRinging,
              let expiresAt = state.expiresAt else {
            return false
        }

        return expiresAt <= now
    }

    private func incomingDirectCallState(_ call: TrixIncomingDirectCall) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .incomingRinging,
            roomID: call.roomID,
            callID: call.callID,
            kind: .directVideo,
            startedAt: call.createdAt,
            updatedAt: Date(),
            expiresAt: call.expiresAt,
            participantIDs: [call.callerID],
            localAudioState: .unavailable,
            localCameraState: .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .incomingDirectCallBar
        )
    }

    private func connectingState(
        roomID: String,
        callID: String?,
        kind: TrixCallKind,
        participantIDs: [String],
        surface: TrixCallPlatformSurfaceState,
        expiresAt: Date? = nil
    ) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .connecting,
            roomID: roomID,
            callID: callID,
            kind: kind,
            startedAt: nil,
            updatedAt: Date(),
            expiresAt: expiresAt,
            participantIDs: Self.normalizedParticipants(participantIDs),
            localAudioState: .unavailable,
            localCameraState: kind == .directVideo ? .off : .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: surface
        )
    }

    private func activeState(
        roomID: String,
        activeCall: TrixActiveMediaCall,
        participantIDs: [String]
    ) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .active,
            roomID: roomID,
            callID: activeCall.callID,
            kind: activeCall.kind,
            startedAt: activeCall.startedAt,
            updatedAt: Date(),
            expiresAt: nil,
            participantIDs: Self.normalizedParticipants(participantIDs),
            localAudioState: activeCall.publishesLocalAudio ? .unmuted : .unavailable,
            localCameraState: activeCall.publishesLocalVideo ? .on : .unavailable,
            remoteMediaReadiness: Self.remoteReadiness(for: activeCall),
            platformSurfaceState: activeCall.kind == .groupVoice ? .groupVoiceRoomBar : .directCallBar
        )
    }

    private func updateLocalMediaState(
        roomID: String,
        localAudioState: TrixCallLocalAudioState? = nil,
        localCameraState: TrixCallLocalCameraState? = nil
    ) {
        let state = callLifecycleState(roomID: roomID)
        setLifecycleState(TrixCallLifecycleState(
            phase: state.phase,
            roomID: state.roomID,
            callID: state.callID,
            kind: state.kind,
            startedAt: state.startedAt,
            updatedAt: Date(),
            expiresAt: state.expiresAt,
            participantIDs: state.participantIDs,
            localAudioState: localAudioState ?? state.localAudioState,
            localCameraState: localCameraState ?? state.localCameraState,
            remoteMediaReadiness: state.remoteMediaReadiness,
            platformSurfaceState: state.platformSurfaceState
        ))
    }

    private static func remoteReadiness(for activeCall: TrixActiveMediaCall?) -> TrixCallRemoteMediaReadiness {
        guard let activeCall else {
            return .none
        }

        return activeCall.subscribesRemoteAudio || activeCall.subscribesRemoteVideo ? .waiting : .none
    }

    private func endingState(
        from state: TrixCallLifecycleState
    ) -> TrixCallLifecycleState {
        endingState(
            roomID: state.roomID,
            callID: state.callID,
            kind: state.kind,
            participantIDs: state.participantIDs,
            surface: state.platformSurfaceState,
            expiresAt: state.expiresAt
        )
    }

    private func endingState(
        roomID: String,
        callID: String?,
        kind: TrixCallKind?,
        participantIDs: [String],
        surface: TrixCallPlatformSurfaceState,
        expiresAt: Date?
    ) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .ending,
            roomID: roomID,
            callID: callID,
            kind: kind,
            startedAt: callLifecycleState(roomID: roomID).startedAt,
            updatedAt: Date(),
            expiresAt: expiresAt,
            participantIDs: Self.normalizedParticipants(participantIDs),
            localAudioState: .unavailable,
            localCameraState: kind == .directVideo ? .off : .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: surface
        )
    }

    private func endedState(
        from state: TrixCallLifecycleState,
        updatedAt: Date = Date()
    ) -> TrixCallLifecycleState {
        endedState(roomID: state.roomID, callID: state.callID, kind: state.kind, updatedAt: updatedAt)
    }

    private func endedState(
        roomID: String,
        callID: String?,
        kind: TrixCallKind?,
        updatedAt: Date = Date()
    ) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .ended,
            roomID: roomID,
            callID: callID,
            kind: kind,
            startedAt: nil,
            updatedAt: updatedAt,
            expiresAt: nil,
            participantIDs: [],
            localAudioState: .unavailable,
            localCameraState: .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .none
        )
    }

    private func failedState(roomID: String, previous: TrixCallLifecycleState) -> TrixCallLifecycleState {
        TrixCallLifecycleState(
            phase: .failed,
            roomID: roomID,
            callID: previous.callID,
            kind: previous.kind,
            startedAt: previous.startedAt,
            updatedAt: Date(),
            expiresAt: previous.expiresAt,
            participantIDs: previous.participantIDs,
            localAudioState: .unavailable,
            localCameraState: previous.kind == .directVideo ? .off : .off,
            remoteMediaReadiness: .none,
            platformSurfaceState: .none
        )
    }

    private static func groupVoiceRoomSnapshot(from state: TrixCallLifecycleState) -> TrixGroupVoiceRoomSnapshot {
        TrixGroupVoiceRoomSnapshot(
            roomID: state.roomID,
            callID: state.kind == .groupVoice ? state.callID : nil,
            activeParticipantIDs: state.kind == .groupVoice ? state.participantIDs : [],
            updatedAt: state.updatedAt
        )
    }

    private static func incomingDirectCall(
        from descriptors: [TrixReceivedCallDescriptor],
        roomID: String,
        session: TrixSession,
        now: Date
    ) -> TrixIncomingDirectCall? {
        var endedCallIDs = Set<String>()
        var answeredByCurrentUserCallIDs = Set<String>()
        var invites: [TrixReceivedCallDescriptor] = []

        for descriptor in descriptors {
            switch descriptor.descriptor {
            case .invite(let invite) where invite.kind == .directVideo:
                invites.append(descriptor)
            case .answer(let answer):
                if isCurrentUserDescriptor(descriptor, session: session) {
                    answeredByCurrentUserCallIDs.insert(answer.callID)
                }
            case .end(let end):
                endedCallIDs.insert(end.callID)
            case .invite, .voiceRoomState, .keyRotation:
                continue
            }
        }

        return invites
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { received -> TrixIncomingDirectCall? in
                guard case .invite(let invite) = received.descriptor,
                      !isCurrentUserID(invite.senderID, sessionUserID: session.userID),
                      !isCurrentUserDescriptor(received, session: session),
                      !endedCallIDs.contains(invite.callID),
                      !answeredByCurrentUserCallIDs.contains(invite.callID),
                      Date(timeIntervalSince1970: TimeInterval(invite.expiresAtUnix)) > now else {
                    return nil
                }

                return TrixIncomingDirectCall(
                    callID: invite.callID,
                    roomID: roomID,
                    callerID: invite.senderID,
                    liveKitRoom: invite.liveKitRoom,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(invite.createdAtUnix)),
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(invite.expiresAtUnix)),
                    mediaKey: invite.mediaKey
                )
            }
            .first
    }

    private static func containsEndDescriptor(
        for callID: String,
        descriptors: [TrixReceivedCallDescriptor]
    ) -> Bool {
        descriptors.contains { descriptor in
            if case .end(let end) = descriptor.descriptor {
                return end.callID == callID
            }

            return false
        }
    }

    private static func groupVoiceRoomSnapshot(
        from descriptors: [TrixReceivedCallDescriptor],
        roomID: String,
        currentUserID: String,
        activeCall: TrixActiveMediaCall?
    ) -> TrixGroupVoiceRoomSnapshot {
        let latestState = descriptors
            .compactMap { descriptor -> TrixVoiceRoomState? in
                guard case .voiceRoomState(let state) = descriptor.descriptor,
                      state.roomID == roomID else {
                    return nil
                }
                return state
            }
            .max { lhs, rhs in
                lhs.updatedAtUnix < rhs.updatedAtUnix
            }

        var participantIDs = latestState?.activeParticipantIDs ?? []
        if activeCall?.kind == .groupVoice {
            participantIDs = addingParticipant(currentUserID, to: participantIDs)
        }

        return TrixGroupVoiceRoomSnapshot(
            roomID: roomID,
            callID: latestState?.callID ?? activeCall?.callID,
            activeParticipantIDs: normalizedParticipants(participantIDs),
            updatedAt: latestState.map { Date(timeIntervalSince1970: TimeInterval($0.updatedAtUnix)) }
        )
    }

    private static func groupVoiceRoomSnapshot(from state: TrixVoiceRoomState) -> TrixGroupVoiceRoomSnapshot {
        TrixGroupVoiceRoomSnapshot(
            roomID: state.roomID,
            callID: state.callID,
            activeParticipantIDs: normalizedParticipants(state.activeParticipantIDs),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(state.updatedAtUnix))
        )
    }

    private static func groupVoiceRoomMediaKey(
        from descriptors: [TrixReceivedCallDescriptor],
        roomID: String
    ) -> TrixCallMediaKey? {
        guard let latestState = descriptors
            .compactMap({ descriptor -> (Date, TrixVoiceRoomState)? in
                guard case .voiceRoomState(let state) = descriptor.descriptor,
                      state.roomID == roomID else {
                    return nil
                }
                return (descriptor.timestamp, state)
            })
            .max(by: { lhs, rhs in lhs.1.updatedAtUnix < rhs.1.updatedAtUnix }),
              !latestState.1.activeParticipantIDs.isEmpty else {
            return nil
        }

        let rotatedKey = descriptors
            .compactMap { descriptor -> (Date, TrixCallMediaKey)? in
                switch descriptor.descriptor {
                case .keyRotation(let rotation)
                    where rotation.callID == latestState.1.callID && descriptor.timestamp >= latestState.0:
                    return (descriptor.timestamp, rotation.mediaKey)
                case .invite, .answer, .end, .voiceRoomState, .keyRotation:
                    return nil
                }
            }
            .max { lhs, rhs in lhs.0 < rhs.0 }?
            .1

        return rotatedKey ?? latestState.1.mediaKey
    }

    private static func addingParticipant(_ userID: String, to participantIDs: [String]) -> [String] {
        var result = participantIDs
        let normalizedUserID = normalizedUserKey(userID)
        guard !result.contains(where: { normalizedUserKey($0) == normalizedUserID }) else {
            return result
        }

        result.append(userID)
        return normalizedParticipants(result)
    }

    private static func removingParticipant(_ userID: String, from participantIDs: [String]) -> [String] {
        let normalizedUserID = normalizedUserKey(userID)
        return participantIDs.filter { normalizedUserKey($0) != normalizedUserID }
    }

    private static func normalizedParticipants(_ participantIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for participantID in participantIDs {
            let trimmed = participantID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let key = normalizedUserKey(trimmed)
            guard !seen.contains(key) else {
                continue
            }

            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private static func isCurrentUserDescriptor(
        _ descriptor: TrixReceivedCallDescriptor,
        session: TrixSession
    ) -> Bool {
        descriptor.isLocalEcho || isCurrentUserID(descriptor.senderID, sessionUserID: session.userID)
    }

    private static func isCurrentUserID(_ userID: String, sessionUserID: String) -> Bool {
        normalizedUserKey(userID) == normalizedUserKey(sessionUserID)
    }

    private static func normalizedUserKey(_ userID: String) -> String {
        (try? TrixUserIdentity.normalizedXMPPUserID(userID)) ??
            userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func unixNow() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }
}
