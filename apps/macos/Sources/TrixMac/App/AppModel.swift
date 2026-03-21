import AppKit
import Foundation
import UniformTypeIdentifiers

struct PreviewedAttachmentFile: Identifiable {
    let fileURL: URL
    let fileName: String
    let mimeType: String?

    var id: String { fileURL.absoluteString }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var serverBaseURLString: String
    @Published var draft: OnboardingDraft
    @Published var linkDraft: LinkDeviceDraft
    @Published var onboardingMode: OnboardingMode = .createAccount
    @Published var health: HealthResponse?
    @Published var version: VersionResponse?
    @Published var currentAccount: AccountProfileResponse?
    @Published var devices: [DeviceSummary] = []
    @Published var chats: [ChatSummary] = []
    @Published var inboxItems: [InboxItem] = []
    @Published var inboxLeaseDraft = InboxLeaseDraft()
    @Published var activeInboxLease: InboxLeaseState?
    @Published var lastInboxCursor: UInt64?
    @Published var lastAckedInboxIDs: [UInt64] = []
    @Published var syncStateSnapshot: SyncStateSnapshot?
    @Published var historySyncJobs: [HistorySyncJobSummary] = []
    @Published var historySyncCursorDrafts: [UUID: String] = [:]
    @Published var keyPackagePublishDraft = KeyPackagePublishDraft()
    @Published var keyPackageReserveDraft = KeyPackageReserveDraft()
    @Published var createChatDraft = CreateChatDraft()
    @Published var editProfileDraft = EditProfileDraft()
    @Published var accountDirectoryResults: [DirectoryAccountSummary] = []
    @Published var publishedKeyPackages: [PublishedKeyPackage] = []
    @Published var reservedKeyPackages: [ReservedKeyPackage] = []
    @Published var reservedKeyPackagesAccountID: UUID?
    @Published var selectedChatID: UUID?
    @Published var localChatListItems: [LocalChatListItem] = []
    @Published var pendingOutgoingMessages: [PendingOutgoingMessage] = []
    @Published var composerAttachmentDraft: AttachmentDraft?
    @Published var selectedChatDetail: ChatDetailResponse?
    @Published var selectedChatReadState: LocalChatReadState?
    @Published var selectedChatTimelineItems: [LocalTimelineItem] = []
    @Published var selectedChatProjectedCursor: UInt64?
    @Published var selectedChatProjectedMessages: [LocalProjectedMessage] = []
    @Published var selectedChatHistory: [MessageEnvelope] = []
    @Published var cachedAttachmentURLs: [UUID: URL] = [:]
    @Published var previewedAttachment: PreviewedAttachmentFile?
    @Published var outgoingLinkIntent: DeviceLinkIntentState?
    @Published var notificationPreferences: NotificationPreferences
    @Published var hasAccountRootKey = false
    @Published var isRefreshingStatus = false
    @Published var isCreatingAccount = false
    @Published var isCreatingLinkIntent = false
    @Published var isCompletingLink = false
    @Published var isPublishingKeyPackages = false
    @Published var isReservingKeyPackages = false
    @Published var isRestoringSession = false
    @Published var isRefreshingWorkspace = false
    @Published var isCreatingChat = false
    @Published var isSearchingAccountDirectory = false
    @Published var isUpdatingProfile = false
    @Published var isSendingMessage = false
    @Published var isRefreshingInbox = false
    @Published var isLeasingInbox = false
    @Published var isAckingInbox = false
    @Published var isRefreshingHistorySyncJobs = false
    @Published var isLoadingSelectedChat = false
    @Published var revokingDeviceIDs: Set<UUID> = []
    @Published var approvingDeviceIDs: Set<UUID> = []
    @Published var completingHistorySyncJobIDs: Set<UUID> = []
    @Published var downloadingAttachmentMessageIDs: Set<UUID> = []
    @Published var removingChatMemberAccountIDs: Set<UUID> = []
    @Published var removingChatDeviceIDs: Set<UUID> = []
    @Published var isAddingChatMembers = false
    @Published var isAddingChatDevices = false
    @Published var lastErrorMessage: String?

    private let sessionStore: SessionStore
    private let keychainStore: KeychainStore
    private let notificationPreferencesStore: NotificationPreferencesStore
    private let notificationCoordinator: LocalNotificationCoordinator
    private let defaultDeviceName: String
    private var persistedSession: PersistedSession?
    private var accessToken: String?
    private var didStart = false
    private var backgroundRefreshTask: Task<Void, Never>?
    private var realtimeClient: RealtimeWebSocketClient?
    private var realtimeConnectionID = UUID()
    private var realtimeAccessToken: String?
    private var realtimeBaseURLString: String?
    private var hasScheduledRealtimeRecovery = false
    private var isApplicationActive = true

    init(
        sessionStore: SessionStore = SessionStore(),
        keychainStore: KeychainStore = KeychainStore(),
        notificationPreferencesStore: NotificationPreferencesStore = NotificationPreferencesStore(),
        notificationCoordinator: LocalNotificationCoordinator = LocalNotificationCoordinator.makeDefault()
    ) {
        self.sessionStore = sessionStore
        self.keychainStore = keychainStore
        self.notificationPreferencesStore = notificationPreferencesStore
        self.notificationCoordinator = notificationCoordinator

        let defaultDeviceName = Host.current().localizedName ?? "This Mac"
        self.defaultDeviceName = defaultDeviceName
        self.serverBaseURLString = "http://127.0.0.1:8080"
        self.draft = OnboardingDraft(deviceDisplayName: defaultDeviceName)
        self.linkDraft = LinkDeviceDraft(deviceDisplayName: defaultDeviceName)
        self.notificationPreferences = notificationPreferencesStore.load()
        if !notificationCoordinator.isAvailable {
            self.notificationPreferences.permissionState = .denied
            self.notificationPreferences.isEnabled = false
        }
    }

    deinit {
        backgroundRefreshTask?.cancel()
    }

    var isAuthenticated: Bool {
        currentAccount != nil && accessToken != nil
    }

    var hasPersistedSession: Bool {
        persistedSession != nil
    }

    var isAwaitingLinkApproval: Bool {
        !isAuthenticated && persistedSession?.deviceStatus == .pending
    }

    var showsWorkspace: Bool {
        isAuthenticated || (persistedSession?.deviceStatus == .active && hasPersistedSession)
    }

    var canCreateAccount: Bool {
        draft.profileName.nonEmptyTrimmed != nil &&
            draft.deviceDisplayName.nonEmptyTrimmed != nil &&
            ServerEndpoint.normalizedURL(from: serverBaseURLString) != nil
    }

    var canCompleteLink: Bool {
        linkDraft.linkPayload.nonEmptyTrimmed != nil &&
            linkDraft.deviceDisplayName.nonEmptyTrimmed != nil
    }

    var canPublishKeyPackages: Bool {
        keyPackagePublishDraft.packagesJSON.nonEmptyTrimmed != nil && !isPublishingKeyPackages
    }

    var canCreateChat: Bool {
        guard !isCreatingChat else {
            return false
        }

        switch createChatDraft.chatType {
        case .dm:
            return createChatParticipantAccountIDs.count == 1
        case .group:
            return !createChatParticipantAccountIDs.isEmpty
        case .accountSync:
            return false
        }
    }

    var canUpdateProfile: Bool {
        editProfileDraft.profileName.nonEmptyTrimmed != nil && !isUpdatingProfile
    }

    var canReserveKeyPackages: Bool {
        guard keyPackageReserveDraft.accountID.nonEmptyTrimmed != nil else {
            return false
        }

        if keyPackageReserveDraft.mode == .selectedDevices {
            return keyPackageReserveDraft.selectedDeviceIDs.nonEmptyTrimmed != nil && !isReservingKeyPackages
        }

        return !isReservingKeyPackages
    }

    var canAckLoadedInboxItems: Bool {
        !inboxItems.isEmpty && !isAckingInbox
    }

    var currentDeviceID: UUID? {
        currentAccount?.deviceId ?? persistedSession?.deviceId
    }

    var pendingLinkedDeviceID: UUID? {
        isAwaitingLinkApproval ? persistedSession?.deviceId : nil
    }

    var selectedChatSummary: ChatSummary? {
        guard let selectedChatID else {
            return nil
        }

        return chats.first { $0.chatId == selectedChatID }
    }

    var visibleLocalChatListItems: [LocalChatListItem] {
        localChatListItems.filter { $0.chatType != .accountSync }
    }

    var selectedChatListItem: LocalChatListItem? {
        guard let selectedChatID else {
            return nil
        }

        return localChatListItems.first { $0.chatId == selectedChatID }
    }

    var addableCurrentAccountDevicesForSelectedChat: [DeviceSummary] {
        guard let detail = selectedChatDetail,
              let accountId = currentAccount?.accountId ?? persistedSession?.accountId else {
            return []
        }

        let existingDeviceIDs = Set(detail.deviceMembers.map(\.deviceId))
        return devices.filter {
            $0.deviceStatus == .active &&
                !existingDeviceIDs.contains($0.deviceId) &&
                detail.members.contains(where: { $0.accountId == accountId })
        }
    }

    var hasProjectedTimelineData: Bool {
        !selectedChatProjectedMessages.isEmpty
    }

    var selectedPendingOutgoingMessages: [PendingOutgoingMessage] {
        guard let selectedChatID else {
            return []
        }

        return pendingOutgoingMessages.filter { $0.chatId == selectedChatID }
    }

    var chatPresentationAccountID: UUID? {
        currentAccount?.accountId ?? persistedSession?.accountId
    }

    var isCreateChatDirectoryEmpty: Bool {
        !isSearchingAccountDirectory && accountDirectoryResults.isEmpty
    }

    var createChatParticipantAccountIDs: [UUID] {
        var seen = Set<UUID>()
        return createChatDraft.selectedParticipants.compactMap { participant in
            guard seen.insert(participant.accountId).inserted else {
                return nil
            }

            return participant.accountId
        }
    }

    func start() async {
        guard !didStart else {
            return
        }
        didStart = true

        do {
            if let session = try sessionStore.load() {
                persistedSession = session
                serverBaseURLString = session.baseURLString
                draft.profileName = session.profileName
                draft.handle = session.handle ?? ""
                draft.deviceDisplayName = session.deviceDisplayName
                linkDraft.deviceDisplayName = session.deviceDisplayName
                onboardingMode = session.deviceStatus == .pending ? .linkExisting : .createAccount
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }

        refreshLocalIdentityState(reportErrors: true)
        await refreshServerStatus()
        await refreshNotificationPermissionState()
        startBackgroundRefreshLoopIfNeeded()

        if persistedSession != nil {
            await restoreSession()
        }
    }

    func refreshServerStatus() async {
        guard let client = makeClient() else {
            return
        }

        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        do {
            async let health = client.fetchHealth()
            async let version = client.fetchVersion()

            self.health = try await health
            self.version = try await version
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive

        if isActive {
            Task {
                await refreshNotificationPermissionState()
                if let accessToken,
                   let accountId = currentAccount?.accountId ?? persistedSession?.accountId {
                    await startRealtimeConnection(
                        accessToken: accessToken,
                        accountId: accountId
                    )
                } else {
                    await refreshInbox(background: false, suppressErrors: true)
                }
            }
        }
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        notificationPreferences.isEnabled = isEnabled
        notificationPreferencesStore.save(notificationPreferences)
    }

    func setNotificationPollingInterval(_ seconds: TimeInterval) {
        notificationPreferences.backgroundPollingIntervalSeconds = min(max(seconds, 15), 300)
        notificationPreferencesStore.save(notificationPreferences)
    }

    func refreshNotificationPermissionState() async {
        notificationPreferences.permissionState = await notificationCoordinator.permissionState()
        notificationPreferencesStore.save(notificationPreferences)
    }

    func requestNotificationPermission() async {
        do {
            notificationPreferences.permissionState = try await notificationCoordinator.requestAuthorization()
            if notificationPreferences.permissionState == .authorized ||
                notificationPreferences.permissionState == .provisional ||
                notificationPreferences.permissionState == .ephemeral {
                notificationPreferences.isEnabled = true
            }
            notificationPreferencesStore.save(notificationPreferences)
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func importComposerAttachment(from fileURL: URL) {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            lastErrorMessage = "Не удалось открыть выбранный файл."
            return
        }

        do {
            composerAttachmentDraft = try makeAttachmentDraft(from: fileURL)
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func clearComposerAttachment() {
        composerAttachmentDraft = nil
    }

    func cachedAttachmentURL(for messageId: UUID) -> URL? {
        guard let cachedURL = cachedAttachmentURLs[messageId] else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: cachedURL.path) else {
            cachedAttachmentURLs.removeValue(forKey: messageId)
            return nil
        }
        return cachedURL
    }

    func ensureCachedAttachmentURL(
        for message: LocalTimelineItem,
        reportErrors: Bool = false
    ) async -> URL? {
        guard let body = message.body, body.kind == .attachment else {
            return nil
        }
        if let cachedURL = cachedAttachmentURLs[message.messageId],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        guard let token = accessToken else {
            if reportErrors {
                await restoreSession()
            }
            return nil
        }
        guard let client = makeClient() else {
            return nil
        }

        do {
            let downloaded = try await client.downloadAttachment(accessToken: token, body: body)
            let destinationURL = try attachmentCacheURL(for: message.messageId, body: downloaded.body)
            try downloaded.plaintext.write(to: destinationURL, options: .atomic)
            cachedAttachmentURLs[message.messageId] = destinationURL
            return destinationURL
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                if reportErrors {
                    await restoreSession()
                }
            } else if reportErrors {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            if reportErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }

        return nil
    }

    func createAccount() async {
        guard let client = makeClient() else {
            return
        }

        guard let profileName = draft.profileName.nonEmptyTrimmed else {
            lastErrorMessage = "Укажи имя профиля."
            return
        }
        guard let deviceDisplayName = draft.deviceDisplayName.nonEmptyTrimmed else {
            lastErrorMessage = "Укажи имя устройства."
            return
        }

        isCreatingAccount = true
        lastErrorMessage = nil
        defer { isCreatingAccount = false }

        do {
            let handle = draft.handle.nonEmptyTrimmed
            let profileBio = draft.profileBio.nonEmptyTrimmed
            let identity = try DeviceIdentityMaterial.make(
                profileName: profileName,
                handle: handle,
                deviceDisplayName: deviceDisplayName,
                platform: DeviceIdentityMaterial.platform
            )
            let created = try await client.createAccount(
                handle: handle,
                profileName: profileName,
                profileBio: profileBio,
                deviceDisplayName: deviceDisplayName,
                identity: identity
            )
            let authSession = try await authenticate(
                client: client,
                deviceId: created.deviceId,
                identity: identity
            )

            let session = PersistedSession(
                baseURLString: serverBaseURLString,
                accountId: created.accountId,
                deviceId: created.deviceId,
                accountSyncChatId: created.accountSyncChatId,
                profileName: profileName,
                handle: handle,
                deviceDisplayName: deviceDisplayName,
                deviceStatus: .active
            )

            try save(identity: identity, authSession: authSession, persistedSession: session)
            try await loadWorkspace(client: client, accessToken: authSession.accessToken)
            await refreshServerStatus()
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func createLinkIntent() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isCreatingLinkIntent = true
        lastErrorMessage = nil
        defer { isCreatingLinkIntent = false }

        do {
            let response = try await client.createLinkIntent(accessToken: token)
            outgoingLinkIntent = DeviceLinkIntentState(
                payload: response.qrPayload,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAtUnix))
            )
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func completeLink() async {
        guard let deviceDisplayName = linkDraft.deviceDisplayName.nonEmptyTrimmed else {
            lastErrorMessage = "Укажи имя устройства для link flow."
            return
        }

        isCompletingLink = true
        lastErrorMessage = nil
        defer { isCompletingLink = false }

        do {
            let payload = try decodeLinkIntentPayload(linkDraft.linkPayload)
            guard let client = makeClient(baseURLString: payload.baseURL) else {
                return
            }

            let identity = try DeviceIdentityMaterial.makeLinkedDevice(
                deviceDisplayName: deviceDisplayName,
                platform: DeviceIdentityMaterial.platform
            )
            let storePaths = try workspaceStorePaths(for: payload.accountId)
            let response = try await client.completeLinkIntent(
                linkIntentId: payload.linkIntentId,
                linkToken: payload.linkToken,
                deviceDisplayName: deviceDisplayName,
                identity: identity,
                mlsStorageRoot: storePaths.mlsStateRootURL
            )

            serverBaseURLString = payload.baseURL
            draft.deviceDisplayName = deviceDisplayName

            let session = PersistedSession(
                baseURLString: payload.baseURL,
                accountId: response.accountId,
                deviceId: response.pendingDeviceId,
                accountSyncChatId: nil,
                profileName: "Linked Account",
                handle: nil,
                deviceDisplayName: deviceDisplayName,
                deviceStatus: response.deviceStatus
            )

            try save(identity: identity, authSession: nil, persistedSession: session)
            clearWorkspaceData()
            outgoingLinkIntent = nil
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func restoreSession() async {
        guard let session = persistedSession else {
            return
        }
        guard let client = makeClient(baseURLString: session.baseURLString) else {
            return
        }

        logInfo("auth", "restore_session start device=\(shortLogID(session.deviceId))")
        isRestoringSession = true
        lastErrorMessage = nil
        defer { isRestoringSession = false }

        do {
            let identity = try loadStoredIdentity()
            let authSession = try await authenticate(
                client: client,
                deviceId: session.deviceId,
                identity: identity
            )

            var updatedSession = session
            updatedSession.deviceStatus = authSession.deviceStatus

            try save(identity: identity, authSession: authSession, persistedSession: updatedSession)
            try await loadWorkspace(client: client, accessToken: authSession.accessToken)
            logInfo(
                "auth",
                "restore_session success device=\(shortLogID(session.deviceId)) status=\(authSession.deviceStatus.label.lowercased())"
            )
        } catch let error as TrixAPIError {
            logWarn("auth", "restore_session failed device=\(shortLogID(session.deviceId))", error: error)
            if error.isCredentialFailure {
                disconnectRealtimeConnection()
                if session.deviceStatus == .pending {
                    if error.suggestsPendingLinkReset {
                        restartPendingLinkFlow(
                            baseURLString: session.baseURLString,
                            deviceDisplayName: session.deviceDisplayName,
                            errorMessage: "This linked-device session is no longer valid on the server. Start the link flow again on this Mac."
                        )
                    } else {
                        accessToken = nil
                        clearWorkspaceData()
                        refreshLocalIdentityState(reportErrors: false)
                        lastErrorMessage = "This device is still pending approval. Approve it from any active trusted device in the device directory, then reconnect. If that link was rejected or revoked, restart the link flow on this Mac."
                    }
                } else {
                    try? clearSession()
                    serverBaseURLString = session.baseURLString
                    draft.profileName = session.profileName
                    draft.handle = session.handle ?? ""
                    draft.deviceDisplayName = session.deviceDisplayName
                    linkDraft.deviceDisplayName = session.deviceDisplayName
                    lastErrorMessage = "Сохранённая сессия больше невалидна. Создай устройство заново."
                }
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            logWarn("auth", "restore_session failed device=\(shortLogID(session.deviceId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func refreshWorkspace() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        logInfo("sync", "workspace_refresh start")
        isRefreshingWorkspace = true
        defer { isRefreshingWorkspace = false }

        do {
            try await loadWorkspace(client: client, accessToken: token)
            await refreshServerStatus()
            logInfo(
                "sync",
                "workspace_refresh success chats=\(chats.count) devices=\(devices.count) inbox=\(inboxItems.count)"
            )
        } catch let error as TrixAPIError {
            logWarn("sync", "workspace_refresh failed", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                disconnectRealtimeConnection()
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            logWarn("sync", "workspace_refresh failed", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func updateProfile() async {
        guard canUpdateProfile else {
            return
        }
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let profileName = editProfileDraft.profileName.nonEmptyTrimmed else {
            lastErrorMessage = "Укажи имя профиля."
            return
        }

        isUpdatingProfile = true
        lastErrorMessage = nil
        defer { isUpdatingProfile = false }

        do {
            let updated = try await client.updateAccountProfile(
                accessToken: token,
                request: UpdateAccountProfileRequest(
                    handle: editProfileDraft.handle.nonEmptyTrimmed,
                    profileName: profileName,
                    profileBio: editProfileDraft.profileBio.nonEmptyTrimmed
                )
            )
            currentAccount = updated
            syncEditProfileDraft(with: updated)
            try updatePersistedSessionProfile(from: updated)
            await refreshWorkspace()
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func createChat() async -> Bool {
        guard let token = accessToken else {
            await restoreSession()
            return false
        }
        guard let client = makeClient() else {
            return false
        }
        guard let creatorAccountID = currentAccount?.accountId ?? persistedSession?.accountId else {
            lastErrorMessage = "Аккаунт ещё не загружен."
            return false
        }
        guard let creatorDeviceID = currentDeviceID else {
            lastErrorMessage = "Текущее устройство ещё не загружено."
            return false
        }

        isCreatingChat = true
        lastErrorMessage = nil
        defer { isCreatingChat = false }

        do {
            let identity = try loadStoredIdentity()
            var seenParticipantIDs = Set<UUID>()
            let uniqueParticipants = createChatParticipantAccountIDs.filter { participantAccountID in
                guard participantAccountID != creatorAccountID else {
                    return false
                }

                return seenParticipantIDs.insert(participantAccountID).inserted
            }

            switch createChatDraft.chatType {
            case .dm:
                guard uniqueParticipants.count == 1 else {
                    throw TrixAPIError.invalidPayload("Для DM укажи ровно один account id собеседника.")
                }
            case .group:
                guard !uniqueParticipants.isEmpty else {
                    throw TrixAPIError.invalidPayload("Для группы укажи хотя бы один account id участника.")
                }
            case .accountSync:
                throw TrixAPIError.invalidPayload("Account sync chats создаются только сервером.")
            }

            logInfo(
                "chat",
                "create_chat start type=\(logChatType(createChatDraft.chatType)) participants=\(uniqueParticipants.count)"
            )
            let storePaths = try workspaceStorePaths()
            let created = try await client.createChatControl(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity,
                creatorAccountId: creatorAccountID,
                creatorDeviceId: creatorDeviceID,
                chatType: createChatDraft.chatType,
                title: createChatDraft.title.nonEmptyTrimmed,
                participantAccountIds: uniqueParticipants
            )

            resetCreateChatComposer()
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .force(created.chatId)
            )
            logInfo(
                "chat",
                "create_chat success chat=\(shortLogID(created.chatId)) epoch=\(created.epoch)"
            )
            return true
        } catch let error as TrixAPIError {
            logWarn("chat", "create_chat failed", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            logWarn("chat", "create_chat failed", error: error)
            lastErrorMessage = error.userFacingMessage
        }

        return false
    }

    func sendMessage(draftText: String) async -> Bool {
        guard let token = accessToken else {
            await restoreSession()
            return false
        }
        guard let client = makeClient() else {
            return false
        }
        guard let chatId = selectedChatID else {
            lastErrorMessage = "Сначала выбери чат."
            return false
        }
        guard let senderAccountID = currentAccount?.accountId ?? persistedSession?.accountId else {
            lastErrorMessage = "Аккаунт ещё не загружен."
            return false
        }
        guard let senderDeviceID = currentDeviceID else {
            lastErrorMessage = "Текущее устройство ещё не загружено."
            return false
        }
        let trimmedText = draftText.nonEmptyTrimmed
        guard trimmedText != nil || composerAttachmentDraft != nil else {
            return false
        }

        isSendingMessage = true
        lastErrorMessage = nil
        defer { isSendingMessage = false }

        do {
            logInfo(
                "message",
                "send_message start chat=\(shortLogID(chatId)) text=\(trimmedText != nil) attachment=\(composerAttachmentDraft != nil)"
            )
            let identity = try loadStoredIdentity()
            let storePaths = try workspaceStorePaths()
            if let attachmentDraft = composerAttachmentDraft {
                let pendingAttachment = enqueuePendingOutgoing(
                    chatId: chatId,
                    payload: .attachment(attachmentDraft)
                )
                do {
                    try await sendAttachmentPayload(
                        client: client,
                        accessToken: token,
                        storePaths: storePaths,
                        identity: identity,
                        senderAccountID: senderAccountID,
                        senderDeviceID: senderDeviceID,
                        chatId: chatId,
                        draft: attachmentDraft
                    )
                    removePendingOutgoing(pendingAttachment)
                } catch {
                    markPendingOutgoingFailed(
                        pendingAttachment,
                        errorMessage: conversationSafeMessage(error.userFacingMessage)
                    )
                    throw error
                }
            }

            if let trimmedText {
                let pendingText = enqueuePendingOutgoing(
                    chatId: chatId,
                    payload: .text(trimmedText)
                )
                do {
                    _ = try await client.sendMessageBody(
                        accessToken: token,
                        databasePath: storePaths.localHistoryURL,
                        statePath: storePaths.syncStateURL,
                        mlsStorageRoot: storePaths.mlsStateRootURL,
                        credentialIdentity: identity.storedIdentity.credentialIdentity,
                        senderAccountId: senderAccountID,
                        senderDeviceId: senderDeviceID,
                        chatId: chatId,
                        body: .text(trimmedText)
                    )
                    removePendingOutgoing(pendingText)
                } catch {
                    markPendingOutgoingFailed(
                        pendingText,
                        errorMessage: conversationSafeMessage(error.userFacingMessage)
                    )
                    throw error
                }
            }

            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            composerAttachmentDraft = nil
            logInfo("message", "send_message success chat=\(shortLogID(chatId))")
            return true
        } catch let error as TrixAPIError {
            logWarn("message", "send_message failed chat=\(shortLogID(chatId))", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = conversationSafeMessage(error.userFacingMessage)
            }
        } catch {
            logWarn("message", "send_message failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = conversationSafeMessage(error.userFacingMessage)
        }

        return false
    }

    func searchAccounts(query: String?) async -> [DirectoryAccountSummary] {
        guard let token = accessToken else {
            await restoreSession()
            return []
        }
        guard let client = makeClient() else {
            return []
        }

        isSearchingAccountDirectory = true
        lastErrorMessage = nil
        defer { isSearchingAccountDirectory = false }

        do {
            let response = try await client.fetchAccountDirectory(
                accessToken: token,
                query: query?.nonEmptyTrimmed
            )
            return response.accounts
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }

        return []
    }

    func searchAccountDirectory() async {
        accountDirectoryResults = await searchAccounts(query: createChatDraft.directoryQuery)
    }

    func retryPendingOutgoingMessage(_ pendingMessageID: UUID) async {
        guard let pendingMessage = pendingOutgoingMessages.first(where: { $0.id == pendingMessageID }) else {
            return
        }

        markPendingOutgoingSending(pendingMessageID)
        composerAttachmentDraft = nil

        let success: Bool
        switch pendingMessage.payload {
        case let .text(text):
            success = await sendMessage(draftText: text)
        case let .attachment(attachmentDraft):
            composerAttachmentDraft = attachmentDraft
            success = await sendMessage(draftText: "")
        }

        if success {
            removePendingOutgoing(pendingMessageID)
        }
    }

    func discardPendingOutgoingMessage(_ pendingMessageID: UUID) {
        removePendingOutgoing(pendingMessageID)
    }

    func openAttachment(for message: LocalTimelineItem) async {
        guard let body = message.body, body.kind == .attachment else {
            return
        }
        downloadingAttachmentMessageIDs.insert(message.messageId)
        defer { downloadingAttachmentMessageIDs.remove(message.messageId) }

        if let cachedURL = await ensureCachedAttachmentURL(
            for: message,
            reportErrors: true
        ) {
            presentAttachment(url: cachedURL, body: body)
        }
    }

    func addMembersToSelectedChat(_ participantAccountIDs: [UUID]) async {
        guard !participantAccountIDs.isEmpty else {
            return
        }
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let actorAccountID = currentAccount?.accountId ?? persistedSession?.accountId,
              let actorDeviceID = currentDeviceID,
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        isAddingChatMembers = true
        defer { isAddingChatMembers = false }

        do {
            logInfo(
                "membership",
                "add_members start chat=\(shortLogID(chatId)) count=\(participantAccountIDs.count)"
            )
            let identity = try loadStoredIdentity()
            let storePaths = try workspaceStorePaths()
            let outcome = try await client.addChatMembersControl(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity,
                actorAccountId: actorAccountID,
                actorDeviceId: actorDeviceID,
                chatId: chatId,
                participantAccountIds: participantAccountIDs
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "membership",
                "add_members success chat=\(shortLogID(chatId)) changed=\(outcome.changedParticipantAccountIDs.count) epoch=\(outcome.epoch)"
            )
        } catch {
            logWarn("membership", "add_members failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func removeMemberFromSelectedChat(_ participantAccountID: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let actorAccountID = currentAccount?.accountId ?? persistedSession?.accountId,
              let actorDeviceID = currentDeviceID,
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        removingChatMemberAccountIDs.insert(participantAccountID)
        defer { removingChatMemberAccountIDs.remove(participantAccountID) }

        do {
            logInfo(
                "membership",
                "remove_member start chat=\(shortLogID(chatId)) account=\(shortLogID(participantAccountID))"
            )
            let identity = try loadStoredIdentity()
            let storePaths = try workspaceStorePaths()
            let outcome = try await client.removeChatMembersControl(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity,
                actorAccountId: actorAccountID,
                actorDeviceId: actorDeviceID,
                chatId: chatId,
                participantAccountIds: [participantAccountID]
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "membership",
                "remove_member success chat=\(shortLogID(chatId)) changed=\(outcome.changedParticipantAccountIDs.count) epoch=\(outcome.epoch)"
            )
        } catch {
            logWarn("membership", "remove_member failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func addDevicesToSelectedChat(_ deviceIDs: [UUID]) async {
        guard !deviceIDs.isEmpty else {
            return
        }
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let actorAccountID = currentAccount?.accountId ?? persistedSession?.accountId,
              let actorDeviceID = currentDeviceID,
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        isAddingChatDevices = true
        defer { isAddingChatDevices = false }

        do {
            logInfo(
                "devices",
                "add_devices start chat=\(shortLogID(chatId)) count=\(deviceIDs.count)"
            )
            let identity = try loadStoredIdentity()
            let storePaths = try workspaceStorePaths()
            let outcome = try await client.addChatDevicesControl(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity,
                actorAccountId: actorAccountID,
                actorDeviceId: actorDeviceID,
                chatId: chatId,
                deviceIds: deviceIDs
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "devices",
                "add_devices success chat=\(shortLogID(chatId)) changed=\(outcome.changedDeviceIDs.count) epoch=\(outcome.epoch)"
            )
        } catch {
            logWarn("devices", "add_devices failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func removeDeviceFromSelectedChat(_ deviceID: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let actorAccountID = currentAccount?.accountId ?? persistedSession?.accountId,
              let actorDeviceID = currentDeviceID,
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        removingChatDeviceIDs.insert(deviceID)
        defer { removingChatDeviceIDs.remove(deviceID) }

        do {
            logInfo(
                "devices",
                "remove_device start chat=\(shortLogID(chatId)) device=\(shortLogID(deviceID))"
            )
            let identity = try loadStoredIdentity()
            let storePaths = try workspaceStorePaths()
            let outcome = try await client.removeChatDevicesControl(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity,
                actorAccountId: actorAccountID,
                actorDeviceId: actorDeviceID,
                chatId: chatId,
                deviceIds: [deviceID]
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "devices",
                "remove_device success chat=\(shortLogID(chatId)) changed=\(outcome.changedDeviceIDs.count) epoch=\(outcome.epoch)"
            )
        } catch {
            logWarn("devices", "remove_device failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func toggleCreateChatParticipant(_ participant: DirectoryAccountSummary) {
        switch createChatDraft.chatType {
        case .dm:
            createChatDraft.selectedParticipants = [participant]
        case .group:
            if createChatDraft.selectedParticipants.contains(where: { $0.accountId == participant.accountId }) {
                createChatDraft.selectedParticipants.removeAll { $0.accountId == participant.accountId }
            } else {
                createChatDraft.selectedParticipants.append(participant)
            }
        case .accountSync:
            break
        }
    }

    func removeCreateChatParticipant(_ participantID: UUID) {
        createChatDraft.selectedParticipants.removeAll { $0.accountId == participantID }
    }

    func setCreateChatType(_ chatType: ChatType) {
        createChatDraft.chatType = chatType
        normalizeCreateChatSelectionForType()
    }

    func prepareCreateChatSheet() async {
        normalizeCreateChatSelectionForType()

        if accountDirectoryResults.isEmpty && !isSearchingAccountDirectory {
            await searchAccountDirectory()
        }
    }

    func resetCreateChatComposer() {
        createChatDraft = CreateChatDraft()
        accountDirectoryResults = []
    }

    func refreshHistorySyncJobs() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isRefreshingHistorySyncJobs = true
        defer { isRefreshingHistorySyncJobs = false }

        do {
            try await loadHistorySyncJobs(client: client, accessToken: token)
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func refreshInbox(background: Bool = false, suppressErrors: Bool = false) async {
        guard let token = accessToken else {
            if !suppressErrors {
                await restoreSession()
            }
            return
        }
        guard let client = makeClient() else {
            return
        }

        isRefreshingInbox = true
        lastErrorMessage = nil
        defer { isRefreshingInbox = false }

        do {
            logInfo("inbox", "refresh_inbox start background=\(background)")
            let existingInboxIDs = Set(inboxItems.map(\.inboxId))
            let parameters = try decodeInboxPollParameters()
            let storePaths = try workspaceStorePaths()
            let response = try await client.fetchInboxIntoLocalStore(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                afterInboxId: parameters.afterInboxId,
                limit: parameters.limit
            )
            let changedChatIDs = Set(response.report.changedChatIDs)
            let identity = try loadStoredIdentity()
            for chatId in changedChatIDs {
                _ = try await client.projectLocalChatIfPossible(
                    databasePath: storePaths.localHistoryURL,
                    mlsStorageRoot: storePaths.mlsStateRootURL,
                    credentialIdentity: identity.storedIdentity.credentialIdentity,
                    chatId: chatId
                )
            }
            let projectedChats = try await client.fetchLocalChats(databasePath: storePaths.localHistoryURL)
            let currentAccountID = currentAccount?.accountId ?? persistedSession?.accountId
            let newIncomingItems = response.items.filter { item in
                !existingInboxIDs.contains(item.inboxId) &&
                    item.message.senderAccountId != currentAccountID
            }
            mergeInboxItems(response.items, autoAdvanceCursor: true)
            applyLocalStoreSnapshot(chats: projectedChats.chats, syncState: response.syncState)
            if let accountId = currentAccount?.accountId ?? persistedSession?.accountId {
                try await refreshLocalMessengerState(client: client, accountId: accountId)
                try await reconcileSelectedChatAfterLocalStateUpdate(
                    client: client,
                    accessToken: token,
                    changedChatIDs: changedChatIDs
                )
            }
            if background {
                await postNotificationsForNewMessages(newIncomingItems)
            }
            logInfo(
                "inbox",
                "refresh_inbox success items=\(response.items.count) changed_chats=\(changedChatIDs.count)"
            )
        } catch let error as TrixAPIError {
            logWarn("inbox", "refresh_inbox failed", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                disconnectRealtimeConnection()
                lastErrorMessage = "Session expired. Reconnect this Mac to keep syncing messages."
                if !suppressErrors {
                    await restoreSession()
                }
            } else if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            logWarn("inbox", "refresh_inbox failed", error: error)
            if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }
    }

    func leaseInbox() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isLeasingInbox = true
        lastErrorMessage = nil
        defer { isLeasingInbox = false }

        do {
            let parameters = try decodeInboxPollParameters()
            let storePaths = try workspaceStorePaths()
            let response = try await client.leaseInboxIntoLocalStore(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                leaseOwner: parameters.leaseOwner,
                limit: parameters.limit,
                afterInboxId: parameters.afterInboxId,
                leaseTtlSeconds: parameters.leaseTtlSeconds
            )
            let changedChatIDs = Set(response.report.changedChatIDs)
            let identity = try loadStoredIdentity()
            for chatId in changedChatIDs {
                _ = try await client.projectLocalChatIfPossible(
                    databasePath: storePaths.localHistoryURL,
                    mlsStorageRoot: storePaths.mlsStateRootURL,
                    credentialIdentity: identity.storedIdentity.credentialIdentity,
                    chatId: chatId
                )
            }
            let projectedChats = try await client.fetchLocalChats(databasePath: storePaths.localHistoryURL)
            activeInboxLease = InboxLeaseState(
                owner: response.lease.leaseOwner,
                expiresAt: response.lease.leaseExpiresAt
            )
            mergeInboxItems(response.lease.items, autoAdvanceCursor: true)
            applyLocalStoreSnapshot(chats: projectedChats.chats, syncState: response.syncState)
            if let accountId = currentAccount?.accountId ?? persistedSession?.accountId {
                try await refreshLocalMessengerState(client: client, accountId: accountId)
                try await reconcileSelectedChatAfterLocalStateUpdate(
                    client: client,
                    accessToken: token,
                    changedChatIDs: changedChatIDs
                )
            }
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func ackLoadedInboxItems() async {
        guard canAckLoadedInboxItems else {
            return
        }
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isAckingInbox = true
        lastErrorMessage = nil
        defer { isAckingInbox = false }

        do {
            let inboxIds = inboxItems.map(\.inboxId)
            let storePaths = try workspaceStorePaths()
            let response = try await client.ackInboxIntoSyncState(
                accessToken: token,
                statePath: storePaths.syncStateURL,
                inboxIds: inboxIds
            )

            let acked = Set(response.ackedInboxIds)
            inboxItems.removeAll { acked.contains($0.inboxId) }
            lastAckedInboxIDs = response.ackedInboxIds.sorted()
            applySyncStateSnapshot(response.syncState)
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func useLastInboxCursor() {
        guard let lastInboxCursor else {
            return
        }

        inboxLeaseDraft.afterInboxID = String(lastInboxCursor)
    }

    func resetInboxCursor() {
        inboxLeaseDraft.afterInboxID = ""
    }

    func clearLoadedInboxItems() {
        inboxItems = []
        lastAckedInboxIDs = []
    }

    func publishKeyPackages() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isPublishingKeyPackages = true
        lastErrorMessage = nil
        defer { isPublishingKeyPackages = false }

        do {
            let packages = try decodePublishKeyPackageItems(keyPackagePublishDraft.packagesJSON)
            let response = try await client.publishKeyPackages(
                accessToken: token,
                request: PublishKeyPackagesRequest(packages: packages)
            )

            publishedKeyPackages = response.packages
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func reserveKeyPackages() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let accountID = try? decodeUUID(keyPackageReserveDraft.accountID, label: "account id") else {
            lastErrorMessage = "Укажи валидный account id."
            return
        }

        isReservingKeyPackages = true
        lastErrorMessage = nil
        defer { isReservingKeyPackages = false }

        do {
            let response: AccountKeyPackagesResponse
            switch keyPackageReserveDraft.mode {
            case .allActiveDevices:
                response = try await client.fetchAccountKeyPackages(
                    accessToken: token,
                    accountId: accountID
                )
            case .selectedDevices:
                let deviceIDs = try decodeUUIDList(
                    keyPackageReserveDraft.selectedDeviceIDs,
                    label: "device ids"
                )
                response = try await client.reserveKeyPackages(
                    accessToken: token,
                    request: ReserveKeyPackagesRequest(
                        accountId: accountID,
                        deviceIds: deviceIDs
                    )
                )
            }

            reservedKeyPackagesAccountID = response.accountId
            reservedKeyPackages = response.packages
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func useVisibleActiveDeviceIDsForReserve() {
        let deviceIDs = devices
            .filter { $0.deviceStatus == .active }
            .map(\.deviceId.uuidString)
            .joined(separator: "\n")
        keyPackageReserveDraft.selectedDeviceIDs = deviceIDs
    }

    func completeHistorySyncJob(_ jobID: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        completingHistorySyncJobIDs.insert(jobID)
        defer { completingHistorySyncJobIDs.remove(jobID) }

        do {
            let cursorJSON = try decodeCursorJSON(historySyncCursorDrafts[jobID])
            _ = try await client.completeHistorySyncJob(
                accessToken: token,
                jobId: jobID,
                request: CompleteHistorySyncJobRequest(cursorJson: cursorJSON)
            )
            try await loadHistorySyncJobs(client: client, accessToken: token)
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func approvePendingDevice(_ device: DeviceSummary) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard hasAccountRootKey else {
            lastErrorMessage = "Approve доступен только на root-capable устройстве."
            return
        }
        guard device.deviceStatus == .pending else {
            lastErrorMessage = "Only pending devices can be approved."
            return
        }
        guard currentDeviceID != device.deviceId else {
            lastErrorMessage = "Текущее устройство нельзя approve из этого же сеанса."
            return
        }
        guard let client = makeClient() else {
            return
        }

        approvingDeviceIDs.insert(device.deviceId)
        lastErrorMessage = nil
        defer { approvingDeviceIDs.remove(device.deviceId) }

        do {
            let identity = try loadStoredIdentity(requireAccountRoot: true)
            let approvePayload = try await client.fetchDeviceApprovePayload(
                accessToken: token,
                deviceId: device.deviceId
            )
            let transferBundle = try makeApproveTransferBundle(
                approvePayload: approvePayload,
                identity: identity
            )
            _ = try await client.approveDevice(
                accessToken: token,
                deviceId: device.deviceId,
                identity: identity,
                transferBundle: transferBundle
            )

            await refreshWorkspace()
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func revokeDevice(_ device: DeviceSummary) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard hasAccountRootKey else {
            lastErrorMessage = "Revoke доступен только на root-capable устройстве."
            return
        }
        guard currentDeviceID != device.deviceId else {
            lastErrorMessage = "Текущее устройство нельзя отозвать из этого же сеанса."
            return
        }

        revokingDeviceIDs.insert(device.deviceId)
        lastErrorMessage = nil
        defer { revokingDeviceIDs.remove(device.deviceId) }

        do {
            let identity = try loadStoredIdentity(requireAccountRoot: true)
            let reason = device.deviceStatus == .pending
                ? "pending link rejected from macOS alpha client"
                : "device revoked from macOS alpha client"

            guard let client = makeClient() else {
                return
            }

            _ = try await client.revokeDevice(
                accessToken: token,
                deviceId: device.deviceId,
                reason: reason,
                identity: identity
            )

            await refreshWorkspace()
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func selectChat(_ chatId: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard
            selectedChatID != chatId ||
                selectedChatDetail == nil ||
                (selectedChatTimelineItems.isEmpty && selectedChatHistory.isEmpty)
        else {
            return
        }

        logInfo("chat", "select_chat start chat=\(shortLogID(chatId))")
        do {
            try await loadSelectedChat(
                client: client,
                accessToken: token,
                chatId: chatId,
                loadMode: selectedChatID == chatId ? .preserveVisibleState : .replaceVisibleState
            )
            logInfo("chat", "select_chat success chat=\(shortLogID(chatId))")
        } catch let error as TrixAPIError {
            logWarn("chat", "select_chat failed chat=\(shortLogID(chatId))", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            logWarn("chat", "select_chat failed chat=\(shortLogID(chatId))", error: error)
            lastErrorMessage = error.userFacingMessage
        }
    }

    func signOut() {
        do {
            try clearSession()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func restartPendingLinkFlow() {
        guard let session = persistedSession else {
            return
        }

        restartPendingLinkFlow(
            baseURLString: session.baseURLString,
            deviceDisplayName: session.deviceDisplayName
        )
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    private func makeClient(baseURLString: String? = nil) -> TrixAPIClient? {
        let rawValue = baseURLString ?? serverBaseURLString
        guard let baseURL = ServerEndpoint.normalizedURL(from: rawValue) else {
            lastErrorMessage = "Не удалось разобрать URL сервера."
            return nil
        }
        do {
            return try TrixAPIClient(baseURL: baseURL)
        } catch {
            lastErrorMessage = error.userFacingMessage
            return nil
        }
    }

    private func authenticate(
        client: TrixAPIClient,
        deviceId: UUID,
        identity: DeviceIdentityMaterial
    ) async throws -> AuthSessionResponse {
        try await client.authenticate(
            deviceId: deviceId,
            identity: identity
        )
    }

    private func startRealtimeConnection(
        accessToken: String,
        accountId: UUID
    ) async {
        guard let session = persistedSession else {
            return
        }

        let normalizedBaseURL = ServerEndpoint.normalizedURL(from: session.baseURLString)?
            .absoluteString ?? session.baseURLString
        if realtimeClient != nil,
           realtimeAccessToken == accessToken,
           realtimeBaseURLString == normalizedBaseURL {
            return
        }

        await stopRealtimeConnection()

        do {
            let storePaths = try workspaceStorePaths(for: accountId)
            let connectionID = UUID()
            realtimeConnectionID = connectionID
            let client = try RealtimeWebSocketClient(
                baseURLString: session.baseURLString,
                accessToken: accessToken,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                onEvent: { [weak self] update in
                    await self?.handleRealtimeUpdate(update, connectionID: connectionID)
                },
                onDisconnect: { [weak self] reason in
                    await self?.handleRealtimeDisconnect(reason, connectionID: connectionID)
                }
            )
            realtimeClient = client
            realtimeAccessToken = accessToken
            realtimeBaseURLString = normalizedBaseURL
            await client.start()
        } catch {
            realtimeClient = nil
            realtimeAccessToken = nil
            realtimeBaseURLString = nil
            scheduleRealtimeRecovery(delayNanoseconds: 1_500_000_000)
        }
    }

    private func stopRealtimeConnection() async {
        let client = realtimeClient
        realtimeClient = nil
        realtimeAccessToken = nil
        realtimeBaseURLString = nil
        realtimeConnectionID = UUID()
        await client?.stop()
    }

    private func disconnectRealtimeConnection() {
        let client = realtimeClient
        realtimeClient = nil
        realtimeAccessToken = nil
        realtimeBaseURLString = nil
        realtimeConnectionID = UUID()

        if let client {
            Task {
                await client.stop()
            }
        }
    }

    private func handleRealtimeUpdate(
        _ update: RealtimeConnectionUpdate,
        connectionID: UUID
    ) async {
        guard realtimeConnectionID == connectionID else {
            return
        }

        switch update.event.kind {
        case .hello, .pong:
            return
        case .inboxItems:
            await applyRealtimeLocalUpdate(
                changedChatIDs: Set(update.event.report?.changedChatIds.compactMap(UUID.init(uuidString:)) ?? []),
                ackedInboxIDs: [],
                postNotifications: !isApplicationActive
            )
        case .acked:
            removeAckedInboxItems(update.event.serverAckedInboxIds)
            do {
                let storePaths = try workspaceStorePaths()
                let client = try makeClientForRealtimeRefresh()
                let syncState = try await client.fetchSyncStateSnapshot(statePath: storePaths.syncStateURL)
                applySyncStateSnapshot(syncState)
            } catch {
                scheduleRealtimeRecovery(delayNanoseconds: 300_000_000)
            }
        case .sessionReplaced:
            let reason = update.event.sessionReplacedReason?.nonEmptyTrimmed
            disconnectRealtimeConnection()
            if let reason, !isRecoverableRealtimeSessionReplacement(reason) {
                lastErrorMessage = reason
            }
            scheduleRealtimeRecovery(
                delayNanoseconds: isRecoverableRealtimeSessionReplacement(reason) ? 500_000_000 : 1_500_000_000
            )
        case .error:
            if let message = update.event.errorMessage?.nonEmptyTrimmed {
                lastErrorMessage = message
            }
            disconnectRealtimeConnection()
            scheduleRealtimeRecovery(delayNanoseconds: 1_500_000_000)
        case .disconnected:
            disconnectRealtimeConnection()
            scheduleRealtimeRecovery(delayNanoseconds: 1_500_000_000)
        }
    }

    private func handleRealtimeDisconnect(
        _ reason: String?,
        connectionID: UUID
    ) async {
        guard realtimeConnectionID == connectionID else {
            return
        }

        disconnectRealtimeConnection()
        if let reason = reason?.nonEmptyTrimmed,
           currentAccount == nil {
            lastErrorMessage = reason
        }
        scheduleRealtimeRecovery(delayNanoseconds: 1_500_000_000)
    }

    private func applyRealtimeLocalUpdate(
        changedChatIDs: Set<UUID>,
        ackedInboxIDs: [UInt64],
        postNotifications: Bool
    ) async {
        guard let accountId = currentAccount?.accountId ?? persistedSession?.accountId else {
            return
        }

        do {
            let client = try makeClientForRealtimeRefresh()
            let storePaths = try workspaceStorePaths(for: accountId)
            let identity = try loadStoredIdentity()
            guard let accessToken else {
                return
            }
            let previousChatListItems = Dictionary(uniqueKeysWithValues: localChatListItems.map { ($0.chatId, $0) })

            for chatId in changedChatIDs {
                _ = try await client.projectLocalChatIfPossible(
                    databasePath: storePaths.localHistoryURL,
                    mlsStorageRoot: storePaths.mlsStateRootURL,
                    credentialIdentity: identity.storedIdentity.credentialIdentity,
                    chatId: chatId
                )
            }

            let projectedChats = try await client.fetchLocalChats(databasePath: storePaths.localHistoryURL)
            let syncState = try await client.fetchSyncStateSnapshot(statePath: storePaths.syncStateURL)

            applyLocalStoreSnapshot(chats: projectedChats.chats, syncState: syncState)
            try await refreshLocalMessengerState(client: client, accountId: accountId)
            removeAckedInboxItems(ackedInboxIDs)
            try await reconcileSelectedChatAfterLocalStateUpdate(
                client: client,
                accessToken: accessToken,
                changedChatIDs: changedChatIDs
            )

            if postNotifications {
                await postRealtimeNotifications(
                    previousChatListItems: previousChatListItems,
                    changedChatIDs: changedChatIDs
                )
            }
        } catch {
            await refreshInbox(background: postNotifications, suppressErrors: true)
        }
    }

    private func postRealtimeNotifications(
        previousChatListItems: [UUID: LocalChatListItem],
        changedChatIDs: Set<UUID>
    ) async {
        guard notificationPreferences.isEnabled else {
            return
        }

        switch notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            return
        }

        guard let currentAccountID = currentAccount?.accountId ?? persistedSession?.accountId else {
            return
        }

        for chatId in changedChatIDs {
            guard let currentItem = localChatListItems.first(where: { $0.chatId == chatId }) else {
                continue
            }

            let previousServerSeq = previousChatListItems[chatId]?.lastServerSeq ?? 0
            guard currentItem.lastServerSeq > previousServerSeq else {
                continue
            }
            guard currentItem.previewSenderAccountId != currentAccountID else {
                continue
            }

            await notificationCoordinator.postMessageNotification(
                identifier: "chat-\(chatId.uuidString)-\(currentItem.lastServerSeq)",
                title: currentItem.displayTitle,
                body: currentItem.previewText ?? "You have a new message."
            )
        }
    }

    private func scheduleRealtimeRecovery(delayNanoseconds: UInt64) {
        guard !hasScheduledRealtimeRecovery else {
            return
        }

        hasScheduledRealtimeRecovery = true

        Task { [weak self] in
            guard let self else {
                return
            }

            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            defer {
                self.hasScheduledRealtimeRecovery = false
            }

            if let accessToken,
               let accountId = self.currentAccount?.accountId ?? self.persistedSession?.accountId {
                await self.startRealtimeConnection(
                    accessToken: accessToken,
                    accountId: accountId
                )
            } else if self.persistedSession != nil {
                await self.restoreSession()
            }
        }
    }

    private func makeClientForRealtimeRefresh() throws -> TrixAPIClient {
        guard let client = makeClient() else {
            throw TrixAPIError.invalidPayload("Не удалось инициализировать realtime client.")
        }
        return client
    }

    private func loadWorkspace(client: TrixAPIClient, accessToken: String) async throws {
        try await loadWorkspace(client: client, accessToken: accessToken, selectionPreference: .automatic)
    }

    private func loadWorkspace(
        client: TrixAPIClient,
        accessToken: String,
        selectionPreference: WorkspaceSelectionPreference
    ) async throws {
        isRefreshingWorkspace = true
        defer { isRefreshingWorkspace = false }

        if let session = persistedSession {
            do {
                let identity = try loadStoredIdentity()
                let storePaths = try workspaceStorePaths(for: session.accountId)
                _ = try await client.ensureOwnDeviceKeyPackages(
                    accessToken: accessToken,
                    deviceId: session.deviceId,
                    mlsStorageRoot: storePaths.mlsStateRootURL,
                    credentialIdentity: identity.storedIdentity.credentialIdentity
                )
            } catch {
                lastErrorMessage = error.userFacingMessage
            }
        }

        async let profile = client.fetchCurrentAccount(accessToken: accessToken)
        async let devices = client.fetchDevices(accessToken: accessToken)
        async let chats = client.fetchChats(accessToken: accessToken)

        let loadedProfile = try await profile
        let loadedDevices = try await devices
        let loadedChats = try await chats

        let sortedChats = loadedChats.chats.sorted(by: chatSort)

        currentAccount = loadedProfile
        self.devices = loadedDevices.devices.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        self.chats = sortedChats

        try updatePersistedSessionProfile(from: loadedProfile)
        refreshLocalIdentityState(reportErrors: false)
        syncKeyPackageDrafts(with: loadedProfile)
        syncInboxDrafts(with: loadedProfile)
        syncEditProfileDraft(with: loadedProfile)
        try await loadHistorySyncJobs(client: client, accessToken: accessToken)
        await refreshLocalWorkspaceCache(
            client: client,
            accessToken: accessToken,
            accountId: loadedProfile.accountId
        )
        await startRealtimeConnection(
            accessToken: accessToken,
            accountId: loadedProfile.accountId
        )

        if let preferredChatID = resolvedWorkspaceSelection(
            selectionPreference: selectionPreference,
            currentSelectedChatID: selectedChatID,
            visibleLocalChatIDs: visibleLocalChatListItems.map(\.chatId),
            serverChatIDs: self.chats.map(\.chatId)
        ) {
            try await loadSelectedChat(
                client: client,
                accessToken: accessToken,
                chatId: preferredChatID,
                loadMode: selectedChatID == preferredChatID ? .preserveVisibleState : .replaceVisibleState
            )
        } else {
            clearSelectedChat()
        }
    }

    private func loadSelectedChat(
        client: TrixAPIClient,
        accessToken: String,
        chatId: UUID,
        loadMode: SelectedChatLoadMode = .replaceVisibleState
    ) async throws {
        let shouldResetVisibleState = loadMode.shouldResetVisibleState || selectedChatID != chatId
        selectedChatID = chatId
        if shouldResetVisibleState {
            resetSelectedChatContent()
        }
        isLoadingSelectedChat = true
        defer { isLoadingSelectedChat = false }

        let loadedDetail = try await client.fetchChatDetail(accessToken: accessToken, chatId: chatId)
        selectedChatDetail = loadedDetail

        do {
            let storePaths = try workspaceStorePaths()
            let selfAccountId = chatPresentationAccountID
            async let localChatListItem = client.fetchLocalChatListItem(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId,
                selfAccountId: selfAccountId
            )
            async let localTimelineItems = client.fetchLocalTimelineItems(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId,
                selfAccountId: selfAccountId
            )
            async let localReadState = client.fetchLocalChatReadState(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId,
                selfAccountId: selfAccountId
            )
            async let localHistory = client.fetchLocalChatHistory(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId
            )
            async let projectedCursor = client.fetchLocalProjectedCursor(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId
            )
            async let projectedMessages = client.fetchLocalProjectedMessages(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId
            )

            let loadedLocalChatListItem = try await localChatListItem
            let loadedLocalTimelineItems = try await localTimelineItems
            let loadedLocalReadState = try await localReadState
            let loadedProjectedCursor = try await projectedCursor
            let loadedProjectedMessages = try await projectedMessages
            let loadedLocalHistory = try await localHistory
            let localHistoryServerSeq = loadedLocalHistory.messages.map(\.serverSeq).max() ?? 0
            let localProjectedCursor = loadedProjectedCursor ?? 0

            var resolvedLocalChatListItem = loadedLocalChatListItem
            var resolvedLocalTimelineItems = loadedLocalTimelineItems
            var resolvedLocalReadState = loadedLocalReadState
            var resolvedProjectedCursor = loadedProjectedCursor
            var resolvedProjectedMessages = loadedProjectedMessages

            if localHistoryServerSeq > localProjectedCursor {
                let identity = try loadStoredIdentity()
                let projected = try await client.projectLocalChatIfPossible(
                    databasePath: storePaths.localHistoryURL,
                    mlsStorageRoot: storePaths.mlsStateRootURL,
                    credentialIdentity: identity.storedIdentity.credentialIdentity,
                    chatId: chatId
                )

                if projected {
                    async let refreshedLocalChatListItem = client.fetchLocalChatListItem(
                        databasePath: storePaths.localHistoryURL,
                        chatId: chatId,
                        selfAccountId: selfAccountId
                    )
                    async let refreshedLocalTimelineItems = client.fetchLocalTimelineItems(
                        databasePath: storePaths.localHistoryURL,
                        chatId: chatId,
                        selfAccountId: selfAccountId
                    )
                    async let refreshedLocalReadState = client.fetchLocalChatReadState(
                        databasePath: storePaths.localHistoryURL,
                        chatId: chatId,
                        selfAccountId: selfAccountId
                    )
                    async let refreshedProjectedCursor = client.fetchLocalProjectedCursor(
                        databasePath: storePaths.localHistoryURL,
                        chatId: chatId
                    )
                    async let refreshedProjectedMessages = client.fetchLocalProjectedMessages(
                        databasePath: storePaths.localHistoryURL,
                        chatId: chatId
                    )

                    resolvedLocalChatListItem = try await refreshedLocalChatListItem
                    resolvedLocalTimelineItems = try await refreshedLocalTimelineItems
                    resolvedLocalReadState = try await refreshedLocalReadState
                    resolvedProjectedCursor = try await refreshedProjectedCursor
                    resolvedProjectedMessages = try await refreshedProjectedMessages
                }
            }

            if let resolvedLocalChatListItem {
                upsertLocalChatListItem(resolvedLocalChatListItem)
            }
            selectedChatTimelineItems = resolvedLocalTimelineItems
            selectedChatReadState = resolvedLocalReadState
            selectedChatProjectedCursor = resolvedProjectedCursor
            selectedChatProjectedMessages = resolvedProjectedMessages

            if loadedLocalHistory.messages.isEmpty && loadedDetail.lastServerSeq > 0 {
                let remoteHistory = try await client.fetchChatHistory(
                    accessToken: accessToken,
                    chatId: chatId
                )
                selectedChatHistory = remoteHistory.messages
            } else {
                selectedChatHistory = loadedLocalHistory.messages
            }

            if let selfAccountId {
                try await markSelectedChatReadIfNeeded(
                    client: client,
                    accountId: selfAccountId,
                    chatId: chatId,
                    timelineItems: resolvedLocalTimelineItems
                )
            }
        } catch {
            let remoteHistory = try await client.fetchChatHistory(
                accessToken: accessToken,
                chatId: chatId
            )
            selectedChatHistory = remoteHistory.messages
        }
    }

    private func save(
        identity: DeviceIdentityMaterial,
        authSession: AuthSessionResponse?,
        persistedSession: PersistedSession
    ) throws {
        let storedIdentity = identity.storedIdentity

        if let accountRootSeed = storedIdentity.accountRootSeed {
            try keychainStore.save(accountRootSeed, for: .accountRootSeed)
        } else {
            try keychainStore.removeValue(for: .accountRootSeed)
        }
        try keychainStore.save(storedIdentity.transportSeed, for: .transportSeed)
        try keychainStore.save(storedIdentity.credentialIdentity, for: .credentialIdentity)

        if let authSession {
            try keychainStore.save(Data(authSession.accessToken.utf8), for: .accessToken)
            accessToken = authSession.accessToken
        } else {
            try keychainStore.removeValue(for: .accessToken)
            accessToken = nil
        }

        try sessionStore.save(persistedSession)
        self.persistedSession = persistedSession
        refreshLocalIdentityState(reportErrors: true)
    }

    private func loadStoredIdentity(requireAccountRoot: Bool = false) throws -> DeviceIdentityMaterial {
        guard
            let transportSeed = try keychainStore.loadData(for: .transportSeed),
            let credentialIdentity = try keychainStore.loadData(for: .credentialIdentity)
        else {
            throw TrixAPIError.invalidPayload("Не удалось загрузить ключи устройства из Keychain.")
        }

        let accountRootSeed = try keychainStore.loadData(for: .accountRootSeed)
        if requireAccountRoot && accountRootSeed == nil {
            throw TrixAPIError.invalidPayload("На этом устройстве нет account-root ключа.")
        }

        return try DeviceIdentityMaterial(
            storedIdentity: StoredDeviceIdentity(
                accountRootSeed: accountRootSeed,
                transportSeed: transportSeed,
                credentialIdentity: credentialIdentity
            )
        )
    }

    private func clearSession() throws {
        disconnectRealtimeConnection()
        try sessionStore.clear()
        try keychainStore.removeValue(for: .accountRootSeed)
        try keychainStore.removeValue(for: .transportSeed)
        try keychainStore.removeValue(for: .credentialIdentity)
        try keychainStore.removeValue(for: .accessToken)

        persistedSession = nil
        accessToken = nil
        clearWorkspaceData()
        outgoingLinkIntent = nil
        inboxLeaseDraft = InboxLeaseDraft()
        keyPackagePublishDraft = KeyPackagePublishDraft()
        keyPackageReserveDraft = KeyPackageReserveDraft()
        hasAccountRootKey = false
        onboardingMode = .createAccount
        linkDraft = LinkDeviceDraft(deviceDisplayName: defaultDeviceName)
    }

    private func clearWorkspaceData() {
        currentAccount = nil
        devices = []
        chats = []
        localChatListItems = []
        pendingOutgoingMessages = []
        composerAttachmentDraft = nil
        cachedAttachmentURLs = [:]
        previewedAttachment = nil
        accountDirectoryResults = []
        inboxItems = []
        activeInboxLease = nil
        lastInboxCursor = nil
        lastAckedInboxIDs = []
        syncStateSnapshot = nil
        historySyncJobs = []
        historySyncCursorDrafts = [:]
        approvingDeviceIDs = []
        publishedKeyPackages = []
        reservedKeyPackages = []
        reservedKeyPackagesAccountID = nil
        clearSelectedChat()
        createChatDraft = CreateChatDraft()
    }

    private func refreshLocalIdentityState(reportErrors: Bool) {
        do {
            hasAccountRootKey = try keychainStore.loadData(for: .accountRootSeed) != nil
        } catch {
            hasAccountRootKey = false
            if reportErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }
    }

    private func updatePersistedSessionProfile(from profile: AccountProfileResponse) throws {
        guard var session = persistedSession else {
            return
        }

        session.profileName = profile.profileName
        session.handle = profile.handle
        session.deviceId = profile.deviceId
        session.deviceStatus = profile.deviceStatus

        try sessionStore.save(session)
        persistedSession = session
    }

    private func syncKeyPackageDrafts(with profile: AccountProfileResponse) {
        if keyPackageReserveDraft.accountID.nonEmptyTrimmed == nil {
            keyPackageReserveDraft.accountID = profile.accountId.uuidString
        }
    }

    private func syncInboxDrafts(with profile: AccountProfileResponse) {
        if inboxLeaseDraft.leaseOwner.nonEmptyTrimmed == nil {
            inboxLeaseDraft.leaseOwner = defaultInboxLeaseOwner(for: profile.deviceId)
        }
    }

    private func syncEditProfileDraft(with profile: AccountProfileResponse) {
        editProfileDraft.handle = profile.handle ?? ""
        editProfileDraft.profileName = profile.profileName
        editProfileDraft.profileBio = profile.profileBio ?? ""
    }

    private func loadHistorySyncJobs(
        client: TrixAPIClient,
        accessToken: String
    ) async throws {
        let loadedJobs = try await client.fetchHistorySyncJobs(accessToken: accessToken)
        historySyncJobs = loadedJobs.jobs
        for job in loadedJobs.jobs {
            if historySyncCursorDrafts[job.jobId] == nil {
                historySyncCursorDrafts[job.jobId] = try encodeCursorJSON(job.cursorJson) ?? ""
            }
        }
    }

    private func refreshLocalWorkspaceCache(
        client: TrixAPIClient,
        accessToken: String,
        accountId: UUID
    ) async {
        do {
            let storePaths = try workspaceStorePaths(for: accountId)
            let identity = try loadStoredIdentity()
            var syncedState: SyncStateSnapshot?

            do {
                let localResult = try await client.syncChatHistoriesIntoLocalStore(
                    accessToken: accessToken,
                    databasePath: storePaths.localHistoryURL,
                    statePath: storePaths.syncStateURL
                )
                syncedState = localResult.syncState
            } catch {
                lastErrorMessage = error.userFacingMessage
            }

            _ = try await client.projectLocalChatsIfPossible(
                databasePath: storePaths.localHistoryURL,
                mlsStorageRoot: storePaths.mlsStateRootURL,
                credentialIdentity: identity.storedIdentity.credentialIdentity
            )
            let projectedChats = try await client.fetchLocalChats(databasePath: storePaths.localHistoryURL)
            if let syncedState {
                applyLocalStoreSnapshot(chats: projectedChats.chats, syncState: syncedState)
            } else if !projectedChats.chats.isEmpty {
                self.chats = projectedChats.chats.sorted(by: chatSort)
            }
            try await refreshLocalMessengerState(client: client, accountId: accountId)
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    private func workspaceStorePaths(for accountId: UUID? = nil) throws -> WorkspaceStorePaths {
        let resolvedAccountID = accountId ?? currentAccount?.accountId ?? persistedSession?.accountId
        guard let resolvedAccountID else {
            throw TrixAPIError.invalidPayload("Локальный workspace store ещё не инициализирован.")
        }

        return try WorkspaceStorePaths.forAccount(resolvedAccountID)
    }

    private func applyLocalStoreSnapshot(chats: [ChatSummary], syncState: SyncStateSnapshot) {
        if !chats.isEmpty {
            self.chats = chats.sorted(by: chatSort)
        }

        applySyncStateSnapshot(syncState)
    }

    private func refreshLocalMessengerState(
        client: TrixAPIClient,
        accountId: UUID
    ) async throws {
        let storePaths = try workspaceStorePaths(for: accountId)
        let loadedItems = try await client.fetchLocalChatListItems(
            databasePath: storePaths.localHistoryURL,
            selfAccountId: accountId
        )
        localChatListItems = mergeLocalChatListItems(
            existing: localChatListItems,
            incoming: loadedItems
        )
    }

    private func reconcileSelectedChatAfterLocalStateUpdate(
        client: TrixAPIClient,
        accessToken: String,
        changedChatIDs: Set<UUID> = []
    ) async throws {
        switch selectedChatReconciliationAction(
            selectedChatID: selectedChatID,
            visibleChatIDs: visibleLocalChatListItems.map(\.chatId),
            changedChatIDs: changedChatIDs
        ) {
        case .keep:
            return
        case .clear:
            clearSelectedChat()
        case let .load(chatId):
            try await loadSelectedChat(
                client: client,
                accessToken: accessToken,
                chatId: chatId,
                loadMode: selectedChatID == chatId ? .preserveVisibleState : .replaceVisibleState
            )
        }
    }

    private func makeApproveTransferBundle(
        approvePayload: DeviceApprovePayloadResponse,
        identity: DeviceIdentityMaterial
    ) throws -> Data {
        guard let sourceAccountID = currentAccount?.accountId ?? persistedSession?.accountId else {
            throw TrixAPIError.invalidPayload("Аккаунт ещё не загружен.")
        }
        guard let sourceDeviceID = currentDeviceID else {
            throw TrixAPIError.invalidPayload("Текущее устройство ещё не загружено.")
        }

        return try identity.createDeviceTransferBundle(
            DeviceTransferBundleInput(
                accountId: sourceAccountID,
                sourceDeviceId: sourceDeviceID,
                targetDeviceId: approvePayload.deviceId,
                accountSyncChatId: persistedSession?.accountSyncChatId,
                recipientTransportPubkey: try TrixCoreCodec.decodeBase64(
                    approvePayload.transportPubkeyB64,
                    label: "transport_pubkey_b64"
                )
            )
        )
    }

    private func restartPendingLinkFlow(
        baseURLString: String,
        deviceDisplayName: String,
        errorMessage: String? = nil
    ) {
        do {
            try clearSession()
            serverBaseURLString = baseURLString
            linkDraft = LinkDeviceDraft(deviceDisplayName: deviceDisplayName)
            draft.deviceDisplayName = deviceDisplayName
            onboardingMode = .linkExisting
            lastErrorMessage = errorMessage
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    private func applySyncStateSnapshot(_ syncState: SyncStateSnapshot) {
        syncStateSnapshot = syncState

        if inboxLeaseDraft.leaseOwner.nonEmptyTrimmed == nil {
            inboxLeaseDraft.leaseOwner = syncState.leaseOwner
        }

        if let lastAckedInboxId = syncState.lastAckedInboxId {
            lastInboxCursor = max(lastInboxCursor ?? 0, lastAckedInboxId)
            if inboxLeaseDraft.afterInboxID.nonEmptyTrimmed == nil {
                inboxLeaseDraft.afterInboxID = String(lastAckedInboxId)
            }
        }
    }

    private func decodeLinkIntentPayload(_ rawValue: String) throws -> LinkIntentPayload {
        guard let data = rawValue.nonEmptyTrimmed?.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Вставь link payload от активного устройства.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LinkIntentPayload.self, from: data)
    }

    private func decodeCursorJSON(_ rawValue: String?) throws -> JSONValue? {
        guard let rawValue = rawValue?.nonEmptyTrimmed else {
            return nil
        }

        guard let data = rawValue.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Cursor JSON должен быть валидным UTF-8.")
        }

        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func encodeCursorJSON(_ value: JSONValue?) throws -> String? {
        guard let value else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)
    }

    private func decodePublishKeyPackageItems(_ rawValue: String) throws -> [PublishKeyPackageItem] {
        guard let data = rawValue.nonEmptyTrimmed?.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Вставь JSON массив key packages.")
        }

        let packages = try JSONDecoder().decode([PublishKeyPackageItem].self, from: data)
        guard !packages.isEmpty else {
            throw TrixAPIError.invalidPayload("JSON массив key packages не должен быть пустым.")
        }

        return packages
    }

    private func decodeInboxPollParameters() throws -> InboxPollParameters {
        let afterInboxId = try decodeOptionalUInt64(
            inboxLeaseDraft.afterInboxID,
            label: "after inbox id"
        )
        let limit = try decodeOptionalInt(
            inboxLeaseDraft.limit,
            label: "limit",
            range: 1...500
        ) ?? InboxLeaseDraft.defaultLimit
        let leaseTtlSeconds = try decodeOptionalUInt64(
            inboxLeaseDraft.leaseTTLSeconds,
            label: "lease ttl seconds",
            range: 1...300
        ) ?? InboxLeaseDraft.defaultLeaseTTLSeconds

        return InboxPollParameters(
            afterInboxId: afterInboxId,
            limit: limit,
            leaseOwner: inboxLeaseDraft.leaseOwner.nonEmptyTrimmed,
            leaseTtlSeconds: leaseTtlSeconds
        )
    }

    private func decodeUUID(_ rawValue: String, label: String) throws -> UUID {
        guard let trimmed = rawValue.nonEmptyTrimmed, let uuid = UUID(uuidString: trimmed) else {
            throw TrixAPIError.invalidPayload("Не удалось разобрать \(label).")
        }
        return uuid
    }

    private func decodeOptionalUInt64(_ rawValue: String, label: String) throws -> UInt64? {
        guard let trimmed = rawValue.nonEmptyTrimmed else {
            return nil
        }
        guard let value = UInt64(trimmed) else {
            throw TrixAPIError.invalidPayload("Не удалось разобрать \(label).")
        }
        return value
    }

    private func decodeOptionalUInt64(
        _ rawValue: String,
        label: String,
        range: ClosedRange<UInt64>
    ) throws -> UInt64? {
        guard let value = try decodeOptionalUInt64(rawValue, label: label) else {
            return nil
        }
        guard range.contains(value) else {
            throw TrixAPIError.invalidPayload("\(label.capitalized) должен быть в диапазоне \(range.lowerBound)...\(range.upperBound).")
        }
        return value
    }

    private func decodeOptionalInt(
        _ rawValue: String,
        label: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let trimmed = rawValue.nonEmptyTrimmed else {
            return nil
        }
        guard let value = Int(trimmed), range.contains(value) else {
            throw TrixAPIError.invalidPayload("\(label.capitalized) должен быть в диапазоне \(range.lowerBound)...\(range.upperBound).")
        }
        return value
    }

    private func decodeUUIDList(_ rawValue: String, label: String) throws -> [UUID] {
        let parts = rawValue
            .split { $0 == "," || $0 == "\n" || $0 == "\t" || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            throw TrixAPIError.invalidPayload("Укажи хотя бы один \(label).")
        }

        return try parts.map { value in
            guard let uuid = UUID(uuidString: value) else {
                throw TrixAPIError.invalidPayload("Не удалось разобрать \(label).")
            }
            return uuid
        }
    }

    private func chatSort(lhs: ChatSummary, rhs: ChatSummary) -> Bool {
        if lhs.chatType == .accountSync && rhs.chatType != .accountSync {
            return false
        }
        if lhs.chatType != .accountSync && rhs.chatType == .accountSync {
            return true
        }
        return lhs.displayTitle(for: chatPresentationAccountID)
            .localizedCaseInsensitiveCompare(rhs.displayTitle(for: chatPresentationAccountID)) == .orderedAscending
    }

    private func preferredChatSelection(from chats: [ChatSummary]) -> UUID? {
        if let selectedChatID,
           chats.contains(where: { $0.chatId == selectedChatID }) {
            return selectedChatID
        }

        return chats.first?.chatId
    }

    private func preferredLocalChatSelection(from chats: [LocalChatListItem]) -> UUID? {
        let visibleChats = chats.filter { $0.chatType != .accountSync }
        if let selectedChatID,
           visibleChats.contains(where: { $0.chatId == selectedChatID }) {
            return selectedChatID
        }

        return visibleChats.first?.chatId
    }

    private func mergeLocalChatListItems(
        existing: [LocalChatListItem],
        incoming: [LocalChatListItem]
    ) -> [LocalChatListItem] {
        guard !existing.isEmpty else {
            return incoming
        }

        var existingByChatID = Dictionary(uniqueKeysWithValues: existing.map { ($0.chatId, $0) })
        return incoming.map { item in
            guard let existingItem = existingByChatID.removeValue(forKey: item.chatId) else {
                return item
            }

            return existingItem == item ? existingItem : item
        }
    }

    private func resolvedWorkspaceSelection(
        selectionPreference: WorkspaceSelectionPreference,
        currentSelectedChatID: UUID?,
        visibleLocalChatIDs: [UUID],
        serverChatIDs: [UUID]
    ) -> UUID? {
        resolvedWorkspaceSelectedChatID(
            selectionPreference: selectionPreference,
            currentSelectedChatID: currentSelectedChatID,
            visibleLocalChatIDs: visibleLocalChatIDs,
            serverChatIDs: serverChatIDs
        )
    }

    private func clearSelectedChat() {
        selectedChatID = nil
        resetSelectedChatContent()
    }

    private func resetSelectedChatContent() {
        selectedChatDetail = nil
        selectedChatReadState = nil
        selectedChatTimelineItems = []
        selectedChatProjectedCursor = nil
        selectedChatProjectedMessages = []
        selectedChatHistory = []
    }

    private func upsertLocalChatListItem(_ item: LocalChatListItem) {
        if let existingIndex = localChatListItems.firstIndex(where: { $0.chatId == item.chatId }) {
            localChatListItems[existingIndex] = item
            return
        }

        localChatListItems.append(item)
        localChatListItems.sort {
            $0.lastServerSeq > $1.lastServerSeq ||
                ($0.lastServerSeq == $1.lastServerSeq && $0.chatId.uuidString < $1.chatId.uuidString)
        }
    }

    private func startBackgroundRefreshLoopIfNeeded() {
        guard backgroundRefreshTask == nil else {
            return
        }

        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let interval = max(self.notificationPreferences.backgroundPollingIntervalSeconds, 15)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self.performBackgroundRefreshIfNeeded()
            }
        }
    }

    private func performBackgroundRefreshIfNeeded() async {
        guard isAuthenticated,
              !isRefreshingInbox,
              !isLeasingInbox,
              !isAckingInbox else {
            return
        }

        if realtimeClient != nil {
            return
        }

        if isApplicationActive {
            await refreshInbox(background: false, suppressErrors: true)
            return
        }

        guard notificationPreferences.isEnabled else {
            return
        }

        switch notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            await refreshInbox(background: true, suppressErrors: true)
        case .notDetermined, .denied:
            break
        }
    }

    private func postNotificationsForNewMessages(_ inboxItems: [InboxItem]) async {
        guard notificationPreferences.isEnabled else {
            return
        }

        switch notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined, .denied:
            return
        }

        let groupedByChat = Dictionary(grouping: inboxItems, by: { $0.message.chatId })
        for (chatId, items) in groupedByChat {
            guard let latestItem = items.max(by: { $0.inboxId < $1.inboxId }) else {
                continue
            }

            let chatTitle = localChatListItems.first(where: { $0.chatId == chatId })?.displayTitle ?? "New message"
            let body = localChatListItems.first(where: { $0.chatId == chatId })?.previewText ??
                "You have \(items.count) new message\(items.count == 1 ? "" : "s")."
            await notificationCoordinator.postMessageNotification(
                identifier: "chat-\(chatId.uuidString)-\(latestItem.inboxId)",
                title: chatTitle,
                body: body
            )
        }
    }

    private func enqueuePendingOutgoing(chatId: UUID, payload: PendingOutgoingPayload) -> UUID {
        let pendingMessage = PendingOutgoingMessage(chatId: chatId, payload: payload)
        pendingOutgoingMessages.append(pendingMessage)
        return pendingMessage.id
    }

    private func removePendingOutgoing(_ pendingMessageID: UUID) {
        pendingOutgoingMessages.removeAll { $0.id == pendingMessageID }
    }

    private func markPendingOutgoingFailed(_ pendingMessageID: UUID, errorMessage: String) {
        guard let index = pendingOutgoingMessages.firstIndex(where: { $0.id == pendingMessageID }) else {
            return
        }

        pendingOutgoingMessages[index].status = .failed
        pendingOutgoingMessages[index].errorMessage = errorMessage
    }

    private func markPendingOutgoingSending(_ pendingMessageID: UUID) {
        guard let index = pendingOutgoingMessages.firstIndex(where: { $0.id == pendingMessageID }) else {
            return
        }

        pendingOutgoingMessages[index].status = .sending
        pendingOutgoingMessages[index].errorMessage = nil
    }

    private func makeAttachmentDraft(from fileURL: URL) throws -> AttachmentDraft {
        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        let fileName = resourceValues.name ?? fileURL.lastPathComponent
        let mimeType = resourceValues.contentType?.preferredMIMEType ??
            UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ??
            "application/octet-stream"
        let sizeBytes = UInt64(resourceValues.fileSize ?? 0)

        var widthPx: UInt32?
        var heightPx: UInt32?
        if mimeType.hasPrefix("image/"),
           let image = NSImage(contentsOf: fileURL) {
            widthPx = UInt32(max(image.size.width.rounded(), 0))
            heightPx = UInt32(max(image.size.height.rounded(), 0))
        }

        return AttachmentDraft(
            fileURL: fileURL,
            fileName: fileName,
            mimeType: mimeType,
            widthPx: widthPx,
            heightPx: heightPx,
            fileSizeBytes: sizeBytes
        )
    }

    private func sendAttachmentPayload(
        client: TrixAPIClient,
        accessToken: String,
        storePaths: WorkspaceStorePaths,
        identity: DeviceIdentityMaterial,
        senderAccountID: UUID,
        senderDeviceID: UUID,
        chatId: UUID,
        draft: AttachmentDraft
    ) async throws {
        let payload = try Data(contentsOf: draft.fileURL)
        let uploaded = try await client.uploadAttachment(
            accessToken: accessToken,
            chatId: chatId,
            payload: payload,
            mimeType: draft.mimeType,
            fileName: draft.fileName,
            widthPx: draft.widthPx,
            heightPx: draft.heightPx
        )
        _ = try await client.sendMessageBody(
            accessToken: accessToken,
            databasePath: storePaths.localHistoryURL,
            statePath: storePaths.syncStateURL,
            mlsStorageRoot: storePaths.mlsStateRootURL,
            credentialIdentity: identity.storedIdentity.credentialIdentity,
            senderAccountId: senderAccountID,
            senderDeviceId: senderDeviceID,
            chatId: chatId,
            body: uploaded.body
        )
    }

    private func attachmentCacheURL(for messageId: UUID, body: TypedMessageBody) throws -> URL {
        let storePaths = try workspaceStorePaths()
        let fileName = body.fileName?.nonEmptyTrimmed ?? "\(messageId.uuidString).bin"
        return storePaths.attachmentsRootURL.appending(path: "\(messageId.uuidString)-\(fileName)")
    }

    private func presentAttachment(url: URL, body: TypedMessageBody) {
        if LocalImageAttachmentSupport.supports(mimeType: body.mimeType, fileName: body.fileName ?? url.lastPathComponent) {
            previewedAttachment = PreviewedAttachmentFile(
                fileURL: url,
                fileName: body.fileName?.nonEmptyTrimmed ?? url.lastPathComponent,
                mimeType: body.mimeType
            )
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func conversationSafeMessage(_ rawMessage: String) -> String {
        let lowercased = rawMessage.lowercased()
        if lowercased.contains("epoch") ||
            lowercased.contains("mls") ||
            lowercased.contains("projected") ||
            lowercased.contains("group state") ||
            lowercased.contains("conversation material") {
            return "Couldn't send this message right now. Try again in a moment."
        }

        return rawMessage
    }

    private func logInfo(_ category: String, _ message: String) {
        SafeDiagnosticLogStore.shared.info(category, message)
    }

    private func logWarn(_ category: String, _ message: String, error: Error? = nil) {
        SafeDiagnosticLogStore.shared.warn(category, message, error: error)
    }

    private func shortLogID(_ value: UUID) -> String {
        String(value.uuidString.prefix(8)).lowercased()
    }

    private func logChatType(_ value: ChatType) -> String {
        switch value {
        case .dm:
            return "dm"
        case .group:
            return "group"
        case .accountSync:
            return "account_sync"
        }
    }

    private func markSelectedChatReadIfNeeded(
        client: TrixAPIClient,
        accountId: UUID,
        chatId: UUID,
        timelineItems: [LocalTimelineItem]
    ) async throws {
        guard let latestServerSeq = timelineItems.last?.serverSeq else {
            return
        }

        if let selectedChatReadState,
           selectedChatReadState.unreadCount == 0,
           selectedChatReadState.readCursorServerSeq >= latestServerSeq {
            return
        }

        let storePaths = try workspaceStorePaths(for: accountId)
        let updatedReadState = try await client.markLocalChatRead(
            databasePath: storePaths.localHistoryURL,
            chatId: chatId,
            throughServerSeq: latestServerSeq,
            selfAccountId: accountId
        )
        selectedChatReadState = updatedReadState

        if let existingIndex = localChatListItems.firstIndex(where: { $0.chatId == chatId }) {
            let existingItem = localChatListItems[existingIndex]
            localChatListItems[existingIndex] = LocalChatListItem(
                chatId: existingItem.chatId,
                chatType: existingItem.chatType,
                title: existingItem.title,
                displayTitle: existingItem.displayTitle,
                lastServerSeq: existingItem.lastServerSeq,
                epoch: existingItem.epoch,
                pendingMessageCount: existingItem.pendingMessageCount,
                unreadCount: updatedReadState.unreadCount,
                previewText: existingItem.previewText,
                previewSenderAccountId: existingItem.previewSenderAccountId,
                previewSenderDisplayName: existingItem.previewSenderDisplayName,
                previewIsOutgoing: existingItem.previewIsOutgoing,
                previewServerSeq: existingItem.previewServerSeq,
                previewCreatedAtUnix: existingItem.previewCreatedAtUnix,
                participantProfiles: existingItem.participantProfiles
            )
        }
    }

    private func mergeInboxItems(_ newItems: [InboxItem], autoAdvanceCursor: Bool) {
        guard !newItems.isEmpty else {
            return
        }

        var mergedByID = Dictionary(uniqueKeysWithValues: inboxItems.map { ($0.inboxId, $0) })
        for item in newItems {
            mergedByID[item.inboxId] = item
        }

        let merged = mergedByID.values.sorted { $0.inboxId < $1.inboxId }
        inboxItems = merged

        if let maxInboxId = merged.last?.inboxId {
            lastInboxCursor = max(lastInboxCursor ?? 0, maxInboxId)
            if autoAdvanceCursor {
                inboxLeaseDraft.afterInboxID = String(maxInboxId)
            }
        }
    }

    private func removeAckedInboxItems(_ ackedInboxIDs: [UInt64]) {
        guard !ackedInboxIDs.isEmpty else {
            return
        }

        let acked = Set(ackedInboxIDs)
        inboxItems.removeAll { acked.contains($0.inboxId) }
        lastAckedInboxIDs = ackedInboxIDs.sorted()
    }

    private func defaultInboxLeaseOwner(for deviceId: UUID) -> String {
        let prefix = String(deviceId.uuidString.prefix(8)).lowercased()
        return "macos-alpha:\(prefix)"
    }

    private func normalizeCreateChatSelectionForType() {
        if createChatDraft.chatType == .dm,
           createChatDraft.selectedParticipants.count > 1 {
            createChatDraft.selectedParticipants = Array(createChatDraft.selectedParticipants.prefix(1))
        }
    }
}

enum OnboardingMode: String {
    case createAccount
    case linkExisting

    var title: String {
        switch self {
        case .createAccount:
            return "Create First Account"
        case .linkExisting:
            return "Link Existing Account"
        }
    }
}

struct OnboardingDraft {
    var profileName = ""
    var handle = ""
    var profileBio = ""
    var deviceDisplayName: String
}

struct LinkDeviceDraft {
    var linkPayload = ""
    var deviceDisplayName: String
}

struct CreateChatDraft {
    var chatType: ChatType = .dm
    var title = ""
    var directoryQuery = ""
    var selectedParticipants: [DirectoryAccountSummary] = []
}

struct EditProfileDraft {
    var handle = ""
    var profileName = ""
    var profileBio = ""
}

enum KeyPackageReserveMode: String {
    case allActiveDevices
    case selectedDevices

    var title: String {
        switch self {
        case .allActiveDevices:
            return "All Active Devices"
        case .selectedDevices:
            return "Selected Devices"
        }
    }
}

struct KeyPackagePublishDraft {
    var packagesJSON = """
    [
      {
        "cipher_suite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
        "key_package_b64": ""
      }
    ]
    """
}

struct KeyPackageReserveDraft {
    var accountID = ""
    var selectedDeviceIDs = ""
    var mode: KeyPackageReserveMode = .allActiveDevices
}

struct InboxLeaseDraft {
    static let defaultLimit = 50
    static let defaultLeaseTTLSeconds: UInt64 = 30

    var afterInboxID = ""
    var limit = String(defaultLimit)
    var leaseOwner = ""
    var leaseTTLSeconds = String(defaultLeaseTTLSeconds)
}

struct InboxLeaseState {
    let owner: String
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

private struct InboxPollParameters {
    let afterInboxId: UInt64?
    let limit: Int
    let leaseOwner: String?
    let leaseTtlSeconds: UInt64
}

enum SelectedChatReconciliationAction: Equatable {
    case keep
    case clear
    case load(UUID)
}

enum SelectedChatLoadMode {
    case replaceVisibleState
    case preserveVisibleState

    var shouldResetVisibleState: Bool {
        self == .replaceVisibleState
    }
}

enum WorkspaceSelectionPreference: Equatable {
    case automatic
    case prefer(UUID)
    case force(UUID)
}

func selectedChatReconciliationAction(
    selectedChatID: UUID?,
    visibleChatIDs: [UUID],
    changedChatIDs: Set<UUID>
) -> SelectedChatReconciliationAction {
    let firstVisibleChatID = visibleChatIDs.first

    guard let selectedChatID else {
        return .keep
    }

    guard visibleChatIDs.contains(selectedChatID) else {
        if let firstVisibleChatID {
            return .load(firstVisibleChatID)
        }

        return .clear
    }

    if changedChatIDs.contains(selectedChatID) {
        return .load(selectedChatID)
    }

    return .keep
}

func resolvedWorkspaceSelectedChatID(
    selectionPreference: WorkspaceSelectionPreference,
    currentSelectedChatID: UUID?,
    visibleLocalChatIDs: [UUID],
    serverChatIDs: [UUID]
) -> UUID? {
    let automaticSelection: UUID? = {
        if let currentSelectedChatID,
           visibleLocalChatIDs.contains(currentSelectedChatID) {
            return currentSelectedChatID
        }
        if let firstVisibleChatID = visibleLocalChatIDs.first {
            return firstVisibleChatID
        }
        if let currentSelectedChatID,
           serverChatIDs.contains(currentSelectedChatID) {
            return currentSelectedChatID
        }
        return serverChatIDs.first
    }()

    switch selectionPreference {
    case .automatic:
        return automaticSelection
    case let .prefer(chatId):
        if visibleLocalChatIDs.contains(chatId) || serverChatIDs.contains(chatId) {
            return chatId
        }
        return automaticSelection
    case let .force(chatId):
        return chatId
    }
}

struct DeviceLinkIntentState: Identifiable {
    let id = UUID()
    let payload: String
    let expiresAt: Date
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Error {
    var userFacingMessage: String {
        if let localizedError = self as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return localizedDescription
    }
}

private extension TrixAPIError {
    var suggestsPendingLinkReset: Bool {
        guard case let .server(code, message, _) = self else {
            return false
        }

        let combined = "\(code) \(message)".lowercased()
        return combined.contains("revoked") || combined.contains("deleted")
    }
}
