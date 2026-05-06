import Foundation

actor MockMatrixService: MatrixService {
    private var roomSummaries: [MatrixRoomSummary]
    private var roomInvites: [MatrixRoomInvite]
    private var membersByRoomID: [String: [MatrixRoomMember]]
    private var timelines: [String: [MatrixTimelineItem]]
    private var verificationState: MatrixDeviceVerificationState
    private var verificationFlow: MatrixDeviceVerificationFlow
    private var recoveryState: MatrixRecoveryState
    private var backupState: MatrixBackupState
    private var backupExistsOnServer: Bool
    private var attachmentDataBySourceJSON: [String: Data]

    init(now: Date = Date()) {
        let directRoom = MatrixRoomSummary(
            id: "!dm-alice:trix.selfhost.ru",
            name: "Alice",
            kind: .direct,
            isEncrypted: true,
            unreadCount: 1,
            lastMessagePreview: "Mock DM preview",
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
        self.membersByRoomID = [
            directRoom.id: [
                MatrixRoomMember(userID: "@me:trix.selfhost.ru", displayName: "Me", membership: .joined),
                MatrixRoomMember(userID: "@alice:trix.selfhost.ru", displayName: "Alice", membership: .joined),
            ],
            groupRoom.id: [
                MatrixRoomMember(userID: "@me:trix.selfhost.ru", displayName: "Me", membership: .joined),
                MatrixRoomMember(userID: "@alice:trix.selfhost.ru", displayName: "Alice", membership: .joined),
                MatrixRoomMember(userID: "@bob:trix.selfhost.ru", displayName: "Bob", membership: .joined),
            ],
        ]
        self.verificationState = .unverified
        self.verificationFlow = .idle
        self.recoveryState = .disabled
        self.backupState = .unknown
        self.backupExistsOnServer = false
        self.attachmentDataBySourceJSON = [
            "mock://attachment/brief": Data("Mock Matrix attachment bytes".utf8),
        ]
        self.timelines = [
            directRoom.id: [
                MatrixTimelineItem(
                    id: "$mock-dm-1",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-300),
                    body: "This is mock UI data. Real E2EE arrives with the Matrix SDK adapter.",
                    isLocalEcho: false,
                    attachment: nil
                ),
                MatrixTimelineItem(
                    id: "$mock-dm-2",
                    roomID: directRoom.id,
                    sender: "@me:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-240),
                    body: "The session and room UI are ready for adapter wiring.",
                    isLocalEcho: true,
                    attachment: nil
                ),
                MatrixTimelineItem(
                    id: "$mock-dm-3",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-120),
                    body: "release-brief.pdf",
                    isLocalEcho: false,
                    attachment: MatrixTimelineAttachment(
                        kind: .file,
                        filename: "release-brief.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 28,
                        sourceJSON: "mock://attachment/brief"
                    )
                ),
            ],
            groupRoom.id: [
                MatrixTimelineItem(
                    id: "$mock-group-1",
                    roomID: groupRoom.id,
                    sender: "@bob:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-2_400),
                    body: "Group rooms are normal Matrix rooms in this model.",
                    isLocalEcho: false,
                    attachment: nil
                ),
                MatrixTimelineItem(
                    id: "$mock-group-2",
                    roomID: groupRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-1_800),
                    body: "Weekend plans",
                    isLocalEcho: false,
                    attachment: nil
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
            isLocalEcho: true,
            attachment: nil
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(roomID: roomID, body: body, date: item.timestamp)
        return item
    }

    func sendAttachment(_ attachment: MatrixAttachmentUpload, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        guard !attachment.data.isEmpty else {
            throw MatrixClientError.emptyAttachment
        }

        let sourceJSON = "mock://attachment/\(UUID().uuidString)"
        attachmentDataBySourceJSON[sourceJSON] = attachment.data

        let item = MatrixTimelineItem(
            id: "$local-attachment-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: attachment.filename,
            isLocalEcho: true,
            attachment: MatrixTimelineAttachment(
                kind: attachment.isImage ? .image : .file,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count,
                sourceJSON: sourceJSON
            )
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(roomID: roomID, body: "Attachment: \(attachment.filename)", date: item.timestamp)
        return item
    }

    func downloadAttachment(_ attachment: MatrixTimelineAttachment, session: MatrixSession) async throws -> MatrixAttachmentDownload {
        guard let sourceJSON = attachment.sourceJSON else {
            throw MatrixClientError.attachmentDownloadUnavailable
        }

        return MatrixAttachmentDownload(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            data: attachmentDataBySourceJSON[sourceJSON] ?? Data("Mock attachment: \(attachment.filename)".utf8)
        )
    }

    func members(roomID: String, session: MatrixSession) async throws -> [MatrixRoomMember] {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw MatrixClientError.roomUnavailable
        }

        return membersByRoomID[roomID, default: []]
    }

    func inviteUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw MatrixClientError.roomUnavailable
        }

        let normalizedUserID = try Self.normalizedMatrixUserID(userID)
        var members = membersByRoomID[roomID, default: []]
        members.removeAll { $0.userID.lowercased() == normalizedUserID.lowercased() }
        members.append(
            MatrixRoomMember(
                userID: normalizedUserID,
                displayName: displayName(from: normalizedUserID),
                membership: .invited
            )
        )
        membersByRoomID[roomID] = members
    }

    func removeUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw MatrixClientError.roomUnavailable
        }

        let normalizedUserID = try Self.normalizedMatrixUserID(userID)
        membersByRoomID[roomID, default: []].removeAll { $0.userID.lowercased() == normalizedUserID.lowercased() }
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
        membersByRoomID[room.id] = [
            MatrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
            MatrixRoomMember(userID: inviteeUserID, displayName: displayName(from: inviteeUserID), membership: .invited),
        ]
        return room
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let room = MatrixRoomSummary(
            id: "!mock-encrypted-group-\(UUID().uuidString):\(MatrixClientConfiguration.serverName)",
            name: name,
            kind: .group,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "No messages yet",
            lastActivityAt: Date()
        )
        roomSummaries.insert(room, at: 0)
        timelines[room.id] = []
        membersByRoomID[room.id] = [
            MatrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
        ] + inviteeUserIDs.map { userID in
            MatrixRoomMember(userID: userID, displayName: displayName(from: userID), membership: .invited)
        }
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
        if let inviterUserID = invite.inviterUserID {
            membersByRoomID[room.id] = [
                MatrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
                MatrixRoomMember(userID: inviterUserID, displayName: invite.inviterDisplayName, membership: .joined),
            ]
        }
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
}
