import Combine
import Foundation

@MainActor
final class TrixCallViewModel: ObservableObject {
    @Published private(set) var activeCall: TrixActiveMediaCall?
    @Published private(set) var activeRoomID: String?
    @Published private(set) var preparedCall: TrixPreparedCall?
    @Published private(set) var incomingDirectCallsByRoomID: [String: TrixIncomingDirectCall] = [:]
    @Published private(set) var groupVoiceRoomsByRoomID: [String: TrixGroupVoiceRoomSnapshot] = [:]
    @Published private(set) var isPreparing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var actionRoomID: String?
    @Published private(set) var errorMessage: String?

    private let callControlService: TrixCallControlService
    private let callDescriptorService: TrixCallDescriptorService
    private let mediaCallService: TrixMediaCallService

    init(
        callControlService: TrixCallControlService = HTTPCallControlService(),
        callDescriptorService: TrixCallDescriptorService = XMPPMartinService(),
        mediaCallService: TrixMediaCallService = TrixLiveKitMediaCallService()
    ) {
        self.callControlService = callControlService
        self.callDescriptorService = callDescriptorService
        self.mediaCallService = mediaCallService
    }

    func incomingDirectCall(roomID: String) -> TrixIncomingDirectCall? {
        incomingDirectCallsByRoomID[roomID]
    }

    func incomingDirectCall(callID: String) -> TrixIncomingDirectCall? {
        incomingDirectCallsByRoomID.values.first { $0.callID == callID }
    }

    func groupVoiceRoom(roomID: String) -> TrixGroupVoiceRoomSnapshot {
        groupVoiceRoomsByRoomID[roomID] ?? TrixGroupVoiceRoomSnapshot(
            roomID: roomID,
            callID: nil,
            activeParticipantIDs: [],
            updatedAt: nil
        )
    }

    func currentCall(roomID: String, kind: TrixCallKind? = nil) -> TrixActiveMediaCall? {
        guard activeRoomID == roomID, let activeCall else {
            return nil
        }

        if let kind, activeCall.kind != kind {
            return nil
        }

        return activeCall
    }

    func isActing(roomID: String) -> Bool {
        actionRoomID == roomID || isPreparing || isConnecting
    }

    func loadRoomCallState(room: TrixRoomSummary, session: TrixSession) async {
        do {
            let descriptors = try await callDescriptorService.callDescriptors(roomID: room.id, session: session)
            applyCallDescriptors(descriptors, room: room, session: session)
        } catch {
            errorMessage = error.trixUserFacingMessage
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
        guard currentCall(roomID: roomID, kind: .groupVoice) == nil else {
            return
        }

        actionRoomID = roomID
        isConnecting = true
        errorMessage = nil
        defer {
            isConnecting = false
            actionRoomID = nil
        }

        do {
            let authorization = try await callControlService.joinGroupVoiceRoom(roomID: roomID, session: session)
            let mediaKey = try TrixCallMediaKey.generate()
            activeCall = try await mediaCallService.connect(authorization: authorization, mediaKey: mediaKey)
            activeRoomID = roomID
            preparedCall = nil

            let participantIDs = Self.addingParticipant(
                session.userID,
                to: groupVoiceRoom(roomID: roomID).activeParticipantIDs
            )
            let state = TrixVoiceRoomState(
                callID: authorization.callID,
                roomID: roomID,
                activeParticipantIDs: participantIDs,
                updatedAtUnix: Self.unixNow()
            )
            _ = try await callDescriptorService.sendVoiceRoomState(state, roomID: roomID, session: session)
            groupVoiceRoomsByRoomID[roomID] = Self.groupVoiceRoomSnapshot(from: state)
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func connectPreparedCall() async {
        guard let preparedCall else {
            errorMessage = TrixClientError.callControlUnavailable.trixUserFacingMessage
            return
        }

        isConnecting = true
        errorMessage = nil
        defer {
            isConnecting = false
        }

        do {
            activeCall = try await mediaCallService.connect(
                authorization: preparedCall.authorization,
                mediaKey: preparedCall.mediaKey
            )
            activeRoomID = preparedCall.roomID
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    @discardableResult
    func acceptIncomingDirectCall(_ call: TrixIncomingDirectCall, session: TrixSession) async -> Bool {
        actionRoomID = call.roomID
        isConnecting = true
        errorMessage = nil
        defer {
            isConnecting = false
            actionRoomID = nil
        }

        do {
            let authorization = try await callControlService.joinDirectVideoCall(
                callID: call.callID,
                session: session
            )
            guard authorization.kind == .directVideo else {
                throw TrixClientError.callControlUnavailable
            }

            activeCall = try await mediaCallService.connect(
                authorization: authorization,
                mediaKey: call.mediaKey
            )
            activeRoomID = call.roomID
            preparedCall = nil

            let answer = TrixCallAnswer(
                callID: call.callID,
                accepted: true,
                answeredAtUnix: Self.unixNow()
            )
            _ = try await callDescriptorService.sendCallAnswer(answer, roomID: call.roomID, session: session)
            incomingDirectCallsByRoomID[call.roomID] = nil
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
        }
    }

    @discardableResult
    func acceptIncomingDirectCall(callID: String, session: TrixSession) async -> Bool {
        guard let call = incomingDirectCall(callID: callID) else {
            errorMessage = TrixClientError.callControlUnavailable.trixUserFacingMessage
            return false
        }

        return await acceptIncomingDirectCall(call, session: session)
    }

    @discardableResult
    func declineIncomingDirectCall(_ call: TrixIncomingDirectCall, session: TrixSession) async -> Bool {
        actionRoomID = call.roomID
        errorMessage = nil
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
            incomingDirectCallsByRoomID[call.roomID] = nil
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
        }
    }

    @discardableResult
    func endCall(roomID: String, session: TrixSession?) async -> Bool {
        let activeCall = currentCall(roomID: roomID)
        let preparedCall = preparedCall?.roomID == roomID ? preparedCall : nil
        guard activeCall != nil || preparedCall != nil else {
            return false
        }

        actionRoomID = roomID
        defer {
            actionRoomID = nil
        }

        if let activeCall {
            await mediaCallService.disconnect(callID: activeCall.callID)
        }

        let callID = activeCall?.callID ?? preparedCall?.authorization.callID
        if let session, let callID {
            if activeCall?.kind == .groupVoice || preparedCall?.authorization.kind == .groupVoice {
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

        if activeRoomID == roomID {
            self.activeCall = nil
            activeRoomID = nil
        }
        if self.preparedCall?.roomID == roomID {
            self.preparedCall = nil
        }
        return true
    }

    func disconnect(session: TrixSession?) async {
        guard let roomID = activeRoomID ?? preparedCall?.roomID else {
            return
        }

        _ = await endCall(roomID: roomID, session: session)
    }

    func clear() {
        activeCall = nil
        activeRoomID = nil
        preparedCall = nil
        incomingDirectCallsByRoomID = [:]
        groupVoiceRoomsByRoomID = [:]
        isPreparing = false
        isConnecting = false
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
        isPreparing = true
        errorMessage = nil
        defer {
            isPreparing = false
        }

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
            self.preparedCall = prepared
            return prepared
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            incomingDirectCallsByRoomID[room.id] = Self.incomingDirectCall(
                from: descriptors,
                roomID: room.id,
                session: session,
                now: Date()
            )
        case .group:
            groupVoiceRoomsByRoomID[room.id] = Self.groupVoiceRoomSnapshot(
                from: descriptors,
                roomID: room.id,
                currentUserID: session.userID,
                activeCall: currentCall(roomID: room.id, kind: .groupVoice)
            )
        }
    }

    private func sendGroupVoiceLeaveState(callID: String, roomID: String, session: TrixSession) async {
        let previous = groupVoiceRoom(roomID: roomID)
        let participantIDs = Self.removingParticipant(session.userID, from: previous.activeParticipantIDs)
        let state = TrixVoiceRoomState(
            callID: previous.callID ?? callID,
            roomID: roomID,
            activeParticipantIDs: participantIDs,
            updatedAtUnix: Self.unixNow()
        )
        _ = try? await callDescriptorService.sendVoiceRoomState(state, roomID: roomID, session: session)
        groupVoiceRoomsByRoomID[roomID] = Self.groupVoiceRoomSnapshot(from: state)
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
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":") else {
            return trimmed
        }

        let localpart = trimmed[trimmed.index(after: trimmed.startIndex)..<separator]
        let server = trimmed[trimmed.index(after: separator)...]
        guard !localpart.isEmpty, !server.isEmpty else {
            return trimmed
        }

        return "\(localpart)@\(server)"
    }

    private static func unixNow() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }
}
