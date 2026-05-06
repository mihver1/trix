import Foundation

actor MockMatrixService: MatrixService {
    private var roomSummaries: [MatrixRoomSummary]
    private var roomInvites: [MatrixRoomInvite]
    private var timelines: [String: [MatrixTimelineItem]]
    private var verificationState: MatrixDeviceVerificationState
    private var verificationFlow: MatrixDeviceVerificationFlow
    private var recoveryState: MatrixRecoveryState
    private var backupState: MatrixBackupState
    private var backupExistsOnServer: Bool

    init(now: Date = Date()) {
        let directRoom = MatrixRoomSummary(
            id: "!dm-alice:trix.selfhost.ru",
            name: "Alice",
            kind: .direct,
            isEncrypted: true,
            unreadCount: 1,
            lastMessagePreview: "Mock encrypted DM preview",
            lastActivityAt: now.addingTimeInterval(-240)
        )
        let groupRoom = MatrixRoomSummary(
            id: "!friends:trix.selfhost.ru",
            name: "Friends",
            kind: .group,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "Weekend plans",
            lastActivityAt: now.addingTimeInterval(-1_800)
        )
        let invite = MatrixRoomInvite(
            id: "!invite-carol:trix.selfhost.ru",
            roomName: "Carol",
            kind: .direct,
            isEncrypted: true,
            inviterUserID: "@carol:trix.selfhost.ru",
            inviterDisplayName: "Carol",
            receivedAt: now.addingTimeInterval(-120)
        )

        self.roomSummaries = [directRoom, groupRoom]
        self.roomInvites = [invite]
        self.verificationState = .unverified
        self.verificationFlow = .idle
        self.recoveryState = .disabled
        self.backupState = .unknown
        self.backupExistsOnServer = false
        self.timelines = [
            directRoom.id: [
                MatrixTimelineItem(
                    id: "$mock-dm-1",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-300),
                    body: "This is mock UI data. Real E2EE arrives with the Matrix SDK adapter.",
                    isLocalEcho: false
                ),
                MatrixTimelineItem(
                    id: "$mock-dm-2",
                    roomID: directRoom.id,
                    sender: "@me:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-240),
                    body: "The session and room UI are ready for adapter wiring.",
                    isLocalEcho: true
                ),
            ],
            groupRoom.id: [
                MatrixTimelineItem(
                    id: "$mock-group-1",
                    roomID: groupRoom.id,
                    sender: "@bob:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-2_400),
                    body: "Group rooms are normal Matrix rooms in this model.",
                    isLocalEcho: false
                ),
                MatrixTimelineItem(
                    id: "$mock-group-2",
                    roomID: groupRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-1_800),
                    body: "Weekend plans",
                    isLocalEcho: false
                ),
            ],
        ]
    }

    func login(userID: String, password: String, serverURL: URL) async throws -> MatrixSession {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUserID.hasPrefix("@"),
              normalizedUserID.contains(":\(MatrixClientConfiguration.serverName)"),
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatrixClientError.invalidCredentials
        }

        return MatrixSession(
            userID: normalizedUserID,
            deviceID: "MOCK-\(UUID().uuidString.prefix(8))",
            homeserverURL: serverURL,
            accessToken: "mock-token-\(UUID().uuidString)",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "mock-\(UUID().uuidString)",
            createdAt: Date()
        )
    }

    func restore(session: MatrixSession) async throws -> MatrixAccount {
        MatrixAccount(
            userID: session.userID,
            displayName: displayName(from: session.userID),
            deviceID: session.deviceID
        )
    }

    func logout(session: MatrixSession) async throws {
    }

    func rooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        roomSummaries.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    func deviceVerificationStatus(session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        MatrixDeviceVerificationStatus(
            userID: session.userID,
            deviceID: session.deviceID,
            state: verificationState,
            hasDevicesToVerifyAgainst: true,
            isLastDevice: false,
            recoveryState: recoveryState,
            backupState: backupState,
            backupExistsOnServer: backupExistsOnServer,
            ed25519Fingerprint: "MOCKED25519FINGERPRINT",
            curve25519IdentityKey: "MOCKCURVE25519IDENTITYKEY",
            updatedAt: Date()
        )
    }

    func deviceVerificationFlow(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow
    }

    func requestDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .requestSent,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func acceptDeviceVerificationRequest(
        _ request: MatrixDeviceVerificationRequest,
        session: MatrixSession
    ) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .accepted,
            request: request,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func startSasDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .challengeReceived,
            request: verificationFlow.request,
            challenge: .decimals(["1812", "5821", "9197"]),
            updatedAt: Date()
        )
        return verificationFlow
    }

    func approveDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .finished,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func declineDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .cancelled,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func cancelDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        verificationFlow = MatrixDeviceVerificationFlow(
            phase: .cancelled,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func setUpRecovery(session: MatrixSession) async throws -> String {
        guard recoveryState == .disabled else {
            throw MatrixClientError.recoverySetupUnavailable
        }

        recoveryState = .enabled
        backupState = .enabled
        backupExistsOnServer = true
        return "MOCK-RECOVERY-KEY"
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        guard !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatrixClientError.recoveryKeyRequired
        }
        guard recoveryState == .enabled || recoveryState == .incomplete else {
            throw MatrixClientError.recoveryKeyConfirmationUnavailable
        }

        recoveryState = .enabled
        backupState = .enabled
        backupExistsOnServer = true
        return try await deviceVerificationStatus(session: session)
    }

    func timeline(roomID: String, session: MatrixSession) async throws -> [MatrixTimelineItem] {
        timelines[roomID, default: []].sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    func sendText(_ text: String, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw MatrixClientError.emptyMessage
        }

        let item = MatrixTimelineItem(
            id: "$local-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(roomID: roomID, body: body, date: item.timestamp)
        return item
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let room = MatrixRoomSummary(
            id: "!mock-encrypted-dm-\(UUID().uuidString):\(MatrixClientConfiguration.serverName)",
            name: name,
            kind: .direct,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "No messages yet",
            lastActivityAt: Date()
        )
        roomSummaries.insert(room, at: 0)
        timelines[room.id] = []
        return room
    }

    func invitations(session: MatrixSession) async throws -> [MatrixRoomInvite] {
        roomInvites.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }
    }

    func acceptInvitation(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        guard let invite = roomInvites.first(where: { $0.id == roomID }) else {
            throw MatrixClientError.inviteUnavailable
        }

        roomInvites.removeAll { $0.id == roomID }
        let room = MatrixRoomSummary(
            id: invite.id,
            name: invite.title,
            kind: invite.kind,
            isEncrypted: invite.isEncrypted,
            unreadCount: 0,
            lastMessagePreview: "No messages yet",
            lastActivityAt: Date()
        )
        roomSummaries.insert(room, at: 0)
        timelines[room.id] = []
        return room
    }

    func declineInvitation(roomID: String, session: MatrixSession) async throws {
        guard roomInvites.contains(where: { $0.id == roomID }) else {
            throw MatrixClientError.inviteUnavailable
        }

        roomInvites.removeAll { $0.id == roomID }
    }

    func joinInvitedRooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        var joinedRooms: [MatrixRoomSummary] = []
        let pendingInvites = roomInvites
        for invite in pendingInvites {
            joinedRooms.append(try await acceptInvitation(roomID: invite.id, session: session))
        }
        return joinedRooms
    }

    func joinRoom(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        guard let room = roomSummaries.first(where: { $0.id == roomID }) else {
            throw MatrixClientError.roomUnavailable
        }
        return room
    }

    private func updateRoomPreview(roomID: String, body: String, date: Date) {
        roomSummaries = roomSummaries.map { room in
            guard room.id == roomID else {
                return room
            }

            return MatrixRoomSummary(
                id: room.id,
                name: room.name,
                kind: room.kind,
                isEncrypted: room.isEncrypted,
                unreadCount: 0,
                lastMessagePreview: body,
                lastActivityAt: date
            )
        }
    }

    private func displayName(from userID: String) -> String {
        let withoutAt = userID.dropFirst()
        let localpart = withoutAt.split(separator: ":").first.map(String.init) ?? String(withoutAt)
        return localpart.capitalized
    }
}
