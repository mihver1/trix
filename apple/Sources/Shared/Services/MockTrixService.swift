import Foundation

actor MockTrixService: TrixService {
    private static let mockImageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAKUlEQVR42mPQ6n2HhvSXd6IhYtQwjBpER4PI04apZtQgeho0mrKHoEEA2EuLf1hOf2sAAAAASUVORK5CYII=") ?? Data()

    private var roomSummaries: [TrixRoomSummary]
    private var roomInvites: [TrixRoomInvite]
    private var membersByRoomID: [String: [TrixRoomMember]]
    private var timelines: [String: [TrixTimelineItem]]
    private var verificationState: TrixDeviceVerificationState
    private var verificationFlow: TrixDeviceVerificationFlow
    private var trustedPeerDeviceIDs: Set<String>
    private var publishedOwnDeviceIDs: Set<String>
    private var recoveryState: TrixRecoveryState
    private var backupState: TrixBackupState
    private var backupExistsOnServer: Bool
    private var attachmentDataBySourceJSON: [String: Data]
    private var profilesByUserID: [String: TrixUserProfile]
    private var notificationProfilesByAccountID: [String: TrixRoomNotificationProfileSnapshot]
    private var typingUserIDsByRoomID: [String: [String]]
    private var callDescriptorsByRoomID: [String: [TrixReceivedCallDescriptor]]
    private var readMarkersByRoomAndUserID: [String: TrixRoomReadMarkerState]
    private var readMarkerStateRequests: Int
    private var restoreError: TrixClientError?
    private var delayedMemberRoomIDs: Set<String>
    private var memberReleaseWaiters: [String: [CheckedContinuation<Void, Never>]]

    init(
        now: Date = Date(),
        restoreError: TrixClientError? = nil,
        delayedMemberRoomIDs: Set<String> = []
    ) {
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
        self.trustedPeerDeviceIDs = []
        self.publishedOwnDeviceIDs = ["1001", "2002"]
        self.recoveryState = .disabled
        self.backupState = .unknown
        self.backupExistsOnServer = false
        self.attachmentDataBySourceJSON = [
            "mock://attachment/brief": Data("Mock Trix attachment bytes".utf8),
            "mock://attachment/image": Self.mockImageData,
        ]
        self.typingUserIDsByRoomID = [:]
        self.callDescriptorsByRoomID = [:]
        self.readMarkersByRoomAndUserID = [:]
        self.readMarkerStateRequests = 0
        self.restoreError = restoreError
        self.delayedMemberRoomIDs = delayedMemberRoomIDs
        self.memberReleaseWaiters = [:]
        self.profilesByUserID = [
            "@me:trix.selfhost.ru": TrixUserProfile(userID: "@me:trix.selfhost.ru", displayName: "Me", avatarURL: nil),
            "@alice:trix.selfhost.ru": TrixUserProfile(userID: "@alice:trix.selfhost.ru", displayName: "Alice", avatarURL: nil),
            "@bob:trix.selfhost.ru": TrixUserProfile(userID: "@bob:trix.selfhost.ru", displayName: "Bob", avatarURL: nil),
            "@carol:trix.selfhost.ru": TrixUserProfile(userID: "@carol:trix.selfhost.ru", displayName: "Carol", avatarURL: nil),
            "@dora:trix.selfhost.ru": TrixUserProfile(userID: "@dora:trix.selfhost.ru", displayName: "Dora", avatarURL: nil),
        ]
        self.notificationProfilesByAccountID = [:]
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
        let normalizedUserID = try Self.normalizedTrixUserID(userID)
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        if let restoreError {
            throw restoreError
        }

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

    func registerVoIPToken(_ token: TrixVoIPDeviceToken, session: TrixSession) async throws -> TrixVoIPPushRegistration {
        TrixVoIPPushRegistration(
            environment: token.environment,
            provider: token.environment.xmppVoIPPushProvider,
            gatewayJID: "push.trix.selfhost.ru",
            node: "mock-voip-\(session.deviceID)",
            registeredAt: Date()
        )
    }

    func unregisterVoIPToken(
        _ token: TrixVoIPDeviceToken,
        registration: TrixVoIPPushRegistration?,
        session: TrixSession
    ) async throws {
    }

    func roomNotificationProfiles(session: TrixSession) async throws -> TrixRoomNotificationProfileSnapshot? {
        notificationProfilesByAccountID[session.userID.lowercased()]
    }

    func updateRoomNotificationProfiles(
        _ snapshot: TrixRoomNotificationProfileSnapshot,
        session: TrixSession
    ) async throws {
        notificationProfilesByAccountID[session.userID.lowercased()] = snapshot
    }

    func setApplicationActive(_ isActive: Bool, session: TrixSession) async {
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

    func userActivity(userID: String, session: TrixSession) async throws -> TrixUserActivity {
        let normalizedUserID = try Self.normalizedTrixUserID(userID)
        if normalizedUserID.caseInsensitiveCompare(session.userID) == .orderedSame ||
            normalizedUserID.localizedCaseInsensitiveContains("alice") {
            return TrixUserActivity(availability: .online)
        }

        return TrixUserActivity(availability: .offline, lastSeenAt: Date().addingTimeInterval(-60 * 60))
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

    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        try await rooms(session: session)
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
        if userID.caseInsensitiveCompare(session.userID) == .orderedSame {
            return mockOwnAccountDevices(userID: session.userID)
        }

        return [mockPeerDevice(for: userID)]
    }

    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        if userID.caseInsensitiveCompare(session.userID) == .orderedSame {
            return mockOwnAccountDevices(userID: session.userID)
        }

        return [mockPeerDevice(for: userID)]
    }

    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        trustedPeerDeviceIDs.insert(Self.mockDeviceTrustKey(userID: userID, deviceID: deviceID))
        if userID.caseInsensitiveCompare(session.userID) == .orderedSame {
            return mockOwnAccountDevices(userID: session.userID)
        }

        return [mockPeerDevice(for: userID, deviceID: deviceID)]
    }

    func revokeOwnDevice(deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        guard deviceID.caseInsensitiveCompare(session.deviceID) != .orderedSame else {
            throw TrixClientError.currentDeviceRevocationUnavailable
        }
        guard publishedOwnDeviceIDs.remove(deviceID) != nil else {
            throw TrixClientError.ownDeviceUnavailable
        }

        trustedPeerDeviceIDs.remove(Self.mockDeviceTrustKey(userID: session.userID, deviceID: deviceID))
        return mockOwnAccountDevices(userID: session.userID)
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
            challenge: Self.mockSASChallenge,
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

    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        timelines[roomID, default: []].sorted { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        try await cachedTimeline(roomID: roomID, session: session)
    }

    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        try await sendText(
            TrixTextMessageSendRequest(text: text, roomID: roomID),
            session: session
        )
    }

    func sendText(_ request: TrixTextMessageSendRequest, session: TrixSession) async throws -> TrixTimelineItem {
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw TrixClientError.emptyMessage
        }
        guard roomSummary(roomID: request.roomID) != nil else {
            throw TrixClientError.roomUnavailable
        }

        let metadata = try resolvedSendMetadata(
            request.metadata,
            body: body,
            roomID: request.roomID
        )
        let messageID = "$local-\(UUID().uuidString)"
        let thread = metadata.thread.map { thread in
            if thread.rootMessageID == nil && thread.parentMessageID == nil {
                return TrixThreadReference(
                    threadID: thread.threadID,
                    rootMessageID: messageID,
                    parentThreadID: thread.parentThreadID,
                    replyCount: thread.replyCount
                )
            }

            return thread
        }

        let item = TrixTimelineItem(
            id: messageID,
            roomID: request.roomID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil,
            deliveryState: .sent,
            mentions: metadata.mentions,
            replyTo: metadata.replyTo,
            thread: thread
        )

        timelines[request.roomID, default: []].append(item)
        if let thread {
            recordThreadReply(thread, roomID: request.roomID, replyMessageID: item.id)
        }
        updateRoomPreview(roomID: request.roomID, body: "You: \(body)", date: item.timestamp)
        return item
    }

    func editText(_ request: TrixMessageEditRequest, session: TrixSession) async throws -> TrixTimelineItem {
        let body = request.newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw TrixClientError.emptyMessage
        }

        var roomTimeline = timelines[request.roomID, default: []]
        guard let itemIndex = roomTimeline.firstIndex(where: { $0.id == request.messageID }) else {
            throw TrixClientError.invalidMessageReference
        }

        let item = roomTimeline[itemIndex]
        guard isOwnTextMessage(item, session: session),
              !item.isRetracted,
              itemIndex == lastEditableOwnTextMessageIndex(in: roomTimeline, session: session) else {
            throw TrixClientError.messageEditUnavailable
        }

        let editedAt = Date()
        let edited = item.withEditedBody(
            body,
            editState: TrixTimelineEditState(
                editedAt: editedAt,
                editedBy: session.userID,
                replacementMessageID: "$mock-edit-\(UUID().uuidString)"
            )
        )
        roomTimeline[itemIndex] = edited
        timelines[request.roomID] = roomTimeline
        if itemIndex == roomTimeline.index(before: roomTimeline.endIndex) {
            updateRoomPreview(roomID: request.roomID, body: "You: \(body)", date: editedAt)
        }
        return edited
    }

    func retractMessage(_ request: TrixMessageRetractionRequest, session: TrixSession) async throws -> TrixTimelineItem {
        var roomTimeline = timelines[request.roomID, default: []]
        guard let itemIndex = roomTimeline.firstIndex(where: { $0.id == request.messageID }) else {
            throw TrixClientError.invalidMessageReference
        }

        let item = roomTimeline[itemIndex]
        guard isOwnTextMessage(item, session: session), !item.isRetracted else {
            throw TrixClientError.messageRetractionUnavailable
        }

        let retractedAt = Date()
        let retracted = item.withRetractionState(
            TrixTimelineRetractionState(
                retractedAt: retractedAt,
                retractedBy: session.userID
            )
        )
        roomTimeline[itemIndex] = retracted
        timelines[request.roomID] = roomTimeline
        if itemIndex == roomTimeline.index(before: roomTimeline.endIndex) {
            updateRoomPreview(roomID: request.roomID, body: "You: \(retracted.body)", date: retractedAt)
        }
        return retracted
    }

    func markRoomDisplayed(
        _ request: TrixRoomDisplayedMarkerRequest,
        session: TrixSession
    ) async throws -> TrixRoomReadMarkerState {
        guard roomSummary(roomID: request.roomID) != nil else {
            throw TrixClientError.roomUnavailable
        }

        var roomTimeline = timelines[request.roomID, default: []]
        guard let itemIndex = roomTimeline.firstIndex(where: { $0.id == request.messageID }) else {
            throw TrixClientError.invalidMessageReference
        }

        let displayedAt = Date()
        let receipt = TrixReadMarkerReceipt(
            messageID: request.messageID,
            senderID: session.userID,
            displayedAt: displayedAt
        )
        let item = roomTimeline[itemIndex]
        roomTimeline[itemIndex] = item.withReadState(item.readState.withDisplayedReceipt(receipt))
        timelines[request.roomID] = roomTimeline

        let state = TrixRoomReadMarkerState(
            roomID: request.roomID,
            displayedMessageID: request.messageID,
            senderID: session.userID,
            displayedAt: displayedAt
        )
        readMarkersByRoomAndUserID[readMarkerKey(roomID: request.roomID, userID: session.userID)] = state
        roomSummaries = roomSummaries.map { room in
            room.id == request.roomID ? room.markingRead() : room
        }
        return state
    }

    func readMarkerState(roomID: String, session: TrixSession) async throws -> TrixRoomReadMarkerState? {
        readMarkerStateRequests += 1
        return readMarkersByRoomAndUserID[readMarkerKey(roomID: roomID, userID: session.userID)]
    }

    func readMarkerStateRequestCount() -> Int {
        readMarkerStateRequests
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
                kind: attachment.isSticker ? .sticker : (attachment.isImage ? .image : .file),
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count,
                sourceJSON: sourceJSON,
                imageDimensions: attachment.imageDimensions,
                imageBlurhash: attachment.imageBlurhash,
                stickerMetadata: attachment.stickerMetadata
            ),
            deliveryState: .sent
        )

        timelines[roomID, default: []].append(item)
        updateRoomPreview(
            roomID: roomID,
            body: attachment.isSticker ? "You: Sticker" : "You: Attachment: \(attachment.filename)",
            date: item.timestamp
        )
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

    func callDescriptors(roomID: String, session: TrixSession) async throws -> [TrixReceivedCallDescriptor] {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        return callDescriptorsByRoomID[roomID, default: []]
    }

    func sendCallInvite(
        _ invite: TrixCallInvite,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try storeCallDescriptor(.invite(invite), roomID: roomID, session: session)
    }

    func sendCallAnswer(
        _ answer: TrixCallAnswer,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try storeCallDescriptor(.answer(answer), roomID: roomID, session: session)
    }

    func sendCallEnd(
        _ end: TrixCallEnd,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try storeCallDescriptor(.end(end), roomID: roomID, session: session)
    }

    func sendVoiceRoomState(
        _ state: TrixVoiceRoomState,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try storeCallDescriptor(.voiceRoomState(state), roomID: roomID, session: session)
    }

    func sendCallKeyRotation(
        _ rotation: TrixCallKeyRotation,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try storeCallDescriptor(.keyRotation(rotation), roomID: roomID, session: session)
    }

    func appendRemoteCallDescriptor(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        senderID: String
    ) throws -> TrixReceivedCallDescriptor {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        let received = TrixReceivedCallDescriptor(
            id: "$mock-remote-call-\(UUID().uuidString)",
            roomID: roomID,
            senderID: senderID,
            timestamp: Date(),
            descriptor: descriptor,
            isLocalEcho: false
        )
        callDescriptorsByRoomID[roomID, default: []].append(received)
        return received
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

        if delayedMemberRoomIDs.contains(roomID) {
            await withCheckedContinuation { continuation in
                memberReleaseWaiters[roomID, default: []].append(continuation)
            }
        }

        return membersByRoomID[roomID, default: []]
    }

    func releaseMembers(roomID: String) {
        delayedMemberRoomIDs.remove(roomID)
        let waiters = memberReleaseWaiters.removeValue(forKey: roomID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
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

    func leaveGroup(roomID: String, session: TrixSession) async throws {
        guard let room = roomSummaries.first(where: { $0.id == roomID }),
              room.kind == .group else {
            throw TrixClientError.roomUnavailable
        }

        roomSummaries.removeAll { $0.id == roomID }
        membersByRoomID.removeValue(forKey: roomID)
        timelines.removeValue(forKey: roomID)
        callDescriptorsByRoomID.removeValue(forKey: roomID)
        typingUserIDsByRoomID.removeValue(forKey: roomID)
        readMarkersByRoomAndUserID = readMarkersByRoomAndUserID.filter { key, _ in
            !key.hasPrefix("\(roomID.lowercased())|")
        }
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

    private func storeCallDescriptor(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        session: TrixSession
    ) throws -> TrixReceivedCallDescriptor {
        guard roomSummaries.contains(where: { $0.id == roomID }) else {
            throw TrixClientError.roomUnavailable
        }

        let received = TrixReceivedCallDescriptor(
            id: "$mock-call-\(UUID().uuidString)",
            roomID: roomID,
            senderID: session.userID,
            timestamp: Date(),
            descriptor: descriptor,
            isLocalEcho: true
        )
        callDescriptorsByRoomID[roomID, default: []].append(received)
        return received
    }

    private func resolvedSendMetadata(
        _ metadata: TrixTextMessageSendMetadata,
        body: String,
        roomID: String
    ) throws -> TrixTextMessageSendMetadata {
        try validateMentions(metadata.mentions, body: body, roomID: roomID)
        let replyTo = try metadata.replyTo.map { reply in
            try resolvedReplyReference(reply, roomID: roomID)
        }
        let thread = try metadata.thread.map { thread in
            try resolvedThreadReference(thread, roomID: roomID)
        }

        return TrixTextMessageSendMetadata(
            mentions: metadata.mentions,
            replyTo: replyTo,
            thread: thread
        )
    }

    private func validateMentions(
        _ mentions: [TrixMentionReference],
        body: String,
        roomID: String
    ) throws {
        guard !mentions.isEmpty else {
            return
        }

        let knownMemberIDs = Set(membersByRoomID[roomID, default: []].map { $0.userID.lowercased() })
        for mention in mentions {
            guard mention.range.isValid(in: body) else {
                throw TrixClientError.invalidMessageReference
            }
            guard knownMemberIDs.contains(mention.targetUserID.lowercased()) else {
                throw TrixClientError.invalidMentionTarget
            }
        }
    }

    private func resolvedReplyReference(
        _ reply: TrixReplyReference,
        roomID: String
    ) throws -> TrixReplyReference {
        guard let target = timelines[roomID, default: []].first(where: { $0.id == reply.targetMessageID }) else {
            throw TrixClientError.invalidMessageReference
        }

        return TrixReplyReference(
            targetMessageID: reply.targetMessageID,
            targetSenderID: reply.targetSenderID ?? target.sender,
            targetRoomID: reply.targetRoomID ?? target.roomID,
            preview: reply.preview ?? Self.replyPreview(from: target)
        )
    }

    private func resolvedThreadReference(
        _ thread: TrixThreadReference,
        roomID: String
    ) throws -> TrixThreadReference {
        guard roomSummary(roomID: roomID)?.kind == .group else {
            throw TrixClientError.messageMetadataUnavailable
        }

        let threadID = thread.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else {
            throw TrixClientError.invalidMessageReference
        }

        let roomTimeline = timelines[roomID, default: []]
        let rootMessageID = trimmedNonEmpty(thread.rootMessageID)
        let parentMessageID = trimmedNonEmpty(thread.parentMessageID)
        if let rootMessageID,
           !roomTimeline.contains(where: { $0.id == rootMessageID }) {
            throw TrixClientError.invalidMessageReference
        }
        if let parentMessageID,
           !roomTimeline.contains(where: { $0.id == parentMessageID }) {
            throw TrixClientError.invalidMessageReference
        }

        return TrixThreadReference(
            threadID: threadID,
            rootMessageID: rootMessageID,
            parentMessageID: parentMessageID,
            parentThreadID: trimmedNonEmpty(thread.parentThreadID),
            replyCount: thread.replyCount
        )
    }

    private func recordThreadReply(
        _ thread: TrixThreadReference,
        roomID: String,
        replyMessageID: String
    ) {
        guard let rootMessageID = thread.rootMessageID ?? thread.parentMessageID,
              rootMessageID != replyMessageID else {
            return
        }

        var roomTimeline = timelines[roomID, default: []]
        guard let rootIndex = roomTimeline.firstIndex(where: { $0.id == rootMessageID }) else {
            return
        }

        let root = roomTimeline[rootIndex]
        let rootThread = root.thread ?? TrixThreadReference(
            threadID: thread.threadID,
            rootMessageID: rootMessageID
        )
        roomTimeline[rootIndex] = root.withThread(rootThread.withReplyCount(rootThread.replyCount + 1))
        timelines[roomID] = roomTimeline
    }

    private func isOwnTextMessage(_ item: TrixTimelineItem, session: TrixSession) -> Bool {
        item.sender.caseInsensitiveCompare(session.userID) == .orderedSame && item.attachment == nil
    }

    private func lastEditableOwnTextMessageIndex(
        in items: [TrixTimelineItem],
        session: TrixSession
    ) -> Int? {
        items.lastIndex { item in
            isOwnTextMessage(item, session: session) && !item.isRetracted
        }
    }

    private func roomSummary(roomID: String) -> TrixRoomSummary? {
        roomSummaries.first { $0.id == roomID }
    }

    private func readMarkerKey(roomID: String, userID: String) -> String {
        "\(roomID.lowercased())|\(userID.lowercased())"
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func replyPreview(from item: TrixTimelineItem) -> TrixReplyPreview {
        if item.isRetracted {
            return TrixReplyPreview(senderID: item.sender, isUnavailable: true)
        }

        return TrixReplyPreview(
            senderID: item.sender,
            body: item.attachment == nil ? item.body : nil,
            attachmentFilename: item.attachment?.filename,
            isUnavailable: false
        )
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
        let isTrusted = trustedPeerDeviceIDs.contains(Self.mockDeviceTrustKey(userID: userID, deviceID: deviceID))
        return TrixPeerDeviceIdentity(
            userID: userID,
            deviceID: deviceID,
            fingerprint: "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99",
            visualVerification: Self.mockVisualVerification,
            trustState: isTrusted ? .trusted : .undecided,
            isActive: true,
            isLocalDevice: false
        )
    }

    private func mockOwnAccountDevices(userID: String) -> [TrixPeerDeviceIdentity] {
        publishedOwnDeviceIDs.sorted().map { deviceID in
            let isTrusted = trustedPeerDeviceIDs.contains(Self.mockDeviceTrustKey(userID: userID, deviceID: deviceID))
            let fingerprint = Self.mockFingerprint(for: deviceID)
            return TrixPeerDeviceIdentity(
                userID: userID,
                deviceID: deviceID,
                fingerprint: fingerprint,
                visualVerification: TrixDeviceVisualVerification.visualFingerprint(fingerprint),
                trustState: isTrusted ? .trusted : .undecided,
                isActive: true,
                isLocalDevice: false
            )
        }
    }

    private static let mockVisualVerification = TrixDeviceVisualVerification.visualFingerprint(
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
    ) ?? TrixDeviceVisualVerification(
        kind: .fingerprintDisplayTransform,
        symbols: [
            TrixDeviceVerificationEmoji(symbol: "⭐", description: "Star", position: 0),
            TrixDeviceVerificationEmoji(symbol: "🌊", description: "Wave", position: 1),
            TrixDeviceVerificationEmoji(symbol: "🔑", description: "Key", position: 2),
            TrixDeviceVerificationEmoji(symbol: "🌙", description: "Moon", position: 3),
            TrixDeviceVerificationEmoji(symbol: "🛡️", description: "Shield", position: 4),
        ],
        decimalGroups: ["AABBCCDD", "EEFF0011", "22334455", "66778899"],
        sourceText: "AABBCCDDEEFF00112233445566778899"
    )

    private static let mockSASChallenge: TrixDeviceVerificationChallenge = .emojis([
        TrixDeviceVerificationEmoji(symbol: "⭐", description: "Star", position: 0),
        TrixDeviceVerificationEmoji(symbol: "🌊", description: "Wave", position: 1),
        TrixDeviceVerificationEmoji(symbol: "🔑", description: "Key", position: 2),
        TrixDeviceVerificationEmoji(symbol: "🌙", description: "Moon", position: 3),
        TrixDeviceVerificationEmoji(symbol: "🛡️", description: "Shield", position: 4),
    ])

    private static func mockDeviceTrustKey(userID: String, deviceID: String) -> String {
        "\(userID.lowercased())|\(deviceID)"
    }

    private static func mockFingerprint(for deviceID: String) -> String {
        switch deviceID {
        case "1001":
            return "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
        case "2002":
            return "10:32:54:76:98:BA:DC:FE:01:23:45:67:89:AB:CD:EF"
        default:
            return "AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB"
        }
    }

    private static func normalizedTrixUserID(_ userID: String) throws -> String {
        try TrixUserIdentity.normalizedMatrixUserID(userID)
    }
}
