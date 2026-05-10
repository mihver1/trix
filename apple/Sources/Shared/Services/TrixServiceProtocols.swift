import Foundation

protocol TrixSessionStore {
    func loadSession() throws -> TrixSession?
    func saveSession(_ session: TrixSession) throws
    func clearSession() throws
}

protocol TrixAuthService: Sendable {
    func login(userID: String, password: String, serverURL: URL) async throws -> TrixSession
    func restore(session: TrixSession) async throws -> TrixAccount
    func logout(session: TrixSession) async throws
}

protocol TrixSyncService: Sendable {
    func rooms(session: TrixSession) async throws -> [TrixRoomSummary]
}

protocol TrixRoomService: Sendable {
    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem]
    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem
    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction]
    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability
    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem
    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload
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

typealias TrixService = TrixAuthService & TrixSyncService & TrixRoomService & TrixTypingService & TrixRoomMembershipService & TrixRoomBootstrapService & TrixDeviceVerificationService & TrixUserDirectoryService & TrixPushRegistrationService
