import Foundation

@MainActor
final class RoomListViewModel: ObservableObject {
    @Published private(set) var rooms: [MatrixRoomSummary] = []
    @Published private(set) var invitations: [MatrixRoomInvite] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCreatingDirectRoom = false
    @Published private(set) var invitationActionRoomID: String?
    @Published private(set) var errorMessage: String?

    func reload(session: MatrixSession, service: MatrixSyncService & MatrixRoomBootstrapService) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            rooms = try await service.rooms(session: session)
            invitations = try await service.invitations(session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        roomName: String,
        session: MatrixSession,
        service: MatrixRoomBootstrapService
    ) async -> MatrixRoomSummary? {
        isCreatingDirectRoom = true
        errorMessage = nil
        defer { isCreatingDirectRoom = false }

        do {
            let normalizedInvitee = try Self.normalizedMatrixUserID(inviteeUserID)
            let normalizedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = normalizedName.isEmpty ? Self.displayName(from: normalizedInvitee) : normalizedName
            let room = try await service.createEncryptedDirectRoom(
                inviteeUserID: normalizedInvitee,
                name: finalName,
                session: session
            )
            rooms.removeAll { $0.id == room.id }
            rooms.insert(room, at: 0)
            return room
        } catch {
            errorMessage = error.matrixUserFacingMessage
            return nil
        }
    }

    func acceptInvitation(
        _ invitation: MatrixRoomInvite,
        session: MatrixSession,
        service: MatrixRoomBootstrapService
    ) async -> MatrixRoomSummary? {
        invitationActionRoomID = invitation.id
        errorMessage = nil
        defer { invitationActionRoomID = nil }

        do {
            let room = try await service.acceptInvitation(roomID: invitation.id, session: session)
            invitations.removeAll { $0.id == invitation.id }
            rooms.removeAll { $0.id == room.id }
            rooms.insert(room, at: 0)
            return room
        } catch {
            errorMessage = error.matrixUserFacingMessage
            return nil
        }
    }

    func declineInvitation(
        _ invitation: MatrixRoomInvite,
        session: MatrixSession,
        service: MatrixRoomBootstrapService
    ) async -> Bool {
        invitationActionRoomID = invitation.id
        errorMessage = nil
        defer { invitationActionRoomID = nil }

        do {
            try await service.declineInvitation(roomID: invitation.id, session: session)
            invitations.removeAll { $0.id == invitation.id }
            return true
        } catch {
            errorMessage = error.matrixUserFacingMessage
            return false
        }
    }

    func clear() {
        rooms = []
        invitations = []
        isLoading = false
        isCreatingDirectRoom = false
        invitationActionRoomID = nil
        errorMessage = nil
    }

    private static func normalizedMatrixUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":"),
              separator != trimmed.index(after: trimmed.startIndex) else {
            throw MatrixClientError.invalidMatrixUserID
        }

        let serverName = String(trimmed[trimmed.index(after: separator)...])
        guard serverName == MatrixClientConfiguration.serverName else {
            throw MatrixClientError.invalidMatrixUserID
        }

        return trimmed
    }

    private static func displayName(from userID: String) -> String {
        let localpart = userID
            .dropFirst()
            .split(separator: ":")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
    }
}
