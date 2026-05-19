import Foundation

struct TrixStartupStatus: Equatable {
    let step: String
    let title: String
    let detail: String

    static let idle = TrixStartupStatus(
        step: "",
        title: "",
        detail: ""
    )

    static let checkingSavedSession = TrixStartupStatus(
        step: "Step 1 of 3",
        title: "Checking saved session",
        detail: "Reading Trix credentials from Keychain."
    )

    static func openingXMPPSession(host: String) -> TrixStartupStatus {
        TrixStartupStatus(
            step: "Step 2 of 3",
            title: "Opening XMPP session",
            detail: "Connecting to \(host), negotiating TLS, and restoring the encrypted device state."
        )
    }

    static let finishingRestore = TrixStartupStatus(
        step: "Step 3 of 3",
        title: "Session restored",
        detail: "Loading chats, device trust, and push state."
    )

    static let restoreFailed = TrixStartupStatus(
        step: "Restore failed",
        title: "Could not restore session",
        detail: "Returning to sign-in so the saved session can be replaced."
    )
}

@MainActor
final class TrixAppModel: ObservableObject {
    @Published private(set) var session: TrixSession?
    @Published private(set) var account: TrixAccount?
    @Published private(set) var isStarting = false
    @Published private(set) var startupStatus = TrixStartupStatus.idle
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isRegistering = false
    @Published private(set) var isLoggingOut = false
    @Published private(set) var sessionCleanupMessage: String?
    @Published var errorMessage: String?
    @Published var selectedRoomID: String?
    @Published private(set) var lastRoomRefreshAt: Date?
    @Published private(set) var pushRegistration: TrixPushRegistration?
    @Published private(set) var pushRegistrationBlocker: TrixPushRegistrationBlocker? = .waitingForAPNsToken
    @Published private(set) var voipPushRegistration: TrixVoIPPushRegistration?
    @Published private(set) var voipPushRegistrationBlocker: TrixPushRegistrationBlocker? = .waitingForAPNsToken
    @Published private(set) var stickerPacks: [TrixStickerPack] = []
    @Published private(set) var isImportingStickerPack = false
    @Published private(set) var stickerImportMessage: String?
    @Published private(set) var stickerLibraryStats: TrixStickerLibraryStats = .empty
    @Published private(set) var mediaCachePolicy: TrixMediaCachePolicy
    @Published private(set) var mediaCacheSnapshot: TrixMediaCacheSnapshot = .empty
    @Published private(set) var isUpdatingMediaCache = false
    @Published private(set) var mediaCacheMessage: String?
    @Published private(set) var roomNotificationProfiles: [String: TrixRoomNotificationProfile] = [:]
    @Published private(set) var isUpdatingRoomNotificationProfile = false
    @Published private(set) var roomNotificationProfileMessage: String?
    @Published private var selectedRoomSnapshot: TrixRoomSummary?

    let roomListViewModel: RoomListViewModel
    let timelineViewModel: TimelineViewModel
    let deviceVerificationViewModel: DeviceVerificationViewModel
    let callViewModel: TrixCallViewModel

    private let sessionStore: TrixSessionStore
    private let registrationService: TrixRegistrationService
    private let stickerImportService: TrixStickerImportService
    private let stickerLibraryStore: TrixStickerLibraryStore
    private let mediaCacheStore: TrixMediaCacheStore
    private let mediaCacheSettingsStore: TrixMediaCacheSettingsStore
    private let roomNotificationProfileStore: TrixRoomNotificationProfileStore
    private let trixService: TrixService
    private var stickerAssetDataByID: [String: Data] = [:]
    private var apnsDeviceToken: TrixAPNsDeviceToken?
    private var voipDeviceToken: TrixVoIPDeviceToken?
    private var roomNotificationProfileSnapshot = TrixRoomNotificationProfileSnapshot.empty
    private var hasStarted = false
    private let foregroundRefreshInterval: Duration = .seconds(10)

    init(
        sessionStore: TrixSessionStore = KeychainTrixSessionStore(),
        registrationService: TrixRegistrationService = HTTPInviteRegistrationService(),
        stickerImportService: TrixStickerImportService = HTTPStickerImportService(),
        stickerLibraryStore: TrixStickerLibraryStore = TrixStickerLibraryStore(),
        mediaCacheStore: TrixMediaCacheStore = TrixMediaCacheStore(),
        mediaCacheSettingsStore: TrixMediaCacheSettingsStore = UserDefaultsTrixMediaCacheSettingsStore(),
        roomNotificationProfileStore: TrixRoomNotificationProfileStore = TrixRoomNotificationProfileStore(),
        trixService: TrixService = XMPPMartinService()
    ) {
        self.sessionStore = sessionStore
        self.registrationService = registrationService
        self.stickerImportService = stickerImportService
        self.stickerLibraryStore = stickerLibraryStore
        self.mediaCacheStore = mediaCacheStore
        self.mediaCacheSettingsStore = mediaCacheSettingsStore
        self.roomNotificationProfileStore = roomNotificationProfileStore
        self.trixService = trixService
        self.mediaCachePolicy = mediaCacheSettingsStore.loadPolicy()
        self.roomListViewModel = RoomListViewModel()
        self.timelineViewModel = TimelineViewModel()
        self.deviceVerificationViewModel = DeviceVerificationViewModel()
        self.callViewModel = TrixCallViewModel(callDescriptorService: trixService)
    }

    var isAuthenticated: Bool {
        session != nil
    }

    var selectedRoom: TrixRoomSummary? {
        guard let selectedRoomID else {
            return nil
        }

        if let room = roomListViewModel.rooms.first(where: { $0.id == selectedRoomID }) {
            return room
        }

        if selectedRoomSnapshot?.id == selectedRoomID {
            return selectedRoomSnapshot
        }

        return nil
    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isStarting = true
        startupStatus = .checkingSavedSession

        do {
            guard let restoredSession = try sessionStore.loadSession() else {
                isStarting = false
                startupStatus = .idle
                return
            }

            startupStatus = .openingXMPPSession(host: Self.startupHostDescription(from: restoredSession))
            let restoredAccount = try await trixService.restore(session: restoredSession)
            session = restoredSession
            account = restoredAccount
            startupStatus = .finishingRestore

            loadStickerLibrary(for: restoredSession.userID)
            refreshLocalMediaState(for: restoredSession.userID)
            loadRoomNotificationProfiles(for: restoredSession.userID)
            await loadCachedRoomsForCurrentSession()
            isStarting = false

            Task { [weak self] in
                await self?.finishSessionRestoreInBackground()
            }
        } catch {
            startupStatus = .restoreFailed
            isStarting = false
            clearAuthenticatedState()
            try? sessionStore.clearSession()
            errorMessage = error.trixUserFacingMessage
        }
    }

    private static func startupHostDescription(from session: TrixSession) -> String {
        session.homeserverURL.host ?? XMPPClientConfiguration.connectionURL.host ?? "the configured XMPP server"
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
            refreshLocalMediaState(for: authenticatedSession.userID)
            loadRoomNotificationProfiles(for: authenticatedSession.userID)
            await reloadRooms()
            await reloadDeviceVerificationStatus()
            await syncRoomNotificationProfilesFromServerIfPossible(for: authenticatedSession)
            await syncAPNsRegistrationIfPossible()
            await syncVoIPPushRegistrationIfPossible()
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
            refreshLocalMediaState(for: authenticatedSession.userID)
            loadRoomNotificationProfiles(for: authenticatedSession.userID)

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
            await syncRoomNotificationProfilesFromServerIfPossible(for: authenticatedSession)
            await syncAPNsRegistrationIfPossible()
            await syncVoIPPushRegistrationIfPossible()
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
            await unregisterVoIPPushRegistrationIfPossible(session: session)
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

    func registerVoIPDeviceToken(_ token: TrixVoIPDeviceToken) async {
        voipDeviceToken = token
        await syncVoIPPushRegistrationIfPossible()
    }

    func invalidateVoIPDeviceToken() async {
        guard let token = voipDeviceToken else {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        voipDeviceToken = nil
        guard let session else {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        try? await trixService.unregisterVoIPToken(
            token,
            registration: voipPushRegistration,
            session: session
        )
        voipPushRegistration = nil
        voipPushRegistrationBlocker = .waitingForAPNsToken
    }

    func setApplicationIsActive(_ isActive: Bool) async {
        TrixAPNsCoordinator.shared.setApplicationIsActive(isActive)

        guard let session else {
            return
        }

        await trixService.setApplicationActive(isActive, session: session)
    }

    func roomNotificationProfile(for roomID: String) -> TrixRoomNotificationProfile {
        roomNotificationProfileSnapshot.profile(for: roomID)
    }

    func setRoomNotificationProfile(
        _ profile: TrixRoomNotificationProfile,
        for roomID: String
    ) async {
        guard let session else {
            return
        }

        isUpdatingRoomNotificationProfile = true
        roomNotificationProfileMessage = nil
        defer { isUpdatingRoomNotificationProfile = false }

        let updatedSnapshot = roomNotificationProfileSnapshot.setting(profile, for: roomID)
        do {
            try roomNotificationProfileStore.save(updatedSnapshot, accountID: session.userID)
        } catch {
            roomNotificationProfileMessage = error.trixUserFacingMessage
            return
        }

        applyRoomNotificationProfileSnapshot(updatedSnapshot)
        do {
            try await trixService.updateRoomNotificationProfiles(updatedSnapshot, session: session)
        } catch {
            roomNotificationProfileMessage = "Notification preferences were saved locally. Server sync failed."
        }
    }

    func dismissRoomNotificationProfileMessage() {
        roomNotificationProfileMessage = nil
    }

    func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        applicationIsActive: Bool
    ) async -> TrixRemoteNotificationHandlingResult {
        let payload = TrixRemoteNotificationPayload(userInfo: userInfo)
        guard payload.isSyncNotification,
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
            markSelectedRoomRead: false,
            reloadSelectedTimeline: applicationIsActive
        )

        let badgeCount = max(payload.badge ?? 0, totalUnreadCount)
        let shouldScheduleLocalNotification = !applicationIsActive &&
            !payload.presentsRemoteNotification
        let localNotification = shouldScheduleLocalNotification
            ? await localNotificationRequest(
                previousRooms: previousRooms,
                currentRooms: roomListViewModel.rooms,
                payload: payload,
                session: session,
                badgeCount: badgeCount
            )
            : nil

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
            selectedRoomID: nil
        )
        await applyReadMarkerStatesForLoadedRooms(session: session)
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
        reconcileSelectedRoom()
        await refreshCallStateForRooms(reportingErrors: false)

        if let selectedRoomID {
            await loadTimeline(roomID: selectedRoomID)
        }
    }

    private func loadCachedRoomsForCurrentSession() async {
        guard let session else {
            return
        }

        await roomListViewModel.loadCached(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID
        )
        refreshSelectedRoomSnapshot()
        reconcileSelectedRoom()
    }

    private func finishSessionRestoreInBackground() async {
        await reloadRooms()
        await reloadDeviceVerificationStatus()
        if let session {
            await syncRoomNotificationProfilesFromServerIfPossible(for: session)
        }
        await syncAPNsRegistrationIfPossible()
        await syncVoIPPushRegistrationIfPossible()
    }

    func refreshForeground(
        markSelectedRoomRead: Bool = false,
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
        await applyReadMarkerStatesForLoadedRooms(session: session)
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
        reconcileSelectedRoom()
        await refreshCallStateForRooms(reportingErrors: false)

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

        await refreshForeground()

        while !Task.isCancelled && isAuthenticated {
            try? await Task.sleep(for: foregroundRefreshInterval)
            guard !Task.isCancelled else {
                return
            }

            await refreshForeground()
        }
    }

    func selectRoom(_ room: TrixRoomSummary) async {
        prepareRoomSelection(room)
        await refreshMentionCandidates(for: room)
        await loadTimeline(roomID: room.id)
        roomListViewModel.markRead(roomID: room.id)
        await markLatestVisibleItemDisplayed(roomID: room.id)
    }

    func prepareRoomSelection(_ room: TrixRoomSummary) {
        selectedRoomSnapshot = room
        timelineViewModel.prepareForRoomSwitch(roomID: room.id)
        selectedRoomID = room.id
    }

    func loadTimeline(roomID: String) async {
        guard let session else {
            timelineViewModel.clear()
            return
        }
        guard selectedRoomID == roomID else {
            return
        }

        await timelineViewModel.load(roomID: roomID, session: session, service: trixService)
    }

    @discardableResult
    func send(
        text: String,
        metadata: TrixTextMessageSendMetadata? = nil
    ) async -> Bool {
        guard let session, let selectedRoomID else {
            return false
        }

        if let room = selectedRoom {
            await refreshMentionCandidates(for: room)
        }

        let roomID = selectedRoomID
        let sentItem = await timelineViewModel.send(
            text: text,
            roomID: roomID,
            session: session,
            service: trixService,
            metadata: metadata
        )
        guard sentItem != nil else {
            return false
        }

        try? await trixService.sendTypingState(.paused, roomID: roomID, session: session)
        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID,
            showsLoading: false
        )
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
        return true
    }

    @discardableResult
    func editTextMessage(
        messageID: String,
        newText: String
    ) async -> Bool {
        guard let session, let selectedRoomID else {
            return false
        }

        let didEdit = await timelineViewModel.editText(
            messageID: messageID,
            newText: newText,
            roomID: selectedRoomID,
            session: session,
            service: trixService
        )
        guard didEdit else {
            return false
        }

        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID,
            showsLoading: false
        )
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
        return true
    }

    @discardableResult
    func retractMessage(_ item: TrixTimelineItem) async -> Bool {
        guard let session, let selectedRoomID else {
            return false
        }

        let didRetract = await timelineViewModel.retractMessage(
            messageID: item.id,
            roomID: selectedRoomID,
            session: session,
            service: trixService
        )
        guard didRetract else {
            return false
        }

        await roomListViewModel.reload(
            session: session,
            service: trixService,
            selectedRoomID: selectedRoomID,
            showsLoading: false
        )
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
        return true
    }

    func markRoomDisplayed(roomID: String, messageID: String) async {
        guard let session else {
            return
        }

        let marker = await timelineViewModel.markRoomDisplayed(
            roomID: roomID,
            messageID: messageID,
            session: session,
            service: trixService
        )
        if let marker {
            roomListViewModel.applyReadMarker(marker)
            refreshSelectedRoomSnapshot()
        }
    }

    func markSelectedRoomDisplayed() async {
        guard let selectedRoomID else {
            return
        }

        await markLatestVisibleItemDisplayed(roomID: selectedRoomID)
    }

    func beginReply(to item: TrixTimelineItem) {
        timelineViewModel.beginReply(to: item)
    }

    func cancelReply() {
        timelineViewModel.clearReplyTarget()
    }

    func beginThread(from item: TrixTimelineItem) {
        timelineViewModel.beginThread(from: item)
    }

    func continueThread(_ thread: TrixThreadReference) {
        timelineViewModel.continueThread(thread)
    }

    func cancelThread() {
        timelineViewModel.clearThreadTarget()
    }

    @discardableResult
    func beginEditing(_ item: TrixTimelineItem) -> Bool {
        guard let session else {
            return false
        }

        return timelineViewModel.beginEditing(item, currentUserID: session.userID)
    }

    func cancelEditing() {
        timelineViewModel.cancelEditing()
    }

    func refreshMentionCandidates(for room: TrixRoomSummary) async {
        guard let session else {
            timelineViewModel.setMentionCandidates([], for: room.id)
            return
        }

        let candidates: [TrixMentionCandidate]
        if room.kind == .direct {
            candidates = Self.mentionCandidates(
                from: [
                    TrixRoomMember(
                        userID: room.id,
                        displayName: room.name,
                        membership: .joined
                    ),
                ],
                currentUserID: session.userID
            )
        } else {
            let members = (try? await trixService.members(roomID: room.id, session: session)) ?? []
            candidates = Self.mentionCandidates(from: members, currentUserID: session.userID)
        }

        timelineViewModel.setMentionCandidates(candidates, for: room.id)
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
            selectedRoomID: selectedRoomID,
            showsLoading: false
        )
        lastRoomRefreshAt = Date()
        refreshSelectedRoomSnapshot()
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

    func dismissStickerImportMessage() {
        stickerImportMessage = nil
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
            refreshStickerStats(for: session.userID)
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

        if let snapshot = await timelineViewModel.downloadAttachment(
            for: item,
            session: session,
            service: trixService,
            mediaCacheStore: mediaCacheStore,
            mediaCachePolicy: mediaCachePolicy
        ) {
            mediaCacheSnapshot = snapshot
        }
    }

    func loadInlineAttachmentPreview(for item: TrixTimelineItem) async {
        guard let session else {
            return
        }

        if let snapshot = await timelineViewModel.loadInlineAttachmentPreview(
            for: item,
            session: session,
            service: trixService,
            mediaCacheStore: mediaCacheStore,
            mediaCachePolicy: mediaCachePolicy
        ) {
            mediaCacheSnapshot = snapshot
        }
    }

    func dismissMediaCacheMessage() {
        mediaCacheMessage = nil
    }

    func updateMediaCachePolicy(_ policy: TrixMediaCachePolicy) async {
        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            let sanitizedPolicy = policy.sanitized
            try mediaCacheSettingsStore.savePolicy(sanitizedPolicy)
            mediaCachePolicy = sanitizedPolicy

            if let session {
                mediaCacheSnapshot = try mediaCacheStore.applyRetention(
                    accountID: session.userID,
                    policy: sanitizedPolicy
                )
            }
            mediaCacheMessage = "Media cache policy updated."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
    }

    func clearMediaCache() async {
        guard let session else {
            return
        }

        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            mediaCacheSnapshot = try mediaCacheStore.clearAll(accountID: session.userID)
            timelineViewModel.clearAttachmentDownloads()
            mediaCacheMessage = "Media cache cleared."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
    }

    func clearSelectedRoomMediaCache() async {
        guard let session, let selectedRoomID else {
            return
        }

        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            mediaCacheSnapshot = try mediaCacheStore.clearRoom(
                accountID: session.userID,
                roomID: selectedRoomID
            )
            timelineViewModel.clearAttachmentDownloads()
            mediaCacheMessage = "Current chat media cache cleared."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
    }

    func clearMediaCacheOlderThan(days: Int) async {
        guard let session else {
            return
        }

        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 24 * 60 * 60)
            mediaCacheSnapshot = try mediaCacheStore.clearOlderThan(
                accountID: session.userID,
                cutoff: cutoff
            )
            timelineViewModel.clearAttachmentDownloads()
            mediaCacheMessage = "Older media cache entries cleared."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
    }

    func deleteStickerPack(_ pack: TrixStickerPack) async {
        guard let session else {
            return
        }

        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            let state = try stickerLibraryStore.deletePack(id: pack.id, accountID: session.userID)
            stickerPacks = state.packs
            stickerAssetDataByID = state.dataByStickerID
            refreshStickerStats(for: session.userID)
            mediaCacheMessage = "Sticker pack removed."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
    }

    func clearStickerLibrary() async {
        guard let session else {
            return
        }

        isUpdatingMediaCache = true
        mediaCacheMessage = nil
        defer { isUpdatingMediaCache = false }

        do {
            try stickerLibraryStore.clear(accountID: session.userID)
            stickerPacks = []
            stickerAssetDataByID = [:]
            stickerLibraryStats = .empty
            mediaCacheMessage = "Sticker library cleared."
        } catch {
            mediaCacheMessage = error.trixUserFacingMessage
        }
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

    func loadCallState(for room: TrixRoomSummary) async {
        guard let session else {
            callViewModel.clear()
            return
        }

        await callViewModel.loadRoomCallState(room: room, session: session)
    }

    func refreshCallStateForRooms(reportingErrors: Bool = false) async {
        guard let session else {
            callViewModel.clear()
            return
        }

        for room in roomListViewModel.rooms {
            await callViewModel.loadRoomCallState(
                room: room,
                session: session,
                reportsErrors: reportingErrors
            )
        }
    }

    func startDirectVideoCall(in room: TrixRoomSummary) async {
        guard let session, room.kind == .direct else {
            return
        }

        let peerUserID = await directCallPeerUserID(for: room, session: session)
        await callViewModel.startDirectVideoCall(
            peerUserID: peerUserID,
            roomID: room.id,
            session: session
        )
    }

    @discardableResult
    func acceptIncomingDirectCall(_ call: TrixIncomingDirectCall) async -> Bool {
        guard let session else {
            return false
        }

        return await callViewModel.acceptIncomingDirectCall(call, session: session)
    }

    @discardableResult
    func declineIncomingDirectCall(_ call: TrixIncomingDirectCall) async -> Bool {
        guard let session else {
            return false
        }

        return await callViewModel.declineIncomingDirectCall(call, session: session)
    }

    func joinGroupVoiceRoom(in room: TrixRoomSummary) async {
        guard let session, room.kind == .group else {
            return
        }

        await callViewModel.joinGroupVoiceRoom(roomID: room.id, session: session)
    }

    func leaveCall(in room: TrixRoomSummary) async {
        _ = await callViewModel.endCall(roomID: room.id, session: session)
    }

    @discardableResult
    func acceptIncomingCallKitCall(callID: String) async -> Bool {
        guard let session else {
            return false
        }

        await refreshCallStateForRooms()
        return await callViewModel.acceptIncomingDirectCall(callID: callID, session: session)
    }

    @discardableResult
    func endCallKitCall(callID: String) async -> Bool {
        guard let session else {
            return false
        }

        await refreshCallStateForRooms()

        if let incomingCall = callViewModel.incomingDirectCall(callID: callID) {
            return await callViewModel.declineIncomingDirectCall(incomingCall, session: session)
        }

        if callViewModel.activeCall?.callID == callID,
           let activeRoomID = callViewModel.activeRoomID {
            return await callViewModel.endCall(roomID: activeRoomID, session: session)
        }

        return false
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
        prepareRoomSelection(room)
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
        prepareRoomSelection(room)
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

        prepareRoomSelection(room)
        await reloadRooms()
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
            selectedRoomSnapshot = roomListViewModel.rooms.first
            timelineViewModel.clear()
        }
    }

    private func markLatestVisibleItemDisplayed(roomID: String) async {
        guard let session else {
            return
        }

        let marker = await timelineViewModel.markLatestVisibleItemDisplayed(
            roomID: roomID,
            session: session,
            service: trixService
        )
        roomListViewModel.markRead(roomID: roomID)
        if let marker {
            roomListViewModel.applyReadMarker(marker)
        }
        refreshSelectedRoomSnapshot()
    }

    private func applyReadMarkerStatesForLoadedRooms(session: TrixSession) async {
        var markers: [TrixRoomReadMarkerState] = []
        for room in roomListViewModel.rooms {
            if let marker = try? await trixService.readMarkerState(roomID: room.id, session: session) {
                markers.append(marker)
            }
        }

        guard !markers.isEmpty else {
            return
        }

        roomListViewModel.applyReadMarkers(markers)
    }

    private static func mentionCandidates(
        from members: [TrixRoomMember],
        currentUserID: String
    ) -> [TrixMentionCandidate] {
        let currentUserKey = normalizedUserKey(currentUserID)
        return members
            .filter { member in
                member.membership.isActive &&
                    normalizedUserKey(member.userID) != currentUserKey
            }
            .map { member in
                TrixMentionCandidate(userID: member.userID, displayName: member.title)
            }
    }

    private func reconcileSelectedRoom() {
        if let selectedRoomID,
           let room = roomListViewModel.rooms.first(where: { $0.id == selectedRoomID }) {
            selectedRoomSnapshot = room
            return
        }

        if let selectedRoomID,
           selectedRoomSnapshot?.id == selectedRoomID {
            return
        }

        selectedRoomID = roomListViewModel.rooms.first?.id
        selectedRoomSnapshot = roomListViewModel.rooms.first
    }

    private func refreshSelectedRoomSnapshot() {
        guard let selectedRoomID else {
            selectedRoomSnapshot = nil
            return
        }

        if let room = roomListViewModel.rooms.first(where: { $0.id == selectedRoomID }) {
            selectedRoomSnapshot = room
        }
    }

    private var totalUnreadCount: Int {
        roomListViewModel.rooms.reduce(0) { partialResult, room in
            partialResult + max(room.unreadCount, 0)
        }
    }

    private func localNotificationRequest(
        previousRooms: [TrixRoomSummary],
        currentRooms: [TrixRoomSummary],
        payload: TrixRemoteNotificationPayload,
        session: TrixSession,
        badgeCount: Int
    ) async -> TrixLocalNotificationRequest? {
        let candidateRooms = TrixRoomNotificationPlanner.candidateRooms(
            previousRooms: previousRooms,
            currentRooms: currentRooms,
            payload: payload
        )
        guard !candidateRooms.isEmpty else {
            return nil
        }

        let previousActivityByRoomID = Dictionary(
            previousRooms.map { (TrixRoomNotificationProfileSnapshot.normalizedRoomID($0.id), $0.lastActivityAt) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var candidates: [TrixRoomNotificationCandidate] = []
        for room in candidateRooms {
            let profile = roomNotificationProfile(for: room.id)
            let previousActivityAt = previousActivityByRoomID[
                TrixRoomNotificationProfileSnapshot.normalizedRoomID(room.id)
            ]
            let hasMention: Bool
            if profile == .mentionsOnly {
                let items = (try? await trixService.cachedTimeline(roomID: room.id, session: session)) ?? []
                hasMention = TrixRoomNotificationPlanner.timelineContainsMention(
                    items,
                    accountID: session.userID,
                    newerThan: previousActivityAt
                )
            } else {
                hasMention = false
            }
            candidates.append(
                TrixRoomNotificationCandidate(
                    room: room,
                    profile: profile,
                    hasMention: hasMention
                )
            )
        }

        return TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: candidates,
            payload: payload,
            badgeCount: badgeCount
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

    private func syncVoIPPushRegistrationIfPossible() async {
        guard let voipDeviceToken else {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        guard let session else {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .waitingForSession
            return
        }

        do {
            voipPushRegistration = try await trixService.registerVoIPToken(voipDeviceToken, session: session)
            voipPushRegistrationBlocker = nil
        } catch TrixClientError.apnsGatewayUnavailable {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .pushGatewayUnavailable
        } catch {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .registrationFailed
        }
    }

    private func unregisterVoIPPushRegistrationIfPossible(session: TrixSession) async {
        guard let voipDeviceToken else {
            voipPushRegistration = nil
            voipPushRegistrationBlocker = .waitingForAPNsToken
            return
        }

        try? await trixService.unregisterVoIPToken(
            voipDeviceToken,
            registration: voipPushRegistration,
            session: session
        )
        voipPushRegistration = nil
        voipPushRegistrationBlocker = .waitingForSession
    }

    private func loadRoomNotificationProfiles(for accountID: String) {
        do {
            applyRoomNotificationProfileSnapshot(
                try roomNotificationProfileStore.load(accountID: accountID)
            )
            roomNotificationProfileMessage = nil
        } catch {
            applyRoomNotificationProfileSnapshot(.empty)
            roomNotificationProfileMessage = error.trixUserFacingMessage
        }
    }

    private func syncRoomNotificationProfilesFromServerIfPossible(for session: TrixSession) async {
        do {
            let localSnapshot = roomNotificationProfileSnapshot
            guard let remoteSnapshot = try await trixService.roomNotificationProfiles(session: session) else {
                if !localSnapshot.isEmpty {
                    try await trixService.updateRoomNotificationProfiles(localSnapshot, session: session)
                }
                return
            }

            if remoteSnapshot.updatedAt > localSnapshot.updatedAt {
                try roomNotificationProfileStore.save(remoteSnapshot, accountID: session.userID)
                applyRoomNotificationProfileSnapshot(remoteSnapshot)
            } else if localSnapshot.updatedAt > remoteSnapshot.updatedAt {
                try await trixService.updateRoomNotificationProfiles(localSnapshot, session: session)
            }
        } catch {
            roomNotificationProfileMessage = "Notification preferences are available locally. Server sync failed."
        }
    }

    private func directCallPeerUserID(for room: TrixRoomSummary, session: TrixSession) async -> String {
        guard room.kind == .direct else {
            return room.id
        }

        guard let members = try? await trixService.members(roomID: room.id, session: session),
              let peer = members.first(where: { member in
                  member.membership.isActive &&
                      Self.normalizedUserKey(member.userID) != Self.normalizedUserKey(session.userID)
              }) else {
            return room.id
        }

        return peer.userID
    }

    private static func normalizedUserKey(_ userID: String) -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":") else {
            return trimmed
        }

        let localpart = trimmed[trimmed.index(after: trimmed.startIndex)..<separator]
        let server = trimmed[trimmed.index(after: separator)...]
        guard !localpart.isEmpty, !server.isEmpty else {
            return trimmed
        }

        return "\(localpart)@\(server)"
    }

    private func applyRoomNotificationProfileSnapshot(_ snapshot: TrixRoomNotificationProfileSnapshot) {
        roomNotificationProfileSnapshot = snapshot
        roomNotificationProfiles = snapshot.profilesByRoomID
    }

    private func loadStickerLibrary(for accountID: String) {
        do {
            let state = try stickerLibraryStore.load(accountID: accountID)
            stickerPacks = state.packs
            stickerAssetDataByID = state.dataByStickerID
            refreshStickerStats(for: accountID)
            stickerImportMessage = nil
        } catch {
            stickerPacks = []
            stickerAssetDataByID = [:]
            stickerLibraryStats = .empty
            stickerImportMessage = error.trixUserFacingMessage
        }
    }

    private func refreshLocalMediaState(for accountID: String) {
        do {
            mediaCacheSnapshot = try mediaCacheStore.applyRetention(
                accountID: accountID,
                policy: mediaCachePolicy
            )
        } catch {
            mediaCacheSnapshot = .empty
            mediaCacheMessage = error.trixUserFacingMessage
        }

        refreshStickerStats(for: accountID)
    }

    private func refreshStickerStats(for accountID: String) {
        stickerLibraryStats = (try? stickerLibraryStore.stats(accountID: accountID)) ?? .empty
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
        selectedRoomSnapshot = nil
        pushRegistration = nil
        pushRegistrationBlocker = apnsDeviceToken == nil ? .waitingForAPNsToken : .waitingForSession
        voipPushRegistration = nil
        voipPushRegistrationBlocker = voipDeviceToken == nil ? .waitingForAPNsToken : .waitingForSession
        lastRoomRefreshAt = nil
        stickerPacks = []
        stickerAssetDataByID = [:]
        stickerImportMessage = nil
        isImportingStickerPack = false
        stickerLibraryStats = .empty
        mediaCacheSnapshot = .empty
        mediaCacheMessage = nil
        isUpdatingMediaCache = false
        roomNotificationProfileSnapshot = .empty
        roomNotificationProfiles = [:]
        roomNotificationProfileMessage = nil
        isUpdatingRoomNotificationProfile = false
        roomListViewModel.clear()
        timelineViewModel.clear()
        deviceVerificationViewModel.clear()
        callViewModel.clear()
    }
}

extension TrixAppModel {
    static func makeDefault() -> TrixAppModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TRIX_USE_MOCK_SERVICE"] == "1" {
            return TrixAppModel(
                sessionStore: TrixMockSessionStore(),
                registrationService: MockInviteRegistrationService(),
                stickerImportService: MockStickerImportService(),
                trixService: MockTrixService()
            )
        }
        if let localProfile = TrixLocalProfileConfiguration.current() {
            return TrixAppModel(
                sessionStore: KeychainTrixSessionStore(
                    service: localProfile.keychainService("com.softgrid.trix.session"),
                    account: "trix-session"
                ),
                stickerLibraryStore: TrixStickerLibraryStore(
                    keychainService: localProfile.keychainService("com.softgrid.trix.xmpp.sticker-library-key"),
                    directoryName: localProfile.directoryName("StickerLibrary")
                ),
                mediaCacheStore: TrixMediaCacheStore(
                    keychainService: localProfile.keychainService("com.softgrid.trix.xmpp.media-cache-key"),
                    directoryName: localProfile.directoryName("MediaCache")
                ),
                mediaCacheSettingsStore: UserDefaultsTrixMediaCacheSettingsStore(
                    userDefaults: localProfile.userDefaults(suiteName: "com.softgrid.trix.media-cache-settings")
                ),
                roomNotificationProfileStore: TrixRoomNotificationProfileStore(
                    keychainService: localProfile.keychainService("com.softgrid.trix.xmpp.room-notification-profile-key"),
                    directoryName: localProfile.directoryName("RoomNotificationProfiles")
                ),
                trixService: XMPPMartinService(localProfile: localProfile)
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
