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
    @Published var syncStateSnapshot: SyncStateSnapshot?
    @Published var historySyncJobs: [HistorySyncJobSummary] = []
    @Published var historySyncCursorDrafts: [UUID: String] = [:]
    @Published var historySyncChunkDrafts: [UUID: HistorySyncChunkDraft] = [:]
    @Published var historySyncChunksByJobID: [UUID: [HistorySyncChunkSummary]] = [:]
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
    @Published var selectedChatReadCursor: UInt64?
    @Published var selectedChatUnreadCount: UInt64?
    @Published var selectedChatSyncCursor: UInt64?
    @Published var selectedChatTimelineItems: [LocalTimelineItem] = []
    @Published var selectedChatProjectedCursor: UInt64?
    @Published var selectedChatProjectedMessages: [LocalProjectedMessage] = []
    @Published var selectedChatHistory: [MessageEnvelope] = []
    @Published var selectedChatMlsDiagnostics: LocalChatMlsDiagnostics?
    @Published var mlsSignaturePublicKeyFingerprint: String?
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
    @Published private(set) var storedSessionRecoveryMode: StoredSessionRecoveryMode = .reconnect
    @Published var isRefreshingWorkspace = false
    @Published var isRefreshingDevices = false
    @Published var isCreatingChat = false
    @Published var isSearchingAccountDirectory = false
    @Published var isUpdatingProfile = false
    @Published var isSendingMessage = false
    @Published var isRefreshingHistorySyncJobs = false
    @Published var isLoadingSelectedChat = false
    @Published var revokingDeviceIDs: Set<UUID> = []
    @Published var approvingDeviceIDs: Set<UUID> = []
    @Published var completingHistorySyncJobIDs: Set<UUID> = []
    @Published var loadingHistorySyncChunkJobIDs: Set<UUID> = []
    @Published var appendingHistorySyncChunkJobIDs: Set<UUID> = []
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
    private let importedAttachmentStore: ImportedAttachmentStore
    private let defaultDeviceName: String
    private var persistedSession: PersistedSession?
    private var accessToken: String?
    private var apnsTokenHex: String?
    private var messengerCheckpoint: String?
    private var didStart = false
    private var backgroundRefreshTask: Task<Void, Never>?
    private var foregroundRealtimeTask: Task<Void, Never>?
    private var linkIntentRefreshTask: Task<Void, Never>?
    private var foregroundRealtimeTaskID: UUID?
    private var foregroundRealtimeAccessToken: String?
    private var foregroundRealtimeBaseURLString: String?
    private var foregroundRealtimeAccountID: UUID?
    private var typingChatID: UUID?
    private var isTypingActive = false
    private var hasScheduledRealtimeRecovery = false
    private var isApplicationActive = true
    private static let foregroundRealtimePollIntervalNanoseconds: UInt64 = 750_000_000
    private static let foregroundRealtimeRetryDelayNanoseconds: UInt64 = 3_000_000_000
    private static let linkIntentRefreshIntervalNanoseconds: UInt64 = 3_000_000_000
    private var linkIntentPendingBaselineIDs: Set<UUID> = []

    init(
        sessionStore: SessionStore = SessionStore(),
        keychainStore: KeychainStore = KeychainStore(),
        notificationPreferencesStore: NotificationPreferencesStore = NotificationPreferencesStore(),
        notificationCoordinator: LocalNotificationCoordinator = LocalNotificationCoordinator.makeDefault(),
        importedAttachmentStore: ImportedAttachmentStore = ImportedAttachmentStore()
    ) {
        self.sessionStore = sessionStore
        self.keychainStore = keychainStore
        self.notificationPreferencesStore = notificationPreferencesStore
        self.notificationCoordinator = notificationCoordinator
        self.importedAttachmentStore = importedAttachmentStore

        let defaultDeviceName = Host.current().localizedName ?? "This Mac"
        self.defaultDeviceName = defaultDeviceName
        self.serverBaseURLString = "https://trix.artelproject.tech"
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
        foregroundRealtimeTask?.cancel()
        linkIntentRefreshTask?.cancel()
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

    var supportsSafeConversationMemberRemoval: Bool {
        true
    }

    var supportsSafeConversationDeviceRemoval: Bool {
        true
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
        registerForRemoteNotificationsIfNeeded()
        startBackgroundRefreshLoopIfNeeded()

        if persistedSession != nil {
            let uiTestConfig = MacUITestLaunchConfiguration.current
            let skipInitialRestore = uiTestConfig.isEnabled
                && (uiTestConfig.seedScenario == .restoreSession || uiTestConfig.seedScenario == .pendingApproval)
            if !skipInitialRestore {
                await restoreSession()
            }
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

    func clearServerStatus() {
        health = nil
        version = nil
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive

        if isActive {
            Task {
                await refreshNotificationPermissionState()
                if outgoingLinkIntent != nil {
                    await refreshDevices(showProgress: false, suppressErrors: true)
                }
                if accessToken != nil {
                    restartForegroundRealtimeLoopIfNeeded()
                    if foregroundRealtimeTask == nil {
                        await refreshMessengerEvents(
                            postNotifications: false,
                            suppressErrors: true
                        )
                    }
                } else {
                    await restoreSession()
                }
            }
        } else {
            stopForegroundRealtimeLoop()
        }
    }

    func handleRegisteredForRemoteNotifications(deviceToken: Data) async {
        apnsTokenHex = apnsTokenHexString(from: deviceToken)
        await syncApplePushTokenIfPossible()
    }

    func handleRemoteNotificationsRegistrationFailure(_ error: Error) {
        lastErrorMessage = error.userFacingMessage
    }

    func handleRemoteNotification(userInfo: [String: Any]) async {
        guard isTrixInboxRemoteNotification(userInfo) else {
            return
        }
        guard notificationPreferences.isEnabled else {
            return
        }

        await performBackgroundRefreshIfNeeded()
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        notificationPreferences.isEnabled = isEnabled
        notificationPreferencesStore.save(notificationPreferences)

        if isEnabled {
            registerForRemoteNotificationsIfNeeded()
            Task {
                await syncApplePushTokenIfPossible()
            }
        } else {
            Task {
                await deleteApplePushTokenIfPossible()
            }
        }
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
                registerForRemoteNotificationsIfNeeded()
                await syncApplePushTokenIfPossible()
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
            let draft = try makeAttachmentDraft(from: fileURL)
            cleanupImportedComposerAttachmentIfNeeded(replacingWith: draft)
            composerAttachmentDraft = draft
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func clearComposerAttachment() {
        cleanupImportedComposerAttachmentIfNeeded()
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
        guard let attachmentRef = body.attachmentRef?.nonEmptyTrimmed else {
            if reportErrors {
                lastErrorMessage = "Attachment reference is missing."
            }
            return nil
        }

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let file = try await messenger.getAttachment(attachmentRef: attachmentRef)
            cachedAttachmentURLs[message.messageId] = file.localURL
            return file.localURL
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

        isCreatingLinkIntent = true
        lastErrorMessage = nil
        defer { isCreatingLinkIntent = false }

        do {
            stopLinkIntentRefreshLoop()
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let response = try await messenger.createLinkDeviceIntent()
            let baselineDevices = try await messenger.listDevices()
            linkIntentPendingBaselineIDs = pendingDeviceIDs(in: baselineDevices)
            applyLoadedDevices(baselineDevices)
            outgoingLinkIntent = DeviceLinkIntentState(
                payload: response.payload,
                expiresAt: response.expiresAt
            )
            startLinkIntentRefreshLoop()
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    func refreshDevices() async {
        await refreshDevices(showProgress: true, suppressErrors: false)
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
            let identity = try DeviceIdentityMaterial.makeLinkedDevice(
                deviceDisplayName: deviceDisplayName,
                platform: DeviceIdentityMaterial.platform
            )
            let messenger = try makeMessengerClient(
                baseURLString: payload.baseURL,
                accountId: payload.accountId,
                deviceDisplayName: deviceDisplayName,
                identity: identity
            )
            let response = try await messenger.completeLinkDevice(
                linkPayload: linkDraft.linkPayload,
                deviceDisplayName: deviceDisplayName
            )

            serverBaseURLString = payload.baseURL
            draft.deviceDisplayName = deviceDisplayName

            let session = PersistedSession(
                baseURLString: payload.baseURL,
                accountId: response.accountId,
                deviceId: response.deviceId,
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
        storedSessionRecoveryMode = .reconnect
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
            var resolvedIdentity = identity

            if !identity.hasAccountRootKey, authSession.deviceStatus == .active {
                do {
                    let imported = try await importTransferredAccountRootIfAvailable(
                        client: client,
                        accessToken: authSession.accessToken,
                        session: updatedSession,
                        identity: identity
                    )
                    resolvedIdentity = imported.identity
                    updatedSession.accountSyncChatId = imported.accountSyncChatId ?? updatedSession.accountSyncChatId
                } catch {
                    logWarn(
                        "auth",
                        "restore_session account-root import failed device=\(shortLogID(session.deviceId))",
                        error: error
                    )
                }
            }

            try save(identity: resolvedIdentity, authSession: authSession, persistedSession: updatedSession)
            try await loadWorkspace(client: client, accessToken: authSession.accessToken)
            logInfo(
                "auth",
                "restore_session success device=\(shortLogID(session.deviceId)) status=\(authSession.deviceStatus.label.lowercased())"
            )
        } catch let error as TrixAPIError {
            logWarn("auth", "restore_session failed device=\(shortLogID(session.deviceId))", error: error)
            if error.isTransportFailure,
               session.deviceStatus == .active,
               await restoreWorkspaceFromLocalCacheIfPossible(session: session) {
                disconnectRealtimeConnection()
                accessToken = nil
                serverBaseURLString = session.baseURLString
                draft.profileName = session.profileName
                draft.handle = session.handle ?? ""
                draft.deviceDisplayName = session.deviceDisplayName
                linkDraft.deviceDisplayName = session.deviceDisplayName
                refreshLocalIdentityState(reportErrors: false)
                lastErrorMessage = preservedRestoreFailureMessage(for: error)
                return
            }
            switch sessionRestoreErrorDisposition(deviceStatus: session.deviceStatus, error: error) {
            case .restartPendingLink:
                disconnectRealtimeConnection()
                restartPendingLinkFlow(
                    baseURLString: session.baseURLString,
                    deviceDisplayName: session.deviceDisplayName,
                    errorMessage: "This linked-device session is no longer available on the server. Start the link flow again on this Mac."
                )
            case .preservePendingSession:
                disconnectRealtimeConnection()
                accessToken = nil
                clearWorkspaceData()
                refreshLocalIdentityState(reportErrors: false)
                lastErrorMessage = "This device is still pending approval. Approve it from any active trusted device in the device directory, then reconnect. If that link was rejected or revoked, restart the link flow on this Mac."
            case .preserveActiveSession:
                disconnectRealtimeConnection()
                accessToken = nil
                serverBaseURLString = session.baseURLString
                draft.profileName = session.profileName
                draft.handle = session.handle ?? ""
                draft.deviceDisplayName = session.deviceDisplayName
                linkDraft.deviceDisplayName = session.deviceDisplayName
                refreshLocalIdentityState(reportErrors: false)
                lastErrorMessage = preservedRestoreFailureMessage(for: error)
            case .preserveActiveSessionRequiresRelink:
                disconnectRealtimeConnection()
                accessToken = nil
                serverBaseURLString = session.baseURLString
                draft.profileName = session.profileName
                draft.handle = session.handle ?? ""
                draft.deviceDisplayName = session.deviceDisplayName
                linkDraft.deviceDisplayName = session.deviceDisplayName
                refreshLocalIdentityState(reportErrors: false)
                storedSessionRecoveryMode = .relinkRequired
                lastErrorMessage = relinkRequiredRestoreFailureMessage(for: error)
            case .surface:
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
                "workspace_refresh success chats=\(chats.count) devices=\(devices.count)"
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

        isCreatingChat = true
        lastErrorMessage = nil
        defer { isCreatingChat = false }

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
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
            let created = try await messenger.createConversation(
                chatType: createChatDraft.chatType,
                title: createChatDraft.title.nonEmptyTrimmed,
                participantAccountIds: uniqueParticipants
            )

            resetCreateChatComposer()
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .force(created.conversationId)
            )
            logInfo(
                "chat",
                "create_chat success chat=\(shortLogID(created.conversationId)) epoch=\(created.conversation?.epoch ?? 0)"
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

    func sendMessage(draftText: String, pendingMessageID: UUID? = nil) async -> Bool {
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
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            if let attachmentDraft = composerAttachmentDraft {
                let pendingAttachment = pendingMessageID ?? enqueuePendingOutgoing(
                    chatId: chatId,
                    payload: .attachment(attachmentDraft)
                )
                do {
                    let payload = try Data(contentsOf: attachmentDraft.fileURL)
                    let attachmentToken = try await messenger.sendAttachment(
                        conversationId: chatId,
                        payload: payload,
                        mimeType: attachmentDraft.mimeType,
                        fileName: attachmentDraft.fileName,
                        widthPx: attachmentDraft.widthPx,
                        heightPx: attachmentDraft.heightPx
                    )
                    _ = try await messenger.sendMessage(
                        conversationId: chatId,
                        body: TypedMessageBody(
                            kind: .attachment,
                            text: nil,
                            targetMessageId: nil,
                            emoji: nil,
                            reactionAction: nil,
                            receiptType: nil,
                            receiptAtUnix: nil,
                            attachmentRef: nil,
                            blobId: nil,
                            mimeType: attachmentDraft.mimeType,
                            sizeBytes: attachmentDraft.fileSizeBytes,
                            sha256: nil,
                            fileName: attachmentDraft.fileName,
                            widthPx: attachmentDraft.widthPx,
                            heightPx: attachmentDraft.heightPx,
                            fileKey: nil,
                            nonce: nil,
                            eventType: nil,
                            eventJson: nil
                        ),
                        messageId: pendingAttachment,
                        attachmentTokens: [attachmentToken]
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
                let pendingText = pendingMessageID ?? enqueuePendingOutgoing(
                    chatId: chatId,
                    payload: .text(trimmedText)
                )
                do {
                    _ = try await messenger.sendMessage(
                        conversationId: chatId,
                        body: .text(trimmedText),
                        messageId: pendingText
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
            cleanupImportedComposerAttachmentIfNeeded()
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

    func sendReaction(targetMessageID: UUID, emoji: String, removeExisting: Bool) async -> Bool {
        guard !isSendingMessage else {
            lastErrorMessage = "Дождись завершения текущей отправки."
            return false
        }
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

        let trimmedEmoji = emoji.nonEmptyTrimmed
        guard let trimmedEmoji else {
            return false
        }

        isSendingMessage = true
        lastErrorMessage = nil
        defer { isSendingMessage = false }

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            _ = try await messenger.sendMessage(
                conversationId: chatId,
                body: TypedMessageBody(
                    kind: .reaction,
                    text: nil,
                    targetMessageId: targetMessageID,
                    emoji: trimmedEmoji,
                    reactionAction: removeExisting ? .remove : .add,
                    receiptType: nil,
                    receiptAtUnix: nil,
                    attachmentRef: nil,
                    blobId: nil,
                    mimeType: nil,
                    sizeBytes: nil,
                    sha256: nil,
                    fileName: nil,
                    widthPx: nil,
                    heightPx: nil,
                    fileKey: nil,
                    nonce: nil,
                    eventType: nil,
                    eventJson: nil
                )
            )

            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            return true
        } catch let error as TrixAPIError {
            logWarn("message", "send_reaction failed chat=\(shortLogID(chatId))", error: error)
            if error.isCredentialFailure {
                accessToken = nil
                await restoreSession()
            } else {
                lastErrorMessage = conversationSafeMessage(error.userFacingMessage)
            }
        } catch {
            logWarn("message", "send_reaction failed chat=\(shortLogID(chatId))", error: error)
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

        switch pendingMessage.payload {
        case let .text(text):
            cleanupImportedComposerAttachmentIfNeeded()
            composerAttachmentDraft = nil
            _ = await sendMessage(draftText: text, pendingMessageID: pendingMessageID)
        case let .attachment(attachmentDraft):
            cleanupImportedComposerAttachmentIfNeeded(replacingWith: attachmentDraft)
            composerAttachmentDraft = attachmentDraft
            _ = await sendMessage(draftText: "", pendingMessageID: pendingMessageID)
        }
    }

    func discardPendingOutgoingMessage(_ pendingMessageID: UUID) {
        if let pendingMessage = pendingOutgoingMessages.first(where: { $0.id == pendingMessageID }),
           case let .attachment(attachmentDraft) = pendingMessage.payload,
           composerAttachmentDraft?.fileURL != attachmentDraft.fileURL {
            importedAttachmentStore.removeImportedFileIfOwned(at: attachmentDraft.fileURL)
        }
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
        guard let client = makeClient(),
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
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let outcome = try await messenger.updateConversationMembers(
                conversationId: chatId,
                participantAccountIds: participantAccountIDs
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "membership",
                "add_members success chat=\(shortLogID(chatId)) changed=\(outcome.changedParticipantAccountIDs.count) epoch=\(outcome.conversation?.epoch ?? 0)"
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
        guard let client = makeClient(),
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        removingChatMemberAccountIDs.insert(participantAccountID)
        defer { removingChatMemberAccountIDs.remove(participantAccountID) }

        do {
            logInfo(
                "membership",
                "remove_members start chat=\(shortLogID(chatId)) count=1"
            )
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let outcome = try await messenger.removeConversationMembers(
                conversationId: chatId,
                participantAccountIds: [participantAccountID]
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "membership",
                "remove_members success chat=\(shortLogID(chatId)) changed=\(outcome.changedParticipantAccountIDs.count) epoch=\(outcome.conversation?.epoch ?? 0)"
            )
        } catch {
            logWarn("membership", "remove_members failed chat=\(shortLogID(chatId))", error: error)
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
        guard let client = makeClient(),
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
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let outcome = try await messenger.updateConversationDevices(
                conversationId: chatId,
                deviceIds: deviceIDs
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "devices",
                "add_devices success chat=\(shortLogID(chatId)) changed=\(outcome.changedDeviceIDs.count) epoch=\(outcome.conversation?.epoch ?? 0)"
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
        guard let client = makeClient(),
              let chatId = selectedChatID else {
            lastErrorMessage = "Чат или устройство ещё не загружены."
            return
        }

        removingChatDeviceIDs.insert(deviceID)
        defer { removingChatDeviceIDs.remove(deviceID) }

        do {
            logInfo(
                "devices",
                "remove_devices start chat=\(shortLogID(chatId)) count=1"
            )
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let outcome = try await messenger.removeConversationDevices(
                conversationId: chatId,
                deviceIds: [deviceID]
            )
            try await loadWorkspace(
                client: client,
                accessToken: token,
                selectionPreference: .prefer(chatId)
            )
            logInfo(
                "devices",
                "remove_devices success chat=\(shortLogID(chatId)) changed=\(outcome.changedDeviceIDs.count) epoch=\(outcome.conversation?.epoch ?? 0)"
            )
        } catch {
            logWarn("devices", "remove_devices failed chat=\(shortLogID(chatId))", error: error)
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

    func refreshHistorySyncChunks(for jobID: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        loadingHistorySyncChunkJobIDs.insert(jobID)
        defer { loadingHistorySyncChunkJobIDs.remove(jobID) }

        do {
            historySyncChunksByJobID[jobID] = try await client.fetchHistorySyncChunks(
                accessToken: token,
                jobId: jobID
            )
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

    func appendHistorySyncChunk(_ jobID: UUID) async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }
        guard let draft = historySyncChunkDrafts[jobID] else {
            return
        }

        appendingHistorySyncChunkJobIDs.insert(jobID)
        defer { appendingHistorySyncChunkJobIDs.remove(jobID) }

        do {
            let payload = try decodeBase64Data(
                draft.payloadB64,
                label: "history sync payload"
            )
            let cursorJSON = try decodeCursorJSON(draft.cursorJSON)
            let sequenceNo = try decodeUInt64(
                draft.sequenceNo,
                label: "history sync sequence"
            )
            _ = try await client.appendHistorySyncChunk(
                accessToken: token,
                jobId: jobID,
                sequenceNo: sequenceNo,
                payload: payload,
                cursorJson: cursorJSON,
                isFinal: draft.isFinal
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

        approvingDeviceIDs.insert(device.deviceId)
        lastErrorMessage = nil
        defer { approvingDeviceIDs.remove(device.deviceId) }

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let result = try await messenger.approveLinkedDevice(deviceId: device.deviceId)
            applyLoadedDevices(result.devices)
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
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let result = try await messenger.revokeDevice(deviceId: device.deviceId)
            applyLoadedDevices(result.devices)
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

    func setSelectedChatReadCursor(_ readCursorServerSeq: UInt64?) async {
        guard let selectedChatID else {
            return
        }

        do {
            let messenger = try makeAuthenticatedMessenger()
            let throughMessageId = readCursorServerSeq.flatMap { cursor in
                selectedChatTimelineItems.last(where: { $0.serverSeq <= cursor })?.messageId ??
                    selectedChatTimelineItems.last?.messageId
            }
            let updatedReadState = try await messenger.markRead(
                conversationId: selectedChatID,
                throughMessageId: throughMessageId
            )
            applySelectedChatReadState(updatedReadState)
        } catch {
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

    private func ensureApplePushDeliveryConfigured(
        client: TrixAPIClient,
        accessToken: String
    ) async {
        guard notificationPreferences.isEnabled else {
            await deleteApplePushTokenIfPossible()
            return
        }

        registerForRemoteNotificationsIfNeeded()
        guard let tokenHex = apnsTokenHex else {
            return
        }

        do {
            _ = try await client.registerApplePushToken(
                accessToken: accessToken,
                request: RegisterApplePushTokenRequest(
                    tokenHex: tokenHex,
                    environment: ApplePushRegistrationEnvironment.current
                )
            )
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    private func syncApplePushTokenIfPossible() async {
        guard notificationPreferences.isEnabled else {
            return
        }
        guard let tokenHex = apnsTokenHex else {
            return
        }
        guard let accessToken else {
            return
        }
        guard let client = makeClient() else {
            return
        }

        do {
            _ = try await client.registerApplePushToken(
                accessToken: accessToken,
                request: RegisterApplePushTokenRequest(
                    tokenHex: tokenHex,
                    environment: ApplePushRegistrationEnvironment.current
                )
            )
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    private func deleteApplePushTokenIfPossible() async {
        guard let accessToken else {
            return
        }
        guard let client = makeClient() else {
            return
        }

        do {
            try await client.deleteApplePushToken(accessToken: accessToken)
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
    }

    private func registerForRemoteNotificationsIfNeeded() {
        guard notificationPreferences.isEnabled else {
            return
        }

        switch notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            NSApplication.shared.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        case .notDetermined, .denied:
            break
        }
    }

    private func makeMessengerConfiguration(
        baseURLString: String? = nil,
        accessToken: String? = nil,
        accountId: UUID? = nil,
        deviceId: UUID? = nil,
        accountSyncChatId: UUID? = nil,
        deviceDisplayName: String? = nil,
        identity: DeviceIdentityMaterial? = nil
    ) throws -> TrixMessengerClient.Configuration {
        let rawBaseURL = baseURLString ?? persistedSession?.baseURLString ?? serverBaseURLString
        guard let normalizedBaseURL = ServerEndpoint.normalizedURL(from: rawBaseURL)?.absoluteString else {
            throw TrixAPIError.invalidPayload("Не удалось разобрать URL сервера.")
        }

        let resolvedAccountID = accountId ?? currentAccount?.accountId ?? persistedSession?.accountId
        guard let resolvedAccountID else {
            throw TrixAPIError.invalidPayload("Аккаунт ещё не загружен.")
        }

        let storePaths = try workspaceStorePaths(for: resolvedAccountID)
        let storedIdentity = identity?.storedIdentity

        return try TrixMessengerClient(
            workspaceRoot: storePaths.rootURL,
            baseURL: normalizedBaseURL,
            accessToken: accessToken ?? self.accessToken,
            accountId: accountId ?? currentAccount?.accountId ?? persistedSession?.accountId,
            deviceId: deviceId ?? currentDeviceID,
            accountSyncChatId: accountSyncChatId ?? persistedSession?.accountSyncChatId,
            deviceDisplayName: deviceDisplayName ?? persistedSession?.deviceDisplayName ?? draft.deviceDisplayName,
            platform: storedIdentity != nil ? DeviceIdentityMaterial.platform : nil,
            credentialIdentity: storedIdentity?.credentialIdentity,
            accountRootPrivateKey: storedIdentity?.accountRootSeed,
            transportPrivateKey: storedIdentity?.transportSeed
        ).configuration
    }

    private func makeMessengerClient(
        baseURLString: String? = nil,
        accessToken: String? = nil,
        accountId: UUID? = nil,
        deviceId: UUID? = nil,
        accountSyncChatId: UUID? = nil,
        deviceDisplayName: String? = nil,
        identity: DeviceIdentityMaterial? = nil
    ) throws -> TrixMessengerClient {
        TrixMessengerClient(
            configuration: try makeMessengerConfiguration(
                baseURLString: baseURLString,
                accessToken: accessToken,
                accountId: accountId,
                deviceId: deviceId,
                accountSyncChatId: accountSyncChatId,
                deviceDisplayName: deviceDisplayName,
                identity: identity
            )
        )
    }

    private func makeAuthenticatedMessenger(accessToken: String? = nil) throws -> TrixMessengerClient {
        try makeMessengerClient(
            accessToken: accessToken ?? self.accessToken,
            identity: try loadStoredIdentity()
        )
    }

    private func applySelectedChatReadState(_ readState: LocalChatReadState) {
        selectedChatReadState = readState
        selectedChatReadCursor = readState.readCursorServerSeq
        selectedChatUnreadCount = readState.unreadCount

        guard let existingIndex = localChatListItems.firstIndex(where: { $0.chatId == readState.chatId }) else {
            return
        }

        let existingItem = localChatListItems[existingIndex]
        localChatListItems[existingIndex] = LocalChatListItem(
            chatId: existingItem.chatId,
            chatType: existingItem.chatType,
            title: existingItem.title,
            displayTitle: existingItem.displayTitle,
            lastServerSeq: existingItem.lastServerSeq,
            epoch: existingItem.epoch,
            pendingMessageCount: existingItem.pendingMessageCount,
            unreadCount: readState.unreadCount,
            previewText: existingItem.previewText,
            previewSenderAccountId: existingItem.previewSenderAccountId,
            previewSenderDisplayName: existingItem.previewSenderDisplayName,
            previewIsOutgoing: existingItem.previewIsOutgoing,
            previewServerSeq: existingItem.previewServerSeq,
            previewCreatedAtUnix: existingItem.previewCreatedAtUnix,
            participantProfiles: existingItem.participantProfiles
        )
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

    private func disconnectRealtimeConnection() {
        stopForegroundRealtimeLoop()
    }

    func updateTypingState(for chatID: UUID?, draftText: String) {
        let normalizedDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let desiredChatID = normalizedDraft.isEmpty ? nil : chatID
        let desiredIsTyping = desiredChatID != nil

        guard typingChatID != desiredChatID || isTypingActive != desiredIsTyping else {
            return
        }

        let previousChatID = typingChatID
        let previousIsTyping = isTypingActive
        typingChatID = desiredChatID
        isTypingActive = desiredIsTyping

        Task { [weak self] in
            guard let self else {
                return
            }

            guard let accessToken = self.accessToken else {
                return
            }

            do {
                let messenger = try self.makeAuthenticatedMessenger(accessToken: accessToken)
                if previousIsTyping, let previousChatID, previousChatID != desiredChatID {
                    try await messenger.setTyping(
                        conversationId: previousChatID,
                        isTyping: false
                    )
                }

                if let desiredChatID {
                    try await messenger.setTyping(
                        conversationId: desiredChatID,
                        isTyping: desiredIsTyping
                    )
                }
            } catch {
                return
            }
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
                title: "\(currentItem.displayTitle): New message",
                body: currentItem.previewText ?? ""
            )
        }
    }

    private func isTrixInboxRemoteNotification(_ userInfo: [String: Any]) -> Bool {
        if let trixPayload = userInfo["trix"] as? [String: Any] {
            return (trixPayload["event"] as? String) == "inbox_update"
        }

        return userInfo["aps"] != nil
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

            if self.accessToken != nil {
                self.restartForegroundRealtimeLoopIfNeeded()
            } else if self.persistedSession != nil {
                await self.restoreSession()
            }
        }
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
        let loadedProfile = try await client.fetchCurrentAccount(accessToken: accessToken)
        let identity = try loadStoredIdentity()
        let messenger = try makeMessengerClient(
            baseURLString: loadedProfile.accountId == persistedSession?.accountId
                ? persistedSession?.baseURLString
                : serverBaseURLString,
            accessToken: accessToken,
            accountId: loadedProfile.accountId,
            deviceId: loadedProfile.deviceId,
            accountSyncChatId: persistedSession?.accountSyncChatId,
            deviceDisplayName: persistedSession?.deviceDisplayName,
            identity: identity
        )
        let snapshot = try await messenger.loadSnapshot()

        currentAccount = loadedProfile
        try updatePersistedSessionProfile(from: loadedProfile)
        try applyMessengerSnapshot(snapshot)
        await ensureApplePushDeliveryConfigured(client: client, accessToken: accessToken)
        refreshLocalIdentityState(reportErrors: false)
        syncKeyPackageDrafts(with: loadedProfile)
        syncEditProfileDraft(with: loadedProfile)
        try await loadHistorySyncJobs(client: client, accessToken: accessToken)
        restartForegroundRealtimeLoopIfNeeded()

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

    private func restoreWorkspaceFromLocalCacheIfPossible(session: PersistedSession) async -> Bool {
        do {
            let identity = try loadStoredIdentity()
            let messenger = try makeMessengerClient(
                baseURLString: session.baseURLString,
                accessToken: nil,
                accountId: session.accountId,
                deviceId: session.deviceId,
                accountSyncChatId: session.accountSyncChatId,
                deviceDisplayName: session.deviceDisplayName,
                identity: identity
            )
            let snapshot = try await messenger.loadSnapshot()
            currentAccount = offlineCachedAccountProfile(for: session)
            historySyncJobs = []
            try applyMessengerSnapshot(snapshot)
            return true
        } catch {
            logWarn(
                "auth",
                "restore_session local cache fallback failed device=\(shortLogID(session.deviceId))",
                error: error
            )
            return false
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
            try await populateSelectedChatTimeline(
                accessToken: accessToken,
                chatId: chatId
            )
        } catch let initialError {
            let didRecover = await recoverSelectedChatTimelineIfNeeded(
                client: client,
                accessToken: accessToken,
                chatId: chatId,
                detail: loadedDetail,
                error: initialError
            )
            guard !didRecover else {
                return
            }

            clearSelectedChatTimelineState()
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

    private func importTransferredAccountRootIfAvailable(
        client: TrixAPIClient,
        accessToken: String,
        session: PersistedSession,
        identity: DeviceIdentityMaterial
    ) async throws -> ImportedAccountRootResult {
        let bundle = try await client.fetchDeviceTransferBundle(
            accessToken: accessToken,
            deviceId: session.deviceId
        )
        return try identity.importingAccountRoot(
            fromTransferBundle: bundle.transferBundle,
            accountId: session.accountId,
            deviceId: session.deviceId,
            accountSyncChatId: session.accountSyncChatId
        )
    }

    private func loadStoredIdentity(requireAccountRoot: Bool = false) throws -> DeviceIdentityMaterial {
        let transportSeed = try keychainStore.loadData(for: .transportSeed)
        let credentialIdentity = try keychainStore.loadData(for: .credentialIdentity)
        guard let transportSeed, let credentialIdentity else {
            if let plan = missingStoredIdentityRecoveryPlan(hasPersistedSession: persistedSession != nil) {
                logWarn("auth", "stored identity material missing for persisted session; forcing local recovery mode")
                disconnectRealtimeConnection()
                accessToken = nil
                outgoingLinkIntent = nil
                clearWorkspaceData()
                storedSessionRecoveryMode = plan.mode
                refreshLocalIdentityState(reportErrors: false)
                throw TrixAPIError.invalidPayload(plan.message)
            }

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
        if let accessToken,
           let client = makeClient(baseURLString: persistedSession?.baseURLString) {
            Task {
                try? await client.deleteApplePushToken(accessToken: accessToken)
            }
        }

        disconnectRealtimeConnection()
        stopLinkIntentRefreshLoop()
        try sessionStore.clear()
        try keychainStore.removeValue(for: .accountRootSeed)
        try keychainStore.removeValue(for: .transportSeed)
        try keychainStore.removeValue(for: .credentialIdentity)
        try keychainStore.removeValue(for: .accessToken)

        persistedSession = nil
        accessToken = nil
        messengerCheckpoint = nil
        clearWorkspaceData()
        outgoingLinkIntent = nil
        keyPackagePublishDraft = KeyPackagePublishDraft()
        keyPackageReserveDraft = KeyPackageReserveDraft()
        hasAccountRootKey = false
        storedSessionRecoveryMode = .reconnect
        onboardingMode = .createAccount
        linkDraft = LinkDeviceDraft(deviceDisplayName: defaultDeviceName)
    }

    private func clearWorkspaceData() {
        stopLinkIntentRefreshLoop()
        stopForegroundRealtimeLoop()
        cleanupImportedPendingAttachmentDrafts()
        cleanupImportedComposerAttachmentIfNeeded()
        currentAccount = nil
        messengerCheckpoint = nil
        devices = []
        chats = []
        localChatListItems = []
        pendingOutgoingMessages = []
        composerAttachmentDraft = nil
        cachedAttachmentURLs = [:]
        previewedAttachment = nil
        accountDirectoryResults = []
        syncStateSnapshot = nil
        historySyncJobs = []
        historySyncCursorDrafts = [:]
        historySyncChunkDrafts = [:]
        historySyncChunksByJobID = [:]
        approvingDeviceIDs = []
        loadingHistorySyncChunkJobIDs = []
        appendingHistorySyncChunkJobIDs = []
        publishedKeyPackages = []
        reservedKeyPackages = []
        reservedKeyPackagesAccountID = nil
        mlsSignaturePublicKeyFingerprint = nil
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

    private func syncEditProfileDraft(with profile: AccountProfileResponse) {
        editProfileDraft.handle = profile.handle ?? ""
        editProfileDraft.profileName = profile.profileName
        editProfileDraft.profileBio = profile.profileBio ?? ""
    }

    private func loadHistorySyncJobs(
        client: TrixAPIClient,
        accessToken: String
    ) async throws {
        async let sourceJobs = client.fetchHistorySyncJobs(
            accessToken: accessToken,
            role: .source
        )
        async let targetJobs = client.fetchHistorySyncJobs(
            accessToken: accessToken,
            role: .target
        )
        let loadedSourceJobs = try await sourceJobs
        let loadedTargetJobs = try await targetJobs
        let mergedJobs = (loadedSourceJobs.jobs + loadedTargetJobs.jobs)
            .sorted { left, right in
                if left.updatedAtUnix == right.updatedAtUnix {
                    return left.jobId.uuidString < right.jobId.uuidString
                }
                return left.updatedAtUnix > right.updatedAtUnix
            }

        historySyncJobs = mergedJobs
        let visibleJobIDs = Set(mergedJobs.map(\.jobId))
        historySyncChunksByJobID = historySyncChunksByJobID.filter { visibleJobIDs.contains($0.key) }
        historySyncChunkDrafts = historySyncChunkDrafts.filter { visibleJobIDs.contains($0.key) }

        for job in mergedJobs {
            if historySyncCursorDrafts[job.jobId] == nil {
                historySyncCursorDrafts[job.jobId] = try encodeCursorJSON(job.cursorJson) ?? ""
            }
            if historySyncChunkDrafts[job.jobId] == nil {
                historySyncChunkDrafts[job.jobId] = HistorySyncChunkDraft()
            }
        }
    }

    private func populateSelectedChatTimeline(
        accessToken: String,
        chatId: UUID
    ) async throws {
        let messenger = try makeAuthenticatedMessenger(accessToken: accessToken)
        let timelineItems = try await messenger.getAllMessages(conversationId: chatId)
        let localChatListItem = localChatListItems.first { $0.chatId == chatId }
        let unreadCount = localChatListItem?.unreadCount ?? 0
        let inferredReadCursor: UInt64 = {
            if unreadCount == 0 {
                return timelineItems.last?.serverSeq ?? localChatListItem?.lastServerSeq ?? 0
            }
            return selectedChatReadState?.readCursorServerSeq ?? 0
        }()
        let readState = LocalChatReadState(
            chatId: chatId,
            readCursorServerSeq: inferredReadCursor,
            unreadCount: unreadCount
        )

        if let localChatListItem {
            upsertLocalChatListItem(localChatListItem)
        }
        selectedChatTimelineItems = timelineItems
        applySelectedChatReadState(readState)
        selectedChatSyncCursor = nil
        selectedChatProjectedCursor = nil
        selectedChatProjectedMessages = []
        selectedChatHistory = []
        selectedChatMlsDiagnostics = nil

        try await markSelectedChatReadIfNeeded(
            messenger: messenger,
            chatId: chatId,
            timelineItems: timelineItems
        )
    }

    private func recoverSelectedChatTimelineIfNeeded(
        client: TrixAPIClient,
        accessToken: String,
        chatId: UUID,
        detail: ChatDetailResponse,
        error: Error
    ) async -> Bool {
        guard detail.lastServerSeq > 0 else {
            return false
        }

        logWarn(
            "workspace.selected-chat",
            "Local timeline load failed for chat \(shortLogID(chatId)); refreshing messenger snapshot before retry.",
            error: error
        )

        do {
            try await refreshLocalWorkspaceCache(accessToken: accessToken)
        } catch {
            logWarn(
                "workspace.selected-chat",
                "Messenger snapshot refresh failed while recovering chat \(shortLogID(chatId)).",
                error: error
            )
            return false
        }

        do {
            try await loadHistorySyncJobs(client: client, accessToken: accessToken)
        } catch {
            logWarn(
                "workspace.selected-chat",
                "History sync job refresh failed while recovering chat \(shortLogID(chatId)).",
                error: error
            )
        }

        do {
            try await populateSelectedChatTimeline(
                accessToken: accessToken,
                chatId: chatId
            )
            logInfo(
                "workspace.selected-chat",
                "Recovered chat \(shortLogID(chatId)) after refreshing the messenger snapshot."
            )
            return true
        } catch {
            logWarn(
                "workspace.selected-chat",
                "Retry after messenger snapshot refresh still failed for chat \(shortLogID(chatId)).",
                error: error
            )
            return false
        }
    }

    private func clearSelectedChatTimelineState() {
        selectedChatTimelineItems = []
        selectedChatReadState = nil
        selectedChatReadCursor = nil
        selectedChatUnreadCount = nil
        selectedChatSyncCursor = nil
        selectedChatProjectedCursor = nil
        selectedChatProjectedMessages = []
        selectedChatHistory = []
        selectedChatMlsDiagnostics = nil
    }

    private func refreshLocalWorkspaceCache(accessToken: String) async throws {
        let messenger = try makeAuthenticatedMessenger(accessToken: accessToken)
        try applyMessengerSnapshot(try await messenger.loadSnapshot())
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

    private func applyMessengerSnapshot(_ snapshot: MessengerSnapshot) throws {
        messengerCheckpoint = snapshot.checkpoint
        localChatListItems = mergeLocalChatListItems(
            existing: localChatListItems,
            incoming: snapshot.conversations
        )
        chats = snapshot.conversations
            .map(chatSummary(for:))
            .sorted(by: chatSort)
        applyLoadedDevices(snapshot.devices)

        if var session = persistedSession {
            var didChange = false

            if let accountId = snapshot.accountId, accountId != session.accountId {
                session.accountId = accountId
                didChange = true
            }
            if let deviceId = snapshot.deviceId, deviceId != session.deviceId {
                session.deviceId = deviceId
                didChange = true
            }
            if snapshot.accountSyncChatId != session.accountSyncChatId {
                session.accountSyncChatId = snapshot.accountSyncChatId
                didChange = true
            }
            if didChange {
                try sessionStore.save(session)
                persistedSession = session
            }
        }
    }

    private func refreshLocalMessengerState(
        messenger: TrixMessengerClient
    ) async throws {
        localChatListItems = mergeLocalChatListItems(
            existing: localChatListItems,
            incoming: try await messenger.listConversations()
        )
        chats = localChatListItems
            .map(chatSummary(for:))
            .sorted(by: chatSort)
        mlsSignaturePublicKeyFingerprint = nil
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
    }

    private func decodeLinkIntentPayload(_ rawValue: String) throws -> LinkIntentPayload {
        guard let data = rawValue.nonEmptyTrimmed?.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Вставь link payload от активного устройства.")
        }

        return try JSONDecoder().decode(LinkIntentPayload.self, from: data)
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

    private func decodeBase64Data(_ rawValue: String, label: String) throws -> Data {
        guard let trimmed = rawValue.nonEmptyTrimmed, let data = Data(base64Encoded: trimmed) else {
            throw TrixAPIError.invalidPayload("Вставь валидный base64 для \(label).")
        }

        return data
    }

    private func decodeUInt64(_ rawValue: String, label: String) throws -> UInt64 {
        guard let trimmed = rawValue.nonEmptyTrimmed, let value = UInt64(trimmed) else {
            throw TrixAPIError.invalidPayload("Не удалось разобрать \(label).")
        }

        return value
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

    private func chatSummary(for item: LocalChatListItem) -> ChatSummary {
        ChatSummary(
            chatId: item.chatId,
            chatType: item.chatType,
            title: item.title,
            lastServerSeq: item.lastServerSeq,
            epoch: item.epoch,
            pendingMessageCount: item.pendingMessageCount,
            lastMessage: nil,
            participantProfiles: item.participantProfiles
        )
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
        selectedChatReadCursor = nil
        selectedChatUnreadCount = nil
        selectedChatSyncCursor = nil
        selectedChatTimelineItems = []
        selectedChatProjectedCursor = nil
        selectedChatProjectedMessages = []
        selectedChatHistory = []
        selectedChatMlsDiagnostics = nil
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
        guard isAuthenticated else {
            return
        }

        if isApplicationActive {
            restartForegroundRealtimeLoopIfNeeded()
            if foregroundRealtimeTask == nil {
                await refreshMessengerEvents(
                    postNotifications: false,
                    suppressErrors: true
                )
            }
            return
        }

        guard notificationPreferences.isEnabled else {
            return
        }

        switch notificationPreferences.permissionState {
        case .authorized, .provisional, .ephemeral:
            await refreshMessengerEvents(
                postNotifications: true,
                suppressErrors: true
            )
        case .notDetermined, .denied:
            break
        }
    }

    @discardableResult
    private func refreshMessengerEvents(
        postNotifications: Bool,
        suppressErrors: Bool
    ) async -> Bool {
        guard let token = accessToken else {
            if !suppressErrors {
                await restoreSession()
            }
            return false
        }
        guard let client = makeClient() else {
            return false
        }

        let previousChatListItems = Dictionary(
            uniqueKeysWithValues: localChatListItems.map { ($0.chatId, $0) }
        )

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            let batch = try await messenger.getNewEvents(checkpoint: messengerCheckpoint)
            messengerCheckpoint = batch.checkpoint ?? messengerCheckpoint

            if !batch.changedConversationIDs.isEmpty {
                try await refreshLocalMessengerState(messenger: messenger)
                try await reconcileSelectedChatAfterLocalStateUpdate(
                    client: client,
                    accessToken: token,
                    changedChatIDs: batch.changedConversationIDs
                )
            }

            if batch.hasDeviceChanges {
                applyLoadedDevices(try await messenger.listDevices())
            }

            if postNotifications, !batch.changedConversationIDs.isEmpty {
                await postRealtimeNotifications(
                    previousChatListItems: previousChatListItems,
                    changedChatIDs: batch.changedConversationIDs
                )
            }

            return true
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                disconnectRealtimeConnection()
                if !suppressErrors {
                    await restoreSession()
                }
            } else if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }

        return false
    }

    private func restartForegroundRealtimeLoopIfNeeded() {
        guard isApplicationActive,
              isAuthenticated,
              let accessToken,
              let accountId = currentAccount?.accountId ?? persistedSession?.accountId
        else {
            stopForegroundRealtimeLoop()
            return
        }

        let rawBaseURLString = persistedSession?.baseURLString ?? serverBaseURLString
        guard let baseURL = ServerEndpoint.normalizedURL(from: rawBaseURLString) else {
            stopForegroundRealtimeLoop()
            return
        }
        let normalizedBaseURLString = baseURL.absoluteString

        if foregroundRealtimeTask != nil,
           foregroundRealtimeAccessToken == accessToken,
           foregroundRealtimeBaseURLString == normalizedBaseURLString,
           foregroundRealtimeAccountID == accountId {
            return
        }

        stopForegroundRealtimeLoop()
        foregroundRealtimeAccessToken = accessToken
        foregroundRealtimeBaseURLString = normalizedBaseURLString
        foregroundRealtimeAccountID = accountId

        let taskID = UUID()
        foregroundRealtimeTaskID = taskID
        let pollIntervalNanoseconds = Self.foregroundRealtimePollIntervalNanoseconds
        let retryDelayNanoseconds = Self.foregroundRealtimeRetryDelayNanoseconds

        foregroundRealtimeTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                let didRefresh = await self.refreshMessengerEvents(
                    postNotifications: false,
                    suppressErrors: true
                )
                if Task.isCancelled || !self.isApplicationActive || self.accessToken == nil {
                    break
                }
                let delayNanoseconds = didRefresh ? pollIntervalNanoseconds : retryDelayNanoseconds
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    break
                }
            }

            self.finishForegroundRealtimeLoop(taskID: taskID)
        }
    }

    private func stopForegroundRealtimeLoop() {
        foregroundRealtimeTask?.cancel()
        foregroundRealtimeTask = nil
        foregroundRealtimeTaskID = nil
        foregroundRealtimeAccessToken = nil
        foregroundRealtimeBaseURLString = nil
        foregroundRealtimeAccountID = nil
    }

    private func finishForegroundRealtimeLoop(taskID: UUID) {
        guard foregroundRealtimeTaskID == taskID else {
            return
        }

        foregroundRealtimeTask = nil
        foregroundRealtimeTaskID = nil
        foregroundRealtimeAccessToken = nil
        foregroundRealtimeBaseURLString = nil
        foregroundRealtimeAccountID = nil
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
        let didAccessScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceResourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
        let fileName = sourceResourceValues.name ?? fileURL.lastPathComponent
        let mimeType = sourceResourceValues.contentType?.preferredMIMEType ??
            UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ??
            "application/octet-stream"
        let sizeBytes = UInt64(sourceResourceValues.fileSize ?? 0)
        let importedFileURL = try importedAttachmentStore.importFile(at: fileURL)

        var widthPx: UInt32?
        var heightPx: UInt32?
        if mimeType.hasPrefix("image/"),
           let image = NSImage(contentsOf: importedFileURL) {
            widthPx = UInt32(max(image.size.width.rounded(), 0))
            heightPx = UInt32(max(image.size.height.rounded(), 0))
        }

        return AttachmentDraft(
            fileURL: importedFileURL,
            fileName: fileName,
            mimeType: mimeType,
            widthPx: widthPx,
            heightPx: heightPx,
            fileSizeBytes: sizeBytes
        )
    }

    private func cleanupImportedComposerAttachmentIfNeeded(replacingWith newDraft: AttachmentDraft? = nil) {
        guard let currentDraft = composerAttachmentDraft else {
            return
        }
        guard currentDraft.fileURL != newDraft?.fileURL else {
            return
        }
        importedAttachmentStore.removeImportedFileIfOwned(at: currentDraft.fileURL)
    }

    private func cleanupImportedPendingAttachmentDrafts() {
        for pendingMessage in pendingOutgoingMessages {
            guard case let .attachment(attachmentDraft) = pendingMessage.payload else {
                continue
            }
            importedAttachmentStore.removeImportedFileIfOwned(at: attachmentDraft.fileURL)
        }
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

    private func shortDataFingerprint(_ value: Data, prefixBytes: Int = 8) -> String {
        value.prefix(prefixBytes).map { String(format: "%02x", $0) }.joined()
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
        messenger: TrixMessengerClient,
        chatId: UUID,
        timelineItems: [LocalTimelineItem]
    ) async throws {
        guard let latestMessage = timelineItems.last else {
            return
        }

        let previousReadCursor = selectedChatReadState?.readCursorServerSeq ?? 0
        if let selectedChatReadState,
           selectedChatReadState.unreadCount == 0,
           selectedChatReadState.readCursorServerSeq >= latestMessage.serverSeq {
            return
        }

        let updatedReadState = try await messenger.markRead(
            conversationId: chatId,
            throughMessageId: latestMessage.messageId
        )
        applySelectedChatReadState(updatedReadState)

        guard updatedReadState.readCursorServerSeq > 0,
              updatedReadState.readCursorServerSeq > previousReadCursor,
              let receiptTargetMessageID = readReceiptTargetMessageId(
                timelineItems: timelineItems,
                throughServerSeq: updatedReadState.readCursorServerSeq,
                previousReadCursorServerSeq: previousReadCursor
              )
        else {
            return
        }

        do {
            _ = try await messenger.sendMessage(
                conversationId: chatId,
                body: .receipt(
                    targetMessageId: receiptTargetMessageID,
                    receiptAtUnix: UInt64(Date().timeIntervalSince1970)
                )
            )
        } catch {
            // Read receipts are best-effort; keep the chat usable even if they fail.
        }
    }

    private func readReceiptTargetMessageId(
        timelineItems: [LocalTimelineItem],
        throughServerSeq: UInt64,
        previousReadCursorServerSeq: UInt64
    ) -> UUID? {
        timelineItems
            .reversed()
            .first { item in
                !item.isOutgoing &&
                    item.isVisibleInTimeline &&
                    item.serverSeq <= throughServerSeq &&
                    item.serverSeq > previousReadCursorServerSeq
            }?
            .messageId
    }

    private func normalizeCreateChatSelectionForType() {
        if createChatDraft.chatType == .dm,
           createChatDraft.selectedParticipants.count > 1 {
            createChatDraft.selectedParticipants = Array(createChatDraft.selectedParticipants.prefix(1))
        }
    }

    private func refreshDevices(showProgress: Bool, suppressErrors: Bool) async {
        guard let token = accessToken else {
            if !suppressErrors {
                await restoreSession()
            }
            return
        }

        if showProgress {
            isRefreshingDevices = true
        }
        defer {
            if showProgress {
                isRefreshingDevices = false
            }
        }

        do {
            let messenger = try makeAuthenticatedMessenger(accessToken: token)
            applyLoadedDevices(try await messenger.listDevices())
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                accessToken = nil
                disconnectRealtimeConnection()
                if !suppressErrors {
                    await restoreSession()
                }
            } else if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        } catch {
            if !suppressErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }
    }

    private func applyLoadedDevices(_ loadedDevices: [DeviceSummary]) {
        let pendingDeviceIDs = pendingDeviceIDs(in: loadedDevices)
        let newPendingDeviceIDs = pendingDeviceIDs.subtracting(linkIntentPendingBaselineIDs)
        let currentStatus = currentDeviceID.flatMap { currentDeviceID in
            loadedDevices.first(where: { $0.deviceId == currentDeviceID })?.deviceStatus
        }

        devices = sortedDevicesForDisplay(
            loadedDevices,
            currentDeviceID: currentDeviceID
        )

        if let currentStatus {
            if let currentAccount, currentAccount.deviceStatus != currentStatus {
                self.currentAccount = AccountProfileResponse(
                    accountId: currentAccount.accountId,
                    handle: currentAccount.handle,
                    profileName: currentAccount.profileName,
                    profileBio: currentAccount.profileBio,
                    deviceId: currentAccount.deviceId,
                    deviceStatus: currentStatus
                )
            }
            if var session = persistedSession, session.deviceStatus != currentStatus {
                session.deviceStatus = currentStatus
                try? sessionStore.save(session)
                persistedSession = session
            }
        }

        guard outgoingLinkIntent != nil,
              let discoveredDevice = sortedDevicesForDisplay(
                loadedDevices.filter { newPendingDeviceIDs.contains($0.deviceId) },
                currentDeviceID: currentDeviceID
              ).first else {
            return
        }

        outgoingLinkIntent = nil
        stopLinkIntentRefreshLoop()
        lastErrorMessage = "Device \"\(discoveredDevice.displayName)\" is waiting for approval in Trusted Devices."
    }

    private func startLinkIntentRefreshLoop() {
        guard let linkIntent = outgoingLinkIntent else {
            return
        }

        linkIntentRefreshTask?.cancel()
        linkIntentRefreshTask = nil
        let expiresAt = linkIntent.expiresAt

        linkIntentRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                guard self.outgoingLinkIntent?.id == linkIntent.id else {
                    return
                }

                if Date() >= expiresAt {
                    self.outgoingLinkIntent = nil
                    self.stopLinkIntentRefreshLoop()
                    self.lastErrorMessage = "The link payload expired. Create a new one if you still need to add a device."
                    return
                }

                if !self.isRefreshingWorkspace && !self.isRefreshingDevices {
                    await self.refreshDevices(showProgress: false, suppressErrors: true)
                }

                let remainingSeconds = max(expiresAt.timeIntervalSinceNow, 0)
                let sleepNanoseconds = UInt64(
                    min(
                        remainingSeconds,
                        TimeInterval(Self.linkIntentRefreshIntervalNanoseconds) / 1_000_000_000
                    ) * 1_000_000_000
                )
                try? await Task.sleep(nanoseconds: max(sleepNanoseconds, 250_000_000))
            }
        }
    }

    private func stopLinkIntentRefreshLoop() {
        linkIntentRefreshTask?.cancel()
        linkIntentRefreshTask = nil
        linkIntentPendingBaselineIDs = []
    }
}

enum OnboardingMode: String, CaseIterable {
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

struct HistorySyncChunkDraft {
    var sequenceNo = ""
    var payloadB64 = ""
    var cursorJSON = ""
    var isFinal = false
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

func sortedDevicesForDisplay(
    _ devices: [DeviceSummary],
    currentDeviceID: UUID?
) -> [DeviceSummary] {
    devices.sorted { lhs, rhs in
        let lhsPriority = deviceDisplayPriority(lhs, currentDeviceID: currentDeviceID)
        let rhsPriority = deviceDisplayPriority(rhs, currentDeviceID: currentDeviceID)

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.deviceId.uuidString.localizedCaseInsensitiveCompare(rhs.deviceId.uuidString) == .orderedAscending
    }
}

func deviceDisplayPriority(_ device: DeviceSummary, currentDeviceID: UUID?) -> Int {
    switch device.deviceStatus {
    case .pending:
        return 0
    case .active:
        return device.deviceId == currentDeviceID ? 1 : 2
    case .revoked:
        return 3
    }
}

func pendingDeviceIDs(in devices: [DeviceSummary]) -> Set<UUID> {
    Set(
        devices.compactMap { device in
            device.deviceStatus == .pending ? device.deviceId : nil
        }
    )
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

enum SessionRestoreErrorDisposition: Equatable {
    case restartPendingLink
    case preservePendingSession
    case preserveActiveSession
    case preserveActiveSessionRequiresRelink
    case surface
}

enum StoredSessionRecoveryMode: Equatable {
    case reconnect
    case relinkRequired
    case localKeysMissing
}

struct MissingStoredIdentityRecoveryPlan: Equatable {
    let mode: StoredSessionRecoveryMode
    let message: String
}

func missingStoredIdentityRecoveryPlan(hasPersistedSession: Bool) -> MissingStoredIdentityRecoveryPlan? {
    guard hasPersistedSession else {
        return nil
    }

    return MissingStoredIdentityRecoveryPlan(
        mode: .localKeysMissing,
        message: "На этом Mac больше нет локальных device keys для сохранённой сессии. Reconnect уже не поможет. Забудь это устройство и пройди link flow заново."
    )
}

func offlineCachedAccountProfile(for session: PersistedSession) -> AccountProfileResponse {
    AccountProfileResponse(
        accountId: session.accountId,
        handle: session.handle,
        profileName: session.profileName,
        profileBio: nil,
        deviceId: session.deviceId,
        deviceStatus: session.deviceStatus
    )
}

func sessionRestoreErrorDisposition(
    deviceStatus: DeviceStatus,
    error: TrixAPIError
) -> SessionRestoreErrorDisposition {
    switch deviceStatus {
    case .pending:
        if error.suggestsPendingLinkReset || error.isMissingServerState {
            return .restartPendingLink
        }
        if error.isCredentialFailure {
            return .preservePendingSession
        }
    case .active, .revoked:
        if error.isMissingServerState {
            return .preserveActiveSessionRequiresRelink
        }
        if error.isCredentialFailure {
            return .preserveActiveSession
        }
    }

    return .surface
}

func preservedRestoreFailureMessage(for error: TrixAPIError) -> String {
    let reason = error.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    if reason.isEmpty {
        return "Не удалось восстановить сессию на сервере. Локальные ключи и история сохранены на этом Mac. Проверь подключение и состояние устройства на сервере, затем попробуй reconnect."
    }

    return "Не удалось восстановить сессию на сервере (\(reason)). Локальные ключи и история сохранены на этом Mac. Проверь подключение и состояние устройства на сервере, затем попробуй reconnect."
}

func relinkRequiredRestoreFailureMessage(for error: TrixAPIError) -> String {
    let reason = error.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    if reason.isEmpty {
        return "Сервер больше не хранит запись об этом Mac. Локальные ключи и история пока сохранены на этом Mac, но reconnect уже не поможет. Забудь текущее устройство и пройди link flow заново."
    }

    return "Сервер больше не хранит запись об этом Mac (\(reason)). Локальные ключи и история пока сохранены на этом Mac, но reconnect уже не поможет. Забудь текущее устройство и пройди link flow заново."
}
