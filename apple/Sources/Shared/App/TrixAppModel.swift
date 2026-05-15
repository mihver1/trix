import Foundation

@MainActor
final class TrixAppModel: ObservableObject {
    @Published private(set) var session: TrixSession?
    @Published private(set) var account: TrixAccount?
    @Published private(set) var isStarting = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isRegistering = false
    @Published private(set) var isLoggingOut = false
    @Published private(set) var sessionCleanupMessage: String?
    @Published var errorMessage: String?
    @Published var selectedRoomID: String?
    @Published private(set) var lastRoomRefreshAt: Date?
    @Published private(set) var pushRegistration: TrixPushRegistration?
    @Published private(set) var pushRegistrationBlocker: TrixPushRegistrationBlocker? = .waitingForAPNsToken
    @Published private(set) var stickerPacks: [TrixStickerPack] = []
    @Published private(set) var isImportingStickerPack = false
    @Published private(set) var stickerImportMessage: String?

    let roomListViewModel: RoomListViewModel
    let timelineViewModel: TimelineViewModel
    let deviceVerificationViewModel: DeviceVerificationViewModel

    private let sessionStore: TrixSessionStore
    private let registrationService: TrixRegistrationService
    private let stickerImportService: TrixStickerImportService
    private let stickerLibraryStore: TrixStickerLibraryStore
    private let trixService: TrixService
    private var stickerAssetDataByID: [String: Data] = [:]
    private var apnsDeviceToken: TrixAPNsDeviceToken?
    private var hasStarted = false
    private let foregroundRefreshInterval: Duration = .seconds(10)

    init(
        sessionStore: TrixSessionStore = KeychainTrixSessionStore(),
        registrationService: TrixRegistrationService = HTTPInviteRegistrationService(),
        stickerImportService: TrixStickerImportService = HTTPStickerImportService(),
        stickerLibraryStore: TrixStickerLibraryStore = TrixStickerLibraryStore(),
        trixService: TrixService = XMPPMartinService()
    ) {
        self.sessionStore = sessionStore
        self.registrationService = registrationService
        self.stickerImportService = stickerImportService
        self.stickerLibraryStore = stickerLibraryStore
        self.trixService = trixService
        self.roomListViewModel = RoomListViewModel()
        self.timelineViewModel = TimelineViewModel()
        self.deviceVerificationViewModel = DeviceVerificationViewModel()
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var selectedRoom: TrixRoomSummary? {
        guard let selectedRoomID else {
            return nil
        }

        return roomListViewModel.rooms.first { $0.id == selectedRoomID }
    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isStarting = true
        defer { isStarting = false }

        do {
            guard let restoredSession = try sessionStore.loadSession() else {
                return
            }

            session = restoredSession
            account = try await trixService.restore(session: restoredSession)
            loadStickerLibrary(for: restoredSession.userID)
            await reloadRooms()
            await reloadDeviceVerificationStatus()
            await syncAPNsRegistrationIfPossible()
        } catch {
            clearAuthenticatedState()
            try? sessionStore.clearSession()
            errorMessage = error.trixUserFacingMessage
        }
    }

    func login(userID: String, password: String) async {
        guard !isLoggingIn else {
            return
        }

        isLoggingIn = true
        errorMessage = nil
        sessionCleanupMessage = nil
        defer { isLoggingIn = false }

        var newSession: TrixSession?
        do {
            let authenticatedSession = try await trixService.login(
                userID: userID,
                password: password,
                serverURL: XMPPClientConfiguration.connectionURL
            )
            newSession = authenticatedSession
            let restoredAccount = try await trixService.restore(session: authenticatedSession)
            try sessionStore.saveSession(authenticatedSession)
            session = authenticatedSession
            account = restoredAccount
            loadStickerLibrary(for: authenticatedSession.userID)
            await reloadRooms()
            await reloadDeviceVerificationStatus()
            await syncAPNsRegistrationIfPossible()
        } catch {
            if let newSession {
                try? await trixService.logout(session: newSession)
                try? sessionStore.clearSession()
            }
            clearAuthenticatedState()
            errorMessage = error.trixUserFacingMessage
        }
    }

    func registerWithInvite(inviteCode: String, localpart: String, displayName: String, password: String) async {
        guard !isRegistering, !isLoggingIn else {
            return
        }

        isRegistering = true
        errorMessage = nil
        sessionCleanupMessage = nil
        defer { isRegistering = false }

        var newSession: TrixSession?
        do {
            let registration = try await registrationService.redeemInvite(
                TrixInviteRegistrationRequest(
                    inviteCode: inviteCode,
                    localpart: localpart,
                    password: password,
                    displayName: displayName
                )
            )

            let authenticatedSession = try await trixService.login(
                userID: registration.userID,
                password: password,
                serverURL: XMPPClientConfiguration.connectionURL
            )
            newSession = authenticatedSession
            let restoredAccount = try await trixService.restore(session: authenticatedSession)
            try sessionStore.saveSession(authenticatedSession)
            session = authenticatedSession
            account = restoredAccount
            loadStickerLibrary(for: authenticatedSession.userID)

            if let displayName = registration.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                if let profile = try? await trixService.updateDisplayName(displayName, session: authenticatedSession) {
                    account = TrixAccount(
                        userID: profile.userID,
                        displayName: profile.displayName ?? "",
                        deviceID: authenticatedSession.deviceID
                    )
                }
            }

            await reloadRooms()
            await reloadDeviceVerificationStatus()
            await syncAPNsRegistrationIfPossible()
        } catch {
            if let newSession {
                try? await trixService.logout(session: newSession)
                try? sessionStore.clearSession()
            }
            clearAuthenticatedState()
            errorMessage = error.trixUserFacingMessage
        }
    }

    func issueInvite(localpart: String, displayName: String, ttlDays: Int) async throws -> TrixIssuedInvite {
        guard let session else {
            throw TrixClientError.missingSession
        }

        return try await registrationService.issueInvite(
            TrixInviteIssueRequest(
                localpart: localpart,
                displayName: displayName,
                ttlSeconds: max(1, ttlDays) * 24 * 60 * 60
            ),
            session: session
        )
    }

    func changePassword(currentPassword: String, newPassword: String) async throws -> TrixPasswordChangeResult {
        guard let session else {
            throw TrixClientError.missingSession
        }

        let result = try await registrationService.changePassword(
            TrixPasswordChangeRequest(
                currentPassword: currentPassword,
                newPassword: newPassword
            ),
            session: session
        )

        let updatedSession = TrixSession(
            userID: session.userID,
            deviceID: session.deviceID,
            homeserverURL: session.homeserverURL,
            accessToken: newPassword,
            refreshToken: session.refreshToken,
            oidcData: session.oidcData,
            sdkStoreID: session.sdkStoreID,
            createdAt: session.createdAt
        )
        try sessionStore.saveSession(updatedSession)
        self.session = updatedSession
        return result
    }

    func logout() async {
        guard !isLoggingOut else {
            return
        }

        isLoggingOut = true
        errorMessage = nil
        sessionCleanupMessage = nil
        defer { isLoggingOut = false }

        if let session {
            await unregisterAPNsRegistrationIfPossible(session: session)

            do {
                try await trixService.logout(session: session)
            } catch {
                errorMessage = error.trixUserFacingMessage
            }
        }

        do {
            try sessionStore.clearSession()
            sessionCleanupMessage = "Saved XMPP login was removed from Keychain. OMEMO device and trust state stay on this device until the app Keychain data is reset."
        } catch {
            errorMessage = error.trixUserFacingMessage
        }

        clearAuthenticatedState()
    }

    func registerAPNsDeviceToken(_ token: TrixAPNsDeviceToken) async {
        apnsDeviceToken = token
        await syncAPNsRegistrationIfPossible()
    }

    func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        applicationIsActive: Bool
    ) async -> TrixRemoteNotificationHandlingResult {
        let payload = TrixRemoteNotificationPayload(userInfo: userInfo)
        guard payload.isWakeOnlySync,
              let session,
              !isLoggingOut else {
            return .ignored
        }

        if let accountID = payload.accountID,
           accountID.caseInsensitiveCompare(session.userID) != .orderedSame {
            return .ignored
        }

        let previousRooms = roomListViewModel.rooms
        await refreshForeground(
            markSelectedRoomRead: applicationIsActive,
            reloadSelectedTimeline: applicationIsActive
        )

        let badgeCount = max(payload.badge ?? 0, totalUnreadCount)
        let localNotification = applicationIsActive ? nil : Self.localNotificationRequest(
            previousRooms: previousRooms,
            currentRooms: roomListViewModel.rooms,
            payload: payload,
            badgeCount: badgeCount
        )

        return TrixRemoteNotificationHandlingResult(
            didProcess: true,
            badgeCount: badgeCount,
            localNotification: localNotification
        )
    }

    func reloadRooms() async {
        guard let session else {
            roomListViewModel.clear()
            lastRoomRefreshAt = nil
            return
        }

        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID
        )
        lastRoomRefreshAt = Date()
        reconcileSelectedRoom()

        if let selectedRoomID {
            await loadTimeline(roomID: selectedRoomID)
        }
    }

    func refreshForeground(
        markSelectedRoomRead: Bool = true,
        reloadSelectedTimeline: Bool = true
    ) async {
        guard let session, !isLoggingOut else {
            return
        }

        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: markSelectedRoomRead ? selectedRoomID : nil,
            showsLoading: false
        )
        lastRoomRefreshAt = Date()
        reconcileSelectedRoom()

        if reloadSelectedTimeline, let selectedRoomID {
            await timelineViewModel.load(
                roomID: selectedRoomID,
                session: session,
                service: trixService,
                showsLoading: false
            )
        }
    }

    func runForegroundRefreshLoop() async {
        guard isAuthenticated else {
            return
        }

        while !Task.isCancelled && isAuthenticated {
            try? await Task.sleep(for: foregroundRefreshInterval)
            guard !Task.isCancelled else {
                return
            }

            await refreshForeground()
        }
    }

    func selectRoom(_ room: TrixRoomSummary) async {
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
        roomListViewModel.markRead(roomID: room.id)
    }

    func loadTimeline(roomID: String) async {
        guard let session else {
            timelineViewModel.clear()
            return
        }

        await timelineViewModel.load(roomID: roomID, session: session, service: trixService)
    }

    func send(text: String) async {
        guard let session, let selectedRoomID else {
            return
        }

        let roomID = selectedRoomID
        await timelineViewModel.send(
            text: text,
            roomID: roomID,
            session: session,
            service: trixService
        )
        try? await trixService.sendTypingState(.paused, roomID: roomID, session: session)
        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID
        )
        lastRoomRefreshAt = Date()
    }

    func setReaction(_ emoji: String, for item: TrixTimelineItem) async {
        guard let session, let selectedRoomID else {
            return
        }

        await timelineViewModel.setReaction(
            emoji,
            item: item,
            roomID: selectedRoomID,
            session: session,
            service: trixService
        )
    }

    func sendAttachment(_ attachment: TrixAttachmentUpload) async {
        guard let session, let selectedRoomID else {
            return
        }

        await timelineViewModel.sendAttachment(
            attachment,
            roomID: selectedRoomID,
            session: session,
            service: trixService
        )
        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID
        )
        lastRoomRefreshAt = Date()
    }

    func sendSticker(_ sticker: TrixSticker) async {
        guard let data = stickerAssetDataByID[sticker.id],
              let pack = stickerPacks.first(where: { $0.id == sticker.packID }) else {
            errorMessage = TrixClientError.stickerFileUnavailable.trixUserFacingMessage
            return
        }

        let upload = TrixAttachmentUpload(
            filename: sticker.filename,
            mimeType: sticker.mimeType,
            data: data,
            imageDimensions: sticker.imageDimensions,
            stickerMetadata: TrixStickerAttachmentMetadata(
                stickerID: sticker.id,
                packID: pack.id,
                packTitle: pack.title,
                source: pack.source,
                emoji: sticker.emoji
            )
        )
        await sendAttachment(upload)
    }

    func stickerData(for sticker: TrixSticker) -> Data? {
        stickerAssetDataByID[sticker.id]
    }

    func importTelegramStickerPack(_ reference: String) async {
        guard let session else {
            return
        }
        guard !isImportingStickerPack else {
            return
        }

        isImportingStickerPack = true
        stickerImportMessage = nil
        errorMessage = nil
        defer { isImportingStickerPack = false }

        do {
            let importResult = try await stickerImportService.resolveTelegramStickerPack(reference, session: session)
            guard !importResult.stickers.isEmpty else {
                throw TrixClientError.unsupportedStickerPack
            }

            var stickers: [TrixSticker] = []
            var dataByStickerID: [String: Data] = [:]
            for item in importResult.stickers {
                let download = try await stickerImportService.downloadTelegramStickerFile(item, session: session)
                let sticker = TrixSticker(
                    id: item.id,
                    packID: importResult.packID,
                    emoji: item.emoji,
                    filename: download.filename,
                    mimeType: download.mimeType,
                    sizeBytes: download.data.count,
                    imageDimensions: item.imageDimensions,
                    source: item.source
                )
                stickers.append(sticker)
                dataByStickerID[sticker.id] = download.data
            }

            let pack = TrixStickerPack(
                id: importResult.packID,
                title: importResult.title,
                source: importResult.source,
                stickers: stickers,
                importedAt: Date()
            )
            let state = try stickerLibraryStore.save(
                pack: pack,
                dataByStickerID: dataByStickerID,
                accountID: session.userID
            )
            stickerPacks = state.packs
            stickerAssetDataByID = state.dataByStickerID
            stickerImportMessage = Self.stickerImportMessage(
                pack: pack,
                importedStickerCount: stickers.count,
                unsupportedStickerCount: importResult.unsupportedStickerCount
            )
        } catch {
            stickerImportMessage = error.trixUserFacingMessage
        }
    }

    func importStickerPack(from metadata: TrixStickerAttachmentMetadata) async {
        guard metadata.source.kind == .telegram,
              let packName = metadata.source.name else {
            stickerImportMessage = TrixClientError.stickerPackUnavailable.trixUserFacingMessage
            return
        }

        await importTelegramStickerPack(packName)
    }

    func downloadAttachment(for item: TrixTimelineItem) async {
        guard let session else {
            return
        }

        await timelineViewModel.downloadAttachment(
            for: item,
            session: session,
            service: trixService
        )
    }

    func loadInlineAttachmentPreview(for item: TrixTimelineItem) async {
        guard let session else {
            return
        }

        await timelineViewModel.loadInlineAttachmentPreview(
            for: item,
            session: session,
            service: trixService
        )
    }

    func loadAttachmentSendAvailability(roomID: String) async {
        guard let session else {
            timelineViewModel.clearAttachmentSendAvailability()
            return
        }

        await timelineViewModel.loadAttachmentSendAvailability(
            roomID: roomID,
            session: session,
            service: trixService
        )
    }

    func loadTypingState(roomID: String) async {
        guard let session else {
            timelineViewModel.clearTypingState()
            return
        }

        await timelineViewModel.loadTypingState(
            roomID: roomID,
            session: session,
            service: trixService
        )
    }

    func sendTypingState(_ state: TrixTypingState, roomID: String? = nil) async {
        guard let session, let targetRoomID = roomID ?? selectedRoomID else {
            return
        }

        try? await trixService.sendTypingState(state, roomID: targetRoomID, session: session)
    }

    func members(roomID: String) async throws -> [TrixRoomMember] {
        guard let session else {
            throw TrixClientError.missingSession
        }

        return try await trixService.members(roomID: roomID, session: session)
    }

    func peerDeviceIdentities(for userID: String, refresh: Bool = false) async throws -> [TrixPeerDeviceIdentity] {
        guard let session else {
            throw TrixClientError.missingSession
        }

        if refresh {
            return try await trixService.refreshPeerDeviceIdentities(userID: userID, session: session)
        }

        return try await trixService.peerDeviceIdentities(userID: userID, session: session)
    }

    func trustPeerDevice(userID: String, deviceID: String) async throws -> [TrixPeerDeviceIdentity] {
        guard let session else {
            throw TrixClientError.missingSession
        }

        let devices = try await trixService.trustPeerDevice(userID: userID, deviceID: deviceID, session: session)
        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID
        )
        return devices
    }

    func trustAccountDevice(_ device: TrixPeerDeviceIdentity) async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.trustAccountDevice(
            device,
            session: session,
            service: trixService
        )
    }

    func inviteUser(_ userID: String, to roomID: String) async throws {
        guard let session else {
            throw TrixClientError.missingSession
        }

        try await trixService.inviteUser(userID, roomID: roomID, session: session)
        await reloadRooms()
    }

    func removeUser(_ userID: String, from roomID: String) async throws {
        guard let session else {
            throw TrixClientError.missingSession
        }

        try await trixService.removeUser(userID, roomID: roomID, session: session)
        await reloadRooms()
    }

    func searchUsers(_ searchTerm: String, limit: Int = 20) async throws -> TrixUserSearchResult {
        guard let session else {
            throw TrixClientError.missingSession
        }

        return try await trixService.searchUsers(searchTerm, limit: limit, session: session)
    }

    func profile(userID: String? = nil) async throws -> TrixUserProfile {
        guard let session else {
            throw TrixClientError.missingSession
        }

        return try await trixService.profile(userID: userID ?? session.userID, session: session)
    }

    func updateDisplayName(_ displayName: String) async throws -> TrixUserProfile {
        guard let session else {
            throw TrixClientError.missingSession
        }

        let profile = try await trixService.updateDisplayName(displayName, session: session)
        account = TrixAccount(
            userID: profile.userID,
            displayName: profile.displayName ?? "",
            deviceID: session.deviceID
        )
        return profile
    }

    func updateProfile(_ update: TrixUserProfileUpdate) async throws -> TrixUserProfile {
        guard let session else {
            throw TrixClientError.missingSession
        }

        let profile = try await trixService.updateProfile(update, session: session)
        account = TrixAccount(
            userID: profile.userID,
            displayName: profile.displayName ?? "",
            deviceID: session.deviceID
        )
        return profile
    }

    func createEncryptedDirectRoom(inviteeUserID: String, roomName: String) async -> Bool {
        guard let session else {
            return false
        }

        guard let room = await roomListViewModel.createEncryptedDirectRoom(
            inviteeUserID: inviteeUserID,
            roomName: roomName,
            session: session,
            service: trixService
        ) else {
            return false
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
        return true
    }

    func createEncryptedGroupRoom(name: String, inviteeUserIDs: [String]) async -> Bool {
        guard let session else {
            return false
        }

        guard let room = await roomListViewModel.createEncryptedGroupRoom(
            name: name,
            inviteeUserIDs: inviteeUserIDs,
            session: session,
            service: trixService
        ) else {
            return false
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
        return true
    }

    func reloadDeviceVerificationStatus() async {
        guard let session else {
            deviceVerificationViewModel.clear()
            return
        }

        await deviceVerificationViewModel.reload(session: session, service: trixService)
    }

    func requestDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.requestVerification(session: session, service: trixService)
    }

    func acceptDeviceVerificationRequest(_ request: TrixDeviceVerificationRequest) async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.acceptRequest(
            request,
            session: session,
            service: trixService
        )
    }

    func startSasDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.startSas(session: session, service: trixService)
    }

    func approveDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.approve(session: session, service: trixService)
    }

    func declineDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.decline(session: session, service: trixService)
    }

    func cancelDeviceVerification() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.cancel(session: session, service: trixService)
    }

    func setUpRecovery() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.setUpRecovery(session: session, service: trixService)
    }

    func confirmRecoveryKey() async {
        guard let session else {
            return
        }

        await deviceVerificationViewModel.confirmRecoveryKey(session: session, service: trixService)
    }

    func acceptInvitation(_ invitation: TrixRoomInvite) async {
        guard let session else {
            return
        }

        guard let room = await roomListViewModel.acceptInvitation(
            invitation,
            session: session,
            service: trixService
        ) else {
            return
        }

        await reloadRooms()
        selectedRoomID = room.id
        await loadTimeline(roomID: room.id)
    }

    func declineInvitation(_ invitation: TrixRoomInvite) async {
        guard let session else {
            return
        }

        let didDecline = await roomListViewModel.declineInvitation(
            invitation,
            session: session,
            service: trixService
        )

        if didDecline {
            await reloadRooms()
        }
    }

    func forgetRoomLocally(_ room: TrixRoomSummary) {
        roomListViewModel.forgetRoomLocally(roomID: room.id)
        if selectedRoomID == room.id {
            selectedRoomID = roomListViewModel.rooms.first?.id
            timelineViewModel.clear()
        }
    }

    private func reconcileSelectedRoom() {
        if let selectedRoomID,
           roomListViewModel.rooms.contains(where: { $0.id == selectedRoomID }) {
            return
        }

        selectedRoomID = roomListViewModel.rooms.first?.id
    }

    private var totalUnreadCount: Int {
        roomListViewModel.rooms.reduce(0) { partialResult, room in
            partialResult + max(room.unreadCount, 0)
        }
    }

    private static func localNotificationRequest(
        previousRooms: [TrixRoomSummary],
        currentRooms: [TrixRoomSummary],
        payload: TrixRemoteNotificationPayload,
        badgeCount: Int
    ) -> TrixLocalNotificationRequest? {
        let previousUnreadByRoomID = Dictionary(
            previousRooms.map { ($0.id.lowercased(), max($0.unreadCount, 0)) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let roomsWithNewUnread = currentRooms.filter { room in
            let previousUnread = previousUnreadByRoomID[room.id.lowercased()] ?? 0
            return max(room.unreadCount, 0) > previousUnread
        }
        let hasPayloadRoomHint = payload.roomID?.isEmpty == false
        let notificationUnreadCount = max(
            badgeCount,
            roomsWithNewUnread.reduce(0) { partialResult, room in
                partialResult + max(room.unreadCount, 0)
            },
            hasPayloadRoomHint ? 1 : 0
        )
        guard notificationUnreadCount > 0 else {
            return nil
        }

        let body = notificationUnreadCount == 1
            ? "New encrypted message"
            : "\(notificationUnreadCount) unread encrypted messages"
        let threadIdentifier = roomsWithNewUnread.count == 1
            ? roomsWithNewUnread[0].id
            : payload.roomID ?? "trix-unread"

        return TrixLocalNotificationRequest(
            title: "Trix",
            body: body,
            threadIdentifier: threadIdentifier,
            badgeCount: notificationUnreadCount
        )
    }

    private func syncAPNsRegistrationIfPossible() async {
        guard let apnsDeviceToken else {
            pushRegistration = nil
            pushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        guard let session else {
            pushRegistration = nil
            pushRegistrationBlocker = .waitingForSession
            return
        }

        do {
            pushRegistration = try await trixService.registerAPNsToken(apnsDeviceToken, session: session)
            pushRegistrationBlocker = nil
        } catch TrixClientError.apnsGatewayUnavailable {
            pushRegistration = nil
            pushRegistrationBlocker = .pushGatewayUnavailable
        } catch {
            pushRegistration = nil
            pushRegistrationBlocker = .registrationFailed
        }
    }

    private func unregisterAPNsRegistrationIfPossible(session: TrixSession) async {
        guard let apnsDeviceToken else {
            pushRegistration = nil
            pushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        try? await trixService.unregisterAPNsToken(
            apnsDeviceToken,
            registration: pushRegistration,
            session: session
        )
        pushRegistration = nil
        pushRegistrationBlocker = .waitingForSession
    }

    private func loadStickerLibrary(for accountID: String) {
        do {
            let state = try stickerLibraryStore.load(accountID: accountID)
            stickerPacks = state.packs
            stickerAssetDataByID = state.dataByStickerID
            stickerImportMessage = nil
        } catch {
            stickerPacks = []
            stickerAssetDataByID = [:]
            stickerImportMessage = error.trixUserFacingMessage
        }
    }

    private static func stickerImportMessage(
        pack: TrixStickerPack,
        importedStickerCount: Int,
        unsupportedStickerCount: Int
    ) -> String {
        if unsupportedStickerCount > 0 {
            return "Imported \(importedStickerCount) stickers from \(pack.title). Skipped \(unsupportedStickerCount) unsupported animated or video stickers."
        }

        return "Imported \(importedStickerCount) stickers from \(pack.title)."
    }

    private func clearAuthenticatedState() {
        session = nil
        account = nil
        selectedRoomID = nil
        pushRegistration = nil
        pushRegistrationBlocker = apnsDeviceToken == nil ? .waitingForAPNsToken : .waitingForSession
        lastRoomRefreshAt = nil
        stickerPacks = []
        stickerAssetDataByID = [:]
        stickerImportMessage = nil
        isImportingStickerPack = false
        roomListViewModel.clear()
        timelineViewModel.clear()
        deviceVerificationViewModel.clear()
    }
}

extension TrixAppModel {
    static func makeDefault() -> TrixAppModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TRIX_MATRIX_USE_MOCK_SERVICE"] == "1" {
            return TrixAppModel(
                sessionStore: TrixMockSessionStore(),
                registrationService: MockInviteRegistrationService(),
                stickerImportService: MockStickerImportService(),
                trixService: MockTrixService()
            )
        }
        #endif

        return TrixAppModel()
    }
}

#if DEBUG
private struct TrixMockSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        TrixSession(
            userID: "@me:trix.selfhost.ru",
            deviceID: "MOCK-IPHONE",
            homeserverURL: XMPPClientConfiguration.connectionURL,
            accessToken: "debug-placeholder-session",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "mock-ui-demo",
            createdAt: Date()
        )
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}

private struct MockStickerImportService: TrixStickerImportService {
    func resolveTelegramStickerPack(_ reference: String, session: TrixSession) async throws -> TrixTelegramStickerPackImport {
        let source = TrixStickerSource(kind: .telegram, name: "FakePack", url: "https://t.me/addstickers/FakePack")
        return TrixTelegramStickerPackImport(
            packID: "telegram:fakepack",
            title: "Fake Telegram Pack",
            source: source,
            stickers: [
                TrixTelegramStickerImportItem(
                    id: "telegram:fake-static-unique",
                    packID: "telegram:fakepack",
                    emoji: "🙂",
                    filename: "fake-static.png",
                    mimeType: "image/png",
                    sizeBytes: Self.mockImageData.count,
                    imageDimensions: TrixAttachmentImageDimensions(width: 24, height: 18),
                    source: source,
                    fileToken: "mock-token"
                ),
            ],
            unsupportedStickerCount: 2
        )
    }

    func downloadTelegramStickerFile(_ sticker: TrixTelegramStickerImportItem, session: TrixSession) async throws -> TrixTelegramStickerFileDownload {
        TrixTelegramStickerFileDownload(
            filename: sticker.filename,
            mimeType: sticker.mimeType,
            data: Self.mockImageData
        )
    }

    private static let mockImageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAKUlEQVR42mPQ6n2HhvSXd6IhYtQwjBpER4PI04apZtQgeho0mrKHoEEA2EuLf1hOf2sAAAAASUVORK5CYII=") ?? Data()
}
#endif
