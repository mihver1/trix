import Foundation

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
    @Published var publishedKeyPackages: [PublishedKeyPackage] = []
    @Published var reservedKeyPackages: [ReservedKeyPackage] = []
    @Published var reservedKeyPackagesAccountID: UUID?
    @Published var selectedChatID: UUID?
    @Published var selectedChatDetail: ChatDetailResponse?
    @Published var selectedChatHistory: [MessageEnvelope] = []
    @Published var outgoingLinkIntent: DeviceLinkIntentState?
    @Published var hasAccountRootKey = false
    @Published var isRefreshingStatus = false
    @Published var isCreatingAccount = false
    @Published var isCreatingLinkIntent = false
    @Published var isCompletingLink = false
    @Published var isPublishingKeyPackages = false
    @Published var isReservingKeyPackages = false
    @Published var isRestoringSession = false
    @Published var isRefreshingWorkspace = false
    @Published var isRefreshingInbox = false
    @Published var isLeasingInbox = false
    @Published var isAckingInbox = false
    @Published var isRefreshingHistorySyncJobs = false
    @Published var isLoadingSelectedChat = false
    @Published var revokingDeviceIDs: Set<UUID> = []
    @Published var approvingDeviceIDs: Set<UUID> = []
    @Published var completingHistorySyncJobIDs: Set<UUID> = []
    @Published var lastErrorMessage: String?

    private let sessionStore: SessionStore
    private let keychainStore: KeychainStore
    private let defaultDeviceName: String
    private var persistedSession: PersistedSession?
    private var accessToken: String?
    private var didStart = false

    init(
        sessionStore: SessionStore = SessionStore(),
        keychainStore: KeychainStore = KeychainStore()
    ) {
        self.sessionStore = sessionStore
        self.keychainStore = keychainStore

        let defaultDeviceName = Host.current().localizedName ?? "This Mac"
        self.defaultDeviceName = defaultDeviceName
        self.serverBaseURLString = "http://127.0.0.1:8080"
        self.draft = OnboardingDraft(deviceDisplayName: defaultDeviceName)
        self.linkDraft = LinkDeviceDraft(deviceDisplayName: defaultDeviceName)
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
            let request = try identity.makeCreateAccountRequest(
                handle: handle,
                profileName: profileName,
                profileBio: profileBio,
                deviceDisplayName: deviceDisplayName
            )
            let created = try await client.createAccount(request)
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
            let response = try await client.completeLinkIntent(
                linkIntentId: payload.linkIntentId,
                request: identity.makeCompleteLinkIntentRequest(
                    linkToken: payload.linkToken,
                    deviceDisplayName: deviceDisplayName
                )
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
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                if session.deviceStatus == .pending {
                    accessToken = nil
                    clearWorkspaceData()
                    refreshLocalIdentityState(reportErrors: false)
                    lastErrorMessage = "This device is still pending approval. Approve it from any active trusted device in the device directory, then reconnect."
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

        isRefreshingWorkspace = true
        defer { isRefreshingWorkspace = false }

        do {
            try await loadWorkspace(client: client, accessToken: token)
            await refreshServerStatus()
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

    func refreshInbox() async {
        guard let token = accessToken else {
            await restoreSession()
            return
        }
        guard let client = makeClient() else {
            return
        }

        isRefreshingInbox = true
        lastErrorMessage = nil
        defer { isRefreshingInbox = false }

        do {
            let parameters = try decodeInboxPollParameters()
            let storePaths = try workspaceStorePaths()
            let response = try await client.fetchInboxIntoLocalStore(
                accessToken: token,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL,
                afterInboxId: parameters.afterInboxId,
                limit: parameters.limit
            )
            mergeInboxItems(response.items, autoAdvanceCursor: true)
            applyLocalStoreSnapshot(chats: response.chats, syncState: response.syncState)
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
            activeInboxLease = InboxLeaseState(
                owner: response.lease.leaseOwner,
                expiresAt: response.lease.leaseExpiresAt
            )
            mergeInboxItems(response.lease.items, autoAdvanceCursor: true)
            applyLocalStoreSnapshot(chats: response.chats, syncState: response.syncState)
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
            let payload = try await client.fetchDeviceApprovePayload(
                accessToken: token,
                deviceId: device.deviceId
            )
            guard payload.accountId == currentAccount?.accountId else {
                throw TrixAPIError.invalidPayload("Approve payload относится к другому аккаунту.")
            }

            let identity = try loadStoredIdentity(requireAccountRoot: true)
            guard
                let bootstrapPayload = Data(base64Encoded: payload.bootstrapPayloadB64)
            else {
                throw TrixAPIError.invalidPayload("Сервер вернул невалидный approve payload.")
            }

            let signatureB64 = try identity.accountRootSignatureB64(
                for: bootstrapPayload,
                errorMessage: "Approve доступен только на root-capable устройстве."
            )
            _ = try await client.approveDevice(
                accessToken: token,
                deviceId: payload.deviceId,
                request: ApproveDeviceRequest(accountRootSignatureB64: signatureB64)
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
            let signatureB64 = try identity.revokeSignatureB64(
                deviceID: device.deviceId,
                reason: reason
            )

            guard let client = makeClient() else {
                return
            }

            _ = try await client.revokeDevice(
                accessToken: token,
                deviceId: device.deviceId,
                request: RevokeDeviceRequest(
                    reason: reason,
                    accountRootSignatureB64: signatureB64
                )
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
        guard selectedChatID != chatId || selectedChatDetail == nil || selectedChatHistory.isEmpty else {
            return
        }

        do {
            try await loadSelectedChat(client: client, accessToken: token, chatId: chatId)
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

    func signOut() {
        do {
            try clearSession()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.userFacingMessage
        }
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
        let challenge = try await client.createAuthChallenge(
            AuthChallengeRequest(deviceId: deviceId)
        )

        guard let challengeData = Data(base64Encoded: challenge.challengeB64) else {
            throw TrixAPIError.invalidPayload("Сервер вернул challenge в неожиданном формате.")
        }

        let signatureB64 = try identity.transportSignatureB64(for: challengeData)

        return try await client.createAuthSession(
            AuthSessionRequest(
                deviceId: deviceId,
                challengeId: challenge.challengeId,
                signatureB64: signatureB64
            )
        )
    }

    private func loadWorkspace(client: TrixAPIClient, accessToken: String) async throws {
        isRefreshingWorkspace = true
        defer { isRefreshingWorkspace = false }

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
        try await loadHistorySyncJobs(client: client, accessToken: accessToken)
        await refreshLocalWorkspaceCache(
            client: client,
            accessToken: accessToken,
            accountId: loadedProfile.accountId
        )

        if let preferredChatID = preferredChatSelection(from: self.chats) {
            try await loadSelectedChat(
                client: client,
                accessToken: accessToken,
                chatId: preferredChatID
            )
        } else {
            clearSelectedChat()
        }
    }

    private func loadSelectedChat(
        client: TrixAPIClient,
        accessToken: String,
        chatId: UUID
    ) async throws {
        selectedChatID = chatId
        selectedChatDetail = nil
        selectedChatHistory = []
        isLoadingSelectedChat = true
        defer { isLoadingSelectedChat = false }

        let loadedDetail = try await client.fetchChatDetail(accessToken: accessToken, chatId: chatId)
        selectedChatDetail = loadedDetail

        do {
            let storePaths = try workspaceStorePaths()
            let localHistory = try await client.fetchLocalChatHistory(
                databasePath: storePaths.localHistoryURL,
                chatId: chatId
            )
            if localHistory.messages.isEmpty && loadedDetail.lastServerSeq > 0 {
                let remoteHistory = try await client.fetchChatHistory(
                    accessToken: accessToken,
                    chatId: chatId
                )
                selectedChatHistory = remoteHistory.messages
            } else {
                selectedChatHistory = localHistory.messages
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
            let localResult = try await client.syncChatHistoriesIntoLocalStore(
                accessToken: accessToken,
                databasePath: storePaths.localHistoryURL,
                statePath: storePaths.syncStateURL
            )
            applyLocalStoreSnapshot(chats: localResult.chats, syncState: localResult.syncState)
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
        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
    }

    private func preferredChatSelection(from chats: [ChatSummary]) -> UUID? {
        if let selectedChatID,
           chats.contains(where: { $0.chatId == selectedChatID }) {
            return selectedChatID
        }

        return chats.first?.chatId
    }

    private func clearSelectedChat() {
        selectedChatID = nil
        selectedChatDetail = nil
        selectedChatHistory = []
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

    private func defaultInboxLeaseOwner(for deviceId: UUID) -> String {
        let prefix = String(deviceId.uuidString.prefix(8)).lowercased()
        return "macos-alpha:\(prefix)"
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
