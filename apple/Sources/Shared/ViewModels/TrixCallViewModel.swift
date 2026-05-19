import Combine
import Foundation

@MainActor
final class TrixCallViewModel: ObservableObject {
    @Published private(set) var activeCall: TrixActiveMediaCall?
    @Published private(set) var preparedCall: TrixPreparedCall?
    @Published private(set) var isPreparing = false
    @Published private(set) var isConnecting = false
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

    func prepareGroupVoiceRoom(
        roomID: String,
        session: TrixSession
    ) async -> TrixPreparedCall? {
        await prepareCall(roomID: roomID, session: session) {
            try await callControlService.joinGroupVoiceRoom(
                roomID: roomID,
                session: session
            )
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
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func disconnect(session: TrixSession?) async {
        guard let activeCall else {
            return
        }

        await mediaCallService.disconnect(callID: activeCall.callID)
        if let session {
            if let roomID = preparedCall?.invite.roomID {
                let end = TrixCallEnd(
                    callID: activeCall.callID,
                    endedAtUnix: UInt64(Date().timeIntervalSince1970)
                )
                try? await callDescriptorService.sendCallEnd(end, roomID: roomID, session: session)
            }
            try? await callControlService.endCall(callID: activeCall.callID, session: session)
        }
        self.activeCall = nil
        self.preparedCall = nil
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
}
