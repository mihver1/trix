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
    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction]
    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability
    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem
    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload
}

extension TrixRoomService {
    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        []
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
}

protocol TrixClientStateService: Sendable {
    func setApplicationActive(_ isActive: Bool, session: TrixSession) async
}

typealias TrixService = TrixAuthService & TrixSyncService & TrixRoomService & TrixTypingService & TrixRoomMembershipService & TrixRoomBootstrapService & TrixDeviceVerificationService & TrixUserDirectoryService & TrixPushRegistrationService & TrixClientStateService
