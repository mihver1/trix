import Foundation

actor MockTrixService: TrixService {
    private static let mockImageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAKUlEQVR42mPQ6n2HhvSXd6IhYtQwjBpER4PI04apZtQgeho0mrKHoEEA2EuLf1hOf2sAAAAASUVORK5CYII=") ?? Data()

    private var roomSummaries: [TrixRoomSummary]
    private var roomInvites: [TrixRoomInvite]
    private var membersByRoomID: [String: [TrixRoomMember]]
    private var timelines: [String: [TrixTimelineItem]]
    private var verificationState: TrixDeviceVerificationState
    private var verificationFlow: TrixDeviceVerificationFlow
    private var recoveryState: TrixRecoveryState
    private var backupState: TrixBackupState
    private var backupExistsOnServer: Bool
    private var attachmentDataBySourceJSON: [String: Data]
    private var profilesByUserID: [String: TrixUserProfile]
    private var typingUserIDsByRoomID: [String: [String]]

    init(now: Date = Date()) {
        let directRoom = TrixRoomSummary(
            id: "!dm-alice:trix.selfhost.ru",
            name: "Alice",
            kind: .direct,
            isEncrypted: true,
            unreadCount: 1,
            lastMessagePreview: "trix-preview.png",
            lastActivityAt: now.addingTimeInterval(-60)
        )
        let groupRoom = TrixRoomSummary(
            id: "!friends:trix.selfhost.ru",
            name: "Friends",
            kind: .group,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "Weekend plans",
            lastActivityAt: now.addingTimeInterval(-1_800)
        )
        let invite = TrixRoomInvite(
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
                TrixRoomMember(userID: "@me:trix.selfhost.ru", displayName: "Me", membership: .joined),
                TrixRoomMember(userID: "@alice:trix.selfhost.ru", displayName: "Alice", membership: .joined),
            ],
            groupRoom.id: [
                TrixRoomMember(userID: "@me:trix.selfhost.ru", displayName: "Me", membership: .joined),
                TrixRoomMember(userID: "@alice:trix.selfhost.ru", displayName: "Alice", membership: .joined),
                TrixRoomMember(userID: "@bob:trix.selfhost.ru", displayName: "Bob", membership: .joined),
            ],
        ]
        self.verificationState = .unverified
        self.verificationFlow = .idle
        self.recoveryState = .disabled
        self.backupState = .unknown
        self.backupExistsOnServer = false
        self.attachmentDataBySourceJSON = [
            "mock://attachment/brief": Data("Mock Trix attachment bytes".utf8),
            "mock://attachment/image": Self.mockImageData,
        ]
        self.typingUserIDsByRoomID = [:]
        self.profilesByUserID = [
            "@me:trix.selfhost.ru": TrixUserProfile(userID: "@me:trix.selfhost.ru", displayName: "Me", avatarURL: nil),
            "@alice:trix.selfhost.ru": TrixUserProfile(userID: "@alice:trix.selfhost.ru", displayName: "Alice", avatarURL: nil),
            "@bob:trix.selfhost.ru": TrixUserProfile(userID: "@bob:trix.selfhost.ru", displayName: "Bob", avatarURL: nil),
            "@carol:trix.selfhost.ru": TrixUserProfile(userID: "@carol:trix.selfhost.ru", displayName: "Carol", avatarURL: nil),
            "@dora:trix.selfhost.ru": TrixUserProfile(userID: "@dora:trix.selfhost.ru", displayName: "Dora", avatarURL: nil),
        ]
        self.timelines = [
            directRoom.id: [
                TrixTimelineItem(
                    id: "$mock-dm-1",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-300),
                    body: "This is mock UI data. Real E2EE is handled by the XMPP OMEMO adapter.",
                    isLocalEcho: false,
                    attachment: nil
                ),
                TrixTimelineItem(
                    id: "$mock-dm-2",
                    roomID: directRoom.id,
                    sender: "@me:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-240),
                    body: "The session and room UI are ready for adapter wiring.",
                    isLocalEcho: true,
                    attachment: nil,
                    deliveryState: .delivered
                ),
                TrixTimelineItem(
                    id: "$mock-dm-3",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-120),
                    body: "release-brief.pdf",
                    isLocalEcho: false,
                    attachment: TrixTimelineAttachment(
                        kind: .file,
                        filename: "release-brief.pdf",
                        mimeType: "application/pdf",
                        sizeBytes: 28,
                        sourceJSON: "mock://attachment/brief"
                    )
                ),
                TrixTimelineItem(
                    id: "$mock-dm-4",
                    roomID: directRoom.id,
                    sender: "@alice:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-60),
                    body: "trix-preview.png",
                    isLocalEcho: false,
                    attachment: TrixTimelineAttachment(
                        kind: .image,
                        filename: "trix-preview.png",
                        mimeType: "image/png",
                        sizeBytes: Self.mockImageData.count,
                        sourceJSON: "mock://attachment/image",
                        imageDimensions: TrixAttachmentImageDimensions(width: 24, height: 18)
                    )
                ),
            ],
            groupRoom.id: [
                TrixTimelineItem(
                    id: "$mock-group-1",
                    roomID: groupRoom.id,
                    sender: "@bob:trix.selfhost.ru",
                    timestamp: now.addingTimeInterval(-2_400),
                    body: "Group rooms are normal Trix rooms in this model.",
                    isLocalEcho: false,
                    attachment: nil
                ),
                TrixTimelineItem(
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

    func login(userID: String, password: String, serverURL: URL) async throws -> TrixSession {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUserID.hasPrefix("@"),
              normalizedUserID.contains(":\(TrixClientConfiguration.serverName)"),
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.invalidCredentials
        }

        let profile = TrixUserProfile(
            userID: normalizedUserID,
            displayName: displayName(from: normalizedUserID),
            avatarURL: nil
        )
        profilesByUserID[normalizedUserID.lowercased()] = profile

        return TrixSession(
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

    func restore(session: TrixSession) async throws -> TrixAccount {
        let profile = profilesByUserID[session.userID.lowercased()]
        return TrixAccount(
            userID: session.userID,
            displayName: profile?.displayName ?? displayName(from: session.userID),
            deviceID: session.deviceID
        )
    }

    func logout(session: TrixSession) async throws {
    }

    func registerAPNsToken(_ token: TrixAPNsDeviceToken, session: TrixSession) async throws -> TrixPushRegistration {
        TrixPushRegistration(
            environment: token.environment,
            provider: token.environment.xmppPushProvider,
            gatewayJID: "push.trix.selfhost.ru",
            node: "mock-\(session.deviceID)",
            registeredAt: Date()
        )
    }

    func unregisterAPNsToken(
        _ token: TrixAPNsDeviceToken,
        registration: TrixPushRegistration?,
        session: TrixSession
    ) async throws {
    }

    func searchUsers(
        _ searchTerm: String,
        limit: Int,
        session: TrixSession
    ) async throws -> TrixUserSearchResult {
        let query = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return TrixUserSearchResult(users: [], limited: false)
        }

        let ownUserID = session.userID.lowercased()
        let matches = profilesByUserID.values
            .filter { profile in
                profile.userID.lowercased() != ownUserID &&
                    (profile.userID.localizedCaseInsensitiveContains(query) ||
                     profile.title.localizedCaseInsensitiveContains(query))
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        let resultLimit = max(1, limit)
        return TrixUserSearchResult(
            users: Array(matches.prefix(resultLimit)),
            limited: matches.count > resultLimit
        )
    }

    func profile(userID: String, session: TrixSession) async throws -> TrixUserProfile {
        let normalizedUserID = try Self.normalizedTrixUserID(userID)
        return profilesByUserID[normalizedUserID.lowercased()] ?? TrixUserProfile(
            userID: normalizedUserID,
            displayName: displayName(from: normalizedUserID),
            avatarURL: nil
        )
    }

    func updateDisplayName(_ displayName: String, session: TrixSession) async throws -> TrixUserProfile {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = profilesByUserID[session.userID.lowercased()]
        let profile = TrixUserProfile(
            userID: session.userID,
            displayName: normalizedDisplayName.isEmpty ? nil : normalizedDisplayName,
            avatarURL: existing?.avatarURL,
            metadata: existing?.metadata ?? .empty
        )
        profilesByUserID[session.userID.lowercased()] = profile
        return profile
    }

    func updateProfile(_ update: TrixUserProfileUpdate, session: TrixSession) async throws -> TrixUserProfile {
        let existing = profilesByUserID[session.userID.lowercased()]
        let profile = TrixUserProfile(
            userID: session.userID,
            displayName: update.displayName.isEmpty ? nil : update.displayName,
            avatarURL: existing?.avatarURL,
            metadata: update.metadata
        )
        profilesByUserID[session.userID.lowercased()] = profile
        return profile
    }

    func rooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        roomSummaries.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        TrixDeviceVerificationStatus(
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

    func deviceVerificationFlow(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow
    }

    func peerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        [mockPeerDevice(for: userID)]
    }

    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        [mockPeerDevice(for: userID)]
    }

    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        [mockPeerDevice(for: userID, deviceID: deviceID)]
    }

    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .requestSent,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .accepted,
            request: request,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .challengeReceived,
            request: verificationFlow.request,
            challenge: .decimals(["1812", "5821", "9197"]),
            updatedAt: Date()
        )
        return verificationFlow
    }

    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .finished,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .cancelled,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        verificationFlow = TrixDeviceVerificationFlow(
            phase: .cancelled,
            request: nil,
            challenge: nil,
            updatedAt: Date()
        )
        return verificationFlow
    }

    func setUpRecovery(session: TrixSession) async throws -> String {
        guard recoveryState == .disabled else {
            throw TrixClientError.recoverySetupUnavailable
        }

        recoveryState = .enabled
        backupState = .enabled
        backupExistsOnServer = true
        return "MOCK-RECOVERY-KEY"
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        guard !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.recoveryKeyRequired
        }
        guard recoveryState == .enabled || recoveryState == .incomplete else {
            throw TrixClientError.recoveryKeyConfirmationUnavailable
        }

        recoveryState = .enabled
        backupState = .enabled
        backupExistsOnServer = true
        return try await deviceVerificationStatus(session: session)
    }

    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        timelines[roomID, default: []].sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw TrixClientError.emptyMessage
        }

        let item = TrixTimelineItem(
            id: "$local-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil,
            deliveryState: .sent
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(roomID: roomID, body: "You: \(body)", date: item.timestamp)
        return item
    }

    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction] {
        let normalizedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmoji.isEmpty else {
            throw TrixClientError.reactionsUnavailable
        }

        var roomTimeline = timelines[roomID, default: []]
        guard let itemIndex = roomTimeline.firstIndex(where: { $0.id == messageID }) else {
            throw TrixClientError.roomUnavailable
        }

        var item = roomTimeline[itemIndex]
        var reactions = item.reactions.filter { reaction in
            !(reaction.sender.caseInsensitiveCompare(session.userID) == .orderedSame && reaction.emoji == normalizedEmoji)
        }

        if reactions.count == item.reactions.count {
            reactions.append(
                TrixMessageReaction(
                    emoji: normalizedEmoji,
                    sender: session.userID,
                    timestamp: Date(),
                    isLocalEcho: true
                )
            )
        }

        item = item.withReactions(reactions)
        roomTimeline[itemIndex] = item
        timelines[roomID] = roomTimeline
        return reactions
    }

    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability {
        guard let room = roomSummaries.first(where: { $0.id == roomID }) else {
            return .blocked(roomID: roomID, reason: .unavailable)
        }

        let recipients = membersByRoomID[roomID, default: []]
            .map(\.userID)
            .filter { $0.caseInsensitiveCompare(session.userID) != .orderedSame }
            .sorted()
        if room.kind == .group, recipients.isEmpty {
            return .blocked(roomID: roomID, reason: .groupRecipientSetUnavailable)
        }

        return .allowed(roomID: roomID, recipientUserIDs: recipients)
    }

    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        guard !attachment.data.isEmpty else {
            throw TrixClientError.emptyAttachment
        }

        let sourceJSON = "mock://attachment/\(UUID().uuidString)"
        attachmentDataBySourceJSON[sourceJSON] = attachment.data

        let item = TrixTimelineItem(
            id: "$local-attachment-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: attachment.filename,
            isLocalEcho: true,
            attachment: TrixTimelineAttachment(
                kind: attachment.isImage ? .image : .file,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count,
                sourceJSON: sourceJSON,
                imageDimensions: attachment.imageDimensions,
                imageBlurhash: attachment.imageBlurhash
            ),
            deliveryState: .sent
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(roomID: roomID, body: "You: Attachment: \(attachment.filename)", date: item.timestamp)
        return item
    }

    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload {
        guard let sourceJSON = attachment.sourceJSON else {
            throw TrixClientError.attachmentDownloadUnavailable
        }

        return TrixAttachmentDownload(
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            data: attachmentDataBySourceJSON[sourceJSON] ?? Data("Mock attachment: \(attachment.filename)".utf8)
        )
    }

    func typingState(roomID: String, session: TrixSession) async throws -> TrixRoomTypingState {
        TrixRoomTypingState(
            roomID: roomID,
            typingUserIDs: typingUserIDsByRoomID[roomID] ?? [],
            updatedAt: Date()
        )
    }

    func sendTypingState(_ state: TrixTypingState, roomID: String, session: TrixSession) async throws {
        switch state {
        case .idle, .paused, .composing:
            typingUserIDsByRoomID[roomID] = []
        }
    }

    func members(roomID: String, session: TrixSession) async throws -> [TrixRoomMember] {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        return membersByRoomID[roomID, default: []]
    }

    func inviteUser(_ userID: String, roomID: String, session: TrixSession) async throws {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        let normalizedUserID = try Self.normalizedTrixUserID(userID)
        var members = membersByRoomID[roomID, default: []]
        members.removeAll { $0.userID.lowercased() == normalizedUserID.lowercased() }
        members.append(
            TrixRoomMember(
                userID: normalizedUserID,
                displayName: displayName(from: normalizedUserID),
                membership: .invited
            )
        )
        membersByRoomID[roomID] = members
    }

    func removeUser(_ userID: String, roomID: String, session: TrixSession) async throws {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        let normalizedUserID = try Self.normalizedTrixUserID(userID)
        membersByRoomID[roomID, default: []].removeAll { $0.userID.lowercased() == normalizedUserID.lowercased() }
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        let room = TrixRoomSummary(
            id: "!mock-encrypted-dm-\(UUID().uuidString):\(TrixClientConfiguration.serverName)",
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
            TrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
            TrixRoomMember(userID: inviteeUserID, displayName: displayName(from: inviteeUserID), membership: .invited),
        ]
        return room
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        let room = TrixRoomSummary(
            id: "!mock-encrypted-group-\(UUID().uuidString):\(TrixClientConfiguration.serverName)",
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
            TrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
        ] + inviteeUserIDs.map { userID in
            TrixRoomMember(userID: userID, displayName: displayName(from: userID), membership: .invited)
        }
        return room
    }

    func invitations(session: TrixSession) async throws -> [TrixRoomInvite] {
        roomInvites.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }
    }

    func acceptInvitation(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        guard let invite = roomInvites.first(where: { $0.id == roomID }) else {
            throw TrixClientError.inviteUnavailable
        }

        roomInvites.removeAll { $0.id == roomID }
        let room = TrixRoomSummary(
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
                TrixRoomMember(userID: session.userID, displayName: displayName(from: session.userID), membership: .joined),
                TrixRoomMember(userID: inviterUserID, displayName: invite.inviterDisplayName, membership: .joined),
            ]
        }
        return room
    }

    func declineInvitation(roomID: String, session: TrixSession) async throws {
        guard roomInvites.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.inviteUnavailable
        }

        roomInvites.removeAll { $0.id == roomID }
    }

    func joinInvitedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        var joinedRooms: [TrixRoomSummary] = []
        let pendingInvites = roomInvites
        for invite in pendingInvites {
            joinedRooms.append(try await acceptInvitation(roomID: invite.id, session: session))
        }
        return joinedRooms
    }

    func joinRoom(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        guard let room = roomSummaries.first(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }
        return room
    }

    private func updateRoomPreview(roomID: String, body: String, date: Date) {
        roomSummaries = roomSummaries.map { room in
            guard room.id == roomID else {
                return room
            }

            return TrixRoomSummary(
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
        let localpart: String
        if userID.hasPrefix("@") {
            let withoutAt = userID.dropFirst()
            localpart = withoutAt.split(separator: ":").first.map(String.init) ?? String(withoutAt)
        } else {
            localpart = userID.split(separator: "@").first.map(String.init) ?? userID
        }
        return localpart.capitalized
    }

    private func mockPeerDevice(for userID: String, deviceID: String = "1001") -> TrixPeerDeviceIdentity {
        TrixPeerDeviceIdentity(
            userID: userID,
            deviceID: deviceID,
            fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
            trustState: .trusted,
            isActive: true,
            isLocalDevice: false
        )
    }

    private static func normalizedTrixUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":"),
              separator != trimmed.index(after: trimmed.startIndex) else {
            throw TrixClientError.invalidTrixUserID
        }

        let serverName = String(trimmed[trimmed.index(after: separator)...])
        guard serverName == TrixClientConfiguration.serverName else {
            throw TrixClientError.invalidTrixUserID
        }

        return trimmed
    }
}
