import Foundation

protocol TrixSessionStore {
    func loadSession() throws -> TrixSession?
    func saveSession(_ session: TrixSession) throws
    func clearSession() throws
}

protocol TrixRegistrationService: Sendable {
    func issueInvite(_ request: TrixInviteIssueRequest, session: TrixSession) async throws -> TrixIssuedInvite
    func redeemInvite(_ request: TrixInviteRegistrationRequest) async throws -> TrixInviteRegistrationResult
    func changePassword(_ request: TrixPasswordChangeRequest, session: TrixSession) async throws -> TrixPasswordChangeResult
}

protocol TrixStickerImportService: Sendable {
    func resolveTelegramStickerPack(_ reference: String, session: TrixSession) async throws -> TrixTelegramStickerPackImport
    func downloadTelegramStickerFile(_ sticker: TrixTelegramStickerImportItem, session: TrixSession) async throws -> TrixTelegramStickerFileDownload
}

protocol TrixAuthService: Sendable {
    func login(userID: String, password: String, serverURL: URL) async throws -> TrixSession
    func restore(session: TrixSession) async throws -> TrixAccount
    func logout(session: TrixSession) async throws
}

protocol TrixSyncService: Sendable {
    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary]
    func rooms(session: TrixSession) async throws -> [TrixRoomSummary]
}

extension TrixSyncService {
    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        []
    }
}

protocol TrixRoomService: Sendable {
    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem]
    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem]
    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem
    func sendText(_ request: TrixTextMessageSendRequest, session: TrixSession) async throws -> TrixTimelineItem
    func editText(_ request: TrixMessageEditRequest, session: TrixSession) async throws -> TrixTimelineItem
    func retractMessage(_ request: TrixMessageRetractionRequest, session: TrixSession) async throws -> TrixTimelineItem
    func markRoomDisplayed(
        _ request: TrixRoomDisplayedMarkerRequest,
        session: TrixSession
    ) async throws -> TrixRoomReadMarkerState
    func readMarkerState(roomID: String, session: TrixSession) async throws -> TrixRoomReadMarkerState?
    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction]
    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability
    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem
    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload
}

extension TrixRoomService {
    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        []
    }

    func sendText(_ request: TrixTextMessageSendRequest, session: TrixSession) async throws -> TrixTimelineItem {
        guard request.metadata.isEmpty else {
            throw TrixClientError.messageMetadataUnavailable
        }

        return try await sendText(request.text, roomID: request.roomID, session: session)
    }

    func editText(_ request: TrixMessageEditRequest, session: TrixSession) async throws -> TrixTimelineItem {
        throw TrixClientError.messageEditUnavailable
    }

    func retractMessage(_ request: TrixMessageRetractionRequest, session: TrixSession) async throws -> TrixTimelineItem {
        throw TrixClientError.messageRetractionUnavailable
    }

    func markRoomDisplayed(
        _ request: TrixRoomDisplayedMarkerRequest,
        session: TrixSession
    ) async throws -> TrixRoomReadMarkerState {
        throw TrixClientError.readMarkerUnavailable
    }

    func readMarkerState(roomID: String, session: TrixSession) async throws -> TrixRoomReadMarkerState? {
        nil
    }
}

protocol TrixTypingService: Sendable {
    func typingState(roomID: String, session: TrixSession) async throws -> TrixRoomTypingState
    func sendTypingState(_ state: TrixTypingState, roomID: String, session: TrixSession) async throws
}

protocol TrixRoomMembershipService: Sendable {
    func members(roomID: String, session: TrixSession) async throws -> [TrixRoomMember]
    func inviteUser(_ userID: String, roomID: String, session: TrixSession) async throws
    func removeUser(_ userID: String, roomID: String, session: TrixSession) async throws
    func leaveGroup(roomID: String, session: TrixSession) async throws
}

protocol TrixRoomBootstrapService: Sendable {
    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: TrixSession
    ) async throws -> TrixRoomSummary
    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: TrixSession
    ) async throws -> TrixRoomSummary
    func invitations(session: TrixSession) async throws -> [TrixRoomInvite]
    func acceptInvitation(roomID: String, session: TrixSession) async throws -> TrixRoomSummary
    func declineInvitation(roomID: String, session: TrixSession) async throws
    func joinRoom(roomID: String, session: TrixSession) async throws -> TrixRoomSummary
    func joinInvitedRooms(session: TrixSession) async throws -> [TrixRoomSummary]
}

protocol TrixDeviceVerificationService: Sendable {
    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus
    func deviceVerificationFlow(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func peerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity]
    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity]
    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity]
    func revokeOwnDevice(deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity]
    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow
    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow
    func setUpRecovery(session: TrixSession) async throws -> String
    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus
}

protocol TrixUserDirectoryService: Sendable {
    func searchUsers(
        _ searchTerm: String,
        limit: Int,
        session: TrixSession
    ) async throws -> TrixUserSearchResult
    func profile(userID: String, session: TrixSession) async throws -> TrixUserProfile
    func updateDisplayName(_ displayName: String, session: TrixSession) async throws -> TrixUserProfile
    func updateProfile(_ update: TrixUserProfileUpdate, session: TrixSession) async throws -> TrixUserProfile
}

protocol TrixPushRegistrationService: Sendable {
    func registerAPNsToken(_ token: TrixAPNsDeviceToken, session: TrixSession) async throws -> TrixPushRegistration
    func unregisterAPNsToken(
        _ token: TrixAPNsDeviceToken,
        registration: TrixPushRegistration?,
        session: TrixSession
    ) async throws
    func registerVoIPToken(_ token: TrixVoIPDeviceToken, session: TrixSession) async throws -> TrixVoIPPushRegistration
    func unregisterVoIPToken(
        _ token: TrixVoIPDeviceToken,
        registration: TrixVoIPPushRegistration?,
        session: TrixSession
    ) async throws
}

protocol TrixRoomNotificationProfileService: Sendable {
    func roomNotificationProfiles(session: TrixSession) async throws -> TrixRoomNotificationProfileSnapshot?
    func updateRoomNotificationProfiles(
        _ snapshot: TrixRoomNotificationProfileSnapshot,
        session: TrixSession
    ) async throws
}

protocol TrixClientStateService: Sendable {
    func setApplicationActive(_ isActive: Bool, session: TrixSession) async
}

protocol TrixReconnectService: Sendable {
    func disconnectForNetworkLoss(session: TrixSession) async
    func reconnect(session: TrixSession) async throws
}

protocol TrixCallControlService: Sendable {
    func prepareDirectVideoCall(
        peerUserID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization
    func joinDirectVideoCall(
        callID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization
    func joinGroupVoiceRoom(
        roomID: String,
        session: TrixSession
    ) async throws -> TrixCallJoinAuthorization
    func endCall(callID: String, session: TrixSession) async throws
    func turnCredentials(session: TrixSession) async throws -> TrixTurnCredentials
}

protocol TrixCallDescriptorService: Sendable {
    func callDescriptors(roomID: String, session: TrixSession) async throws -> [TrixReceivedCallDescriptor]
    func sendCallInvite(_ invite: TrixCallInvite, roomID: String, session: TrixSession) async throws -> TrixReceivedCallDescriptor
    func sendCallAnswer(_ answer: TrixCallAnswer, roomID: String, session: TrixSession) async throws -> TrixReceivedCallDescriptor
    func sendCallEnd(_ end: TrixCallEnd, roomID: String, session: TrixSession) async throws -> TrixReceivedCallDescriptor
    func sendVoiceRoomState(_ state: TrixVoiceRoomState, roomID: String, session: TrixSession) async throws -> TrixReceivedCallDescriptor
    func sendCallKeyRotation(_ rotation: TrixCallKeyRotation, roomID: String, session: TrixSession) async throws -> TrixReceivedCallDescriptor
}

protocol TrixMediaCallService: Sendable {
    func connect(
        authorization: TrixCallJoinAuthorization,
        mediaKey: TrixCallMediaKey
    ) async throws -> TrixActiveMediaCall
    func setMicrophoneEnabled(_ enabled: Bool, callID: String) async throws
    func setCameraEnabled(_ enabled: Bool, callID: String) async throws
    func disconnect(callID: String) async
}

typealias TrixService = TrixAuthService & TrixSyncService & TrixRoomService & TrixTypingService & TrixRoomMembershipService & TrixRoomBootstrapService & TrixDeviceVerificationService & TrixUserDirectoryService & TrixPushRegistrationService & TrixRoomNotificationProfileService & TrixClientStateService & TrixCallDescriptorService
