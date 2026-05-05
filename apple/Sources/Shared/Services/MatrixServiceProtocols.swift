import Foundation

protocol MatrixSessionStore {
    func loadSession() throws -> MatrixSession?
    func saveSession(_ session: MatrixSession) throws
    func clearSession() throws
}

protocol MatrixAuthService: Sendable {
    func login(userID: String, password: String, serverURL: URL) async throws -> MatrixSession
    func restore(session: MatrixSession) async throws -> MatrixAccount
    func logout(session: MatrixSession) async throws
}

protocol MatrixSyncService: Sendable {
    func rooms(session: MatrixSession) async throws -> [MatrixRoomSummary]
}

protocol MatrixRoomService: Sendable {
    func timeline(roomID: String, session: MatrixSession) async throws -> [MatrixTimelineItem]
    func sendText(_ text: String, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem
}

protocol MatrixRoomBootstrapService: Sendable {
    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: MatrixSession
    ) async throws -> MatrixRoomSummary
    func invitations(session: MatrixSession) async throws -> [MatrixRoomInvite]
    func acceptInvitation(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary
    func declineInvitation(roomID: String, session: MatrixSession) async throws
    func joinRoom(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary
    func joinInvitedRooms(session: MatrixSession) async throws -> [MatrixRoomSummary]
}

typealias MatrixService = MatrixAuthService & MatrixSyncService & MatrixRoomService & MatrixRoomBootstrapService
