import Foundation

@MainActor
final class RoomListViewModel: ObservableObject {
    @Published private(set) var rooms: [TrixRoomSummary] = []
    @Published private(set) var invitations: [TrixRoomInvite] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCreatingDirectRoom = false
    @Published private(set) var isCreatingGroupRoom = false
    @Published private(set) var invitationActionRoomID: String?
    @Published private(set) var errorMessage: String?
    private var readMarkersByRoomID: [String: TrixRoomReadMarkerState] = [:]

    func loadCached(
        session: TrixSession,
        service: TrixSyncService,
        selectedRoomID: String? = nil,
        readMarkers: [TrixRoomReadMarkerState] = []
    ) async {
        do {
            let cachedRooms = try await service.cachedRooms(session: session)
            guard !cachedRooms.isEmpty else {
                return
            }

            rooms = mergedRoomsAfterReload(
                cachedRooms,
                selectedRoomID: selectedRoomID,
                readMarkers: readMarkers
            )
        } catch {
            return
        }
    }

    func reload(
        session: TrixSession,
        service: TrixSyncService & TrixRoomBootstrapService,
        selectedRoomID: String? = nil,
        showsLoading: Bool = true,
        readMarkers: [TrixRoomReadMarkerState] = []
    ) async {
        if showsLoading {
            isLoading = true
        }
        errorMessage = nil
        defer {
            if showsLoading {
                isLoading = false
            }
        }

        do {
            let loadedRooms = try await service.rooms(session: session)
            rooms = mergedRoomsAfterReload(
                loadedRooms,
                selectedRoomID: selectedRoomID,
                readMarkers: readMarkers
            )
            invitations = try await service.invitations(session: session)
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        roomName: String,
        session: TrixSession,
        service: TrixRoomBootstrapService
    ) async -> TrixRoomSummary? {
        isCreatingDirectRoom = true
        errorMessage = nil
        defer { isCreatingDirectRoom = false }

        do {
            let normalizedInvitee = try Self.normalizedTrixUserID(inviteeUserID)
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
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: TrixSession,
        service: TrixRoomBootstrapService
    ) async -> TrixRoomSummary? {
        isCreatingGroupRoom = true
        errorMessage = nil
        defer { isCreatingGroupRoom = false }

        do {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw TrixClientError.groupRoomNameRequired
            }

            let normalizedInvitees = try Self.normalizedTrixUserIDs(
                inviteeUserIDs,
                excluding: session.userID
            )
            let room = try await service.createEncryptedGroupRoom(
                name: normalizedName,
                inviteeUserIDs: normalizedInvitees,
                session: session
            )
            rooms.removeAll { $0.id == room.id }
            rooms.insert(room, at: 0)
            return room
        } catch {
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    func acceptInvitation(
        _ invitation: TrixRoomInvite,
        session: TrixSession,
        service: TrixRoomBootstrapService
    ) async -> TrixRoomSummary? {
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
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    func declineInvitation(
        _ invitation: TrixRoomInvite,
        session: TrixSession,
        service: TrixRoomBootstrapService
    ) async -> Bool {
        invitationActionRoomID = invitation.id
        errorMessage = nil
        defer { invitationActionRoomID = nil }

        do {
            try await service.declineInvitation(roomID: invitation.id, session: session)
            invitations.removeAll { $0.id == invitation.id }
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
        }
    }

    func markRead(roomID: String) {
        let roomKey = roomID.lowercased()
        rooms = rooms.map { room in
            room.id.lowercased() == roomKey ? room.markingRead() : room
        }
    }

    func applyReadMarker(_ marker: TrixRoomReadMarkerState) {
        let roomKey = marker.roomID.lowercased()
        readMarkersByRoomID[roomKey] = marker
        rooms = rooms.map { room in
            guard room.id.lowercased() == roomKey,
                  Self.readMarker(marker, covers: room) else {
                return room
            }

            return room.markingRead()
        }
    }

    func applyReadMarkers(_ markers: [TrixRoomReadMarkerState]) {
        for marker in markers {
            applyReadMarker(marker)
        }
    }

    func forgetRoomLocally(roomID: String) {
        rooms.removeAll { $0.id == roomID }
        invitations.removeAll { $0.id == roomID }
    }

    func clear() {
        rooms = []
        invitations = []
        isLoading = false
        isCreatingDirectRoom = false
        isCreatingGroupRoom = false
        invitationActionRoomID = nil
        errorMessage = nil
        readMarkersByRoomID = [:]
    }

    private static func normalizedTrixUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@"), let separator = trimmed.firstIndex(of: ":") {
            let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
            let serverName = String(trimmed[trimmed.index(after: separator)...])
            guard !localpart.isEmpty, serverName == XMPPClientConfiguration.serverName else {
                throw TrixClientError.invalidTrixUserID
            }

            return "\(localpart)@\(serverName)"
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first,
              let serverName = parts.last,
              !localpart.isEmpty,
              serverName == XMPPClientConfiguration.serverName,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TrixClientError.invalidTrixUserID
        }

        return trimmed
    }

    private static func normalizedTrixUserIDs(_ userIDs: [String], excluding currentUserID: String) throws -> [String] {
        var seenUserIDs = Set<String>()
        var normalizedUserIDs: [String] = []
        let normalizedCurrentUserID = try? normalizedTrixUserID(currentUserID)

        for userID in userIDs {
            let normalized = try normalizedTrixUserID(userID)
            let lookupKey = normalized.lowercased()
            guard lookupKey != (normalizedCurrentUserID ?? currentUserID).lowercased(),
                  seenUserIDs.insert(lookupKey).inserted else {
                continue
            }
            normalizedUserIDs.append(normalized)
        }

        guard normalizedUserIDs.count >= 2 else {
            throw TrixClientError.groupInviteesRequired
        }

        return normalizedUserIDs
    }

    private static func displayName(from userID: String) -> String {
        if userID.hasPrefix("@") {
            return userID
                .dropFirst()
                .split(separator: ":")
                .first
                .map { String($0).capitalized } ?? userID
        }

        return userID
            .split(separator: "@")
            .first
            .map { String($0).capitalized } ?? userID
    }

    private func mergedRoomsAfterReload(
        _ loadedRooms: [TrixRoomSummary],
        selectedRoomID: String?,
        readMarkers: [TrixRoomReadMarkerState]
    ) -> [TrixRoomSummary] {
        let previousRoomsByID = Dictionary(
            rooms.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let selectedRoomKey = selectedRoomID?.lowercased()
        for marker in readMarkers {
            readMarkersByRoomID[marker.roomID.lowercased()] = marker
        }

        return loadedRooms.map { loadedRoom in
            let roomKey = loadedRoom.id.lowercased()
            guard roomKey != selectedRoomKey else {
                return loadedRoom.markingRead()
            }

            if let marker = readMarkersByRoomID[roomKey],
               Self.readMarker(marker, covers: loadedRoom) {
                return loadedRoom.markingRead()
            }

            let serverUnreadCount = max(loadedRoom.unreadCount, 0)
            guard let previousRoom = previousRoomsByID[roomKey] else {
                return loadedRoom.withUnreadCount(serverUnreadCount)
            }

            let previousUnreadCount = max(previousRoom.unreadCount, 0)
            if Self.hasNewIncomingActivity(loadedRoom, comparedTo: previousRoom) {
                return loadedRoom.withUnreadCount(max(serverUnreadCount, previousUnreadCount + 1))
            }

            return loadedRoom.withUnreadCount(max(serverUnreadCount, previousUnreadCount))
        }
    }

    private static func hasNewIncomingActivity(
        _ loadedRoom: TrixRoomSummary,
        comparedTo previousRoom: TrixRoomSummary
    ) -> Bool {
        guard !loadedRoom.lastMessagePreview.hasPrefix("You:") else {
            return false
        }

        if loadedRoom.lastActivityAt > previousRoom.lastActivityAt {
            return true
        }

        return loadedRoom.lastActivityAt == previousRoom.lastActivityAt &&
            loadedRoom.lastMessagePreview != previousRoom.lastMessagePreview
    }

    private static func readMarker(
        _ marker: TrixRoomReadMarkerState,
        covers room: TrixRoomSummary
    ) -> Bool {
        marker.displayedAt >= room.lastActivityAt
    }
}
