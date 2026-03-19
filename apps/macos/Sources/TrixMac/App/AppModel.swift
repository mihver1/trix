import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var serverBaseURLString: String
    @Published var draft: OnboardingDraft
    @Published var linkDraft: LinkDeviceDraft
    @Published var approvalDraft = DeviceApprovalDraft()
    @Published var onboardingMode: OnboardingMode = .createAccount
    @Published var health: HealthResponse?
    @Published var version: VersionResponse?
    @Published var currentAccount: AccountProfileResponse?
    @Published var devices: [DeviceSummary] = []
    @Published var chats: [ChatSummary] = []
    @Published var selectedChatID: UUID?
    @Published var selectedChatDetail: ChatDetailResponse?
    @Published var selectedChatHistory: [MessageEnvelope] = []
    @Published var outgoingLinkIntent: DeviceLinkIntentState?
    @Published var pendingApprovalPayload: String?
    @Published var hasAccountRootKey = false
    @Published var isRefreshingStatus = false
    @Published var isCreatingAccount = false
    @Published var isCreatingLinkIntent = false
    @Published var isCompletingLink = false
    @Published var isRestoringSession = false
    @Published var isRefreshingWorkspace = false
    @Published var isLoadingSelectedChat = false
    @Published var isApprovingPendingDevice = false
    @Published var revokingDeviceIDs: Set<UUID> = []
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

    var canApprovePendingDevice: Bool {
        isAuthenticated &&
            hasAccountRootKey &&
            approvalDraft.payload.nonEmptyTrimmed != nil &&
            !isApprovingPendingDevice
    }

    var currentDeviceID: UUID? {
        currentAccount?.deviceId ?? persistedSession?.deviceId
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
                    lastErrorMessage = "This device is still pending approval. Approve it from an active root-capable device, then reconnect."
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

    func approvePendingDevice() async {
        guard canApprovePendingDevice else {
            return
        }
        guard let token = accessToken else {
            await restoreSession()
            return
        }

        isApprovingPendingDevice = true
        lastErrorMessage = nil
        defer { isApprovingPendingDevice = false }

        do {
            let payload = try decodeDeviceApprovalPayload(approvalDraft.payload)
            guard payload.accountId == currentAccount?.accountId else {
                throw TrixAPIError.invalidPayload("Approval payload относится к другому аккаунту.")
            }
            guard let client = makeClient(baseURLString: payload.baseURL) else {
                return
            }

            let identity = try loadStoredIdentity(requireAccountRoot: true)
            guard
                let transportPublicKey = Data(base64Encoded: payload.transportPubkeyB64),
                let credentialIdentity = Data(base64Encoded: payload.credentialIdentityB64)
            else {
                throw TrixAPIError.invalidPayload("Approval payload содержит невалидный base64.")
            }

            let signatureB64 = try identity.accountBootstrapSignatureB64(
                transportPublicKey: transportPublicKey,
                credentialIdentity: credentialIdentity
            )
            _ = try await client.approveDevice(
                accessToken: token,
                deviceId: payload.pendingDeviceId,
                request: ApproveDeviceRequest(accountRootSignatureB64: signatureB64)
            )

            approvalDraft.payload = ""
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
        return TrixAPIClient(baseURL: baseURL)
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

        if let preferredChatID = preferredChatSelection(from: sortedChats) {
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

        async let detail = client.fetchChatDetail(accessToken: accessToken, chatId: chatId)
        async let history = client.fetchChatHistory(accessToken: accessToken, chatId: chatId)

        let loadedDetail = try await detail
        let loadedHistory = try await history

        selectedChatDetail = loadedDetail
        selectedChatHistory = loadedHistory.messages
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
        pendingApprovalPayload = nil
        approvalDraft = DeviceApprovalDraft()
        hasAccountRootKey = false
        onboardingMode = .createAccount
        linkDraft = LinkDeviceDraft(deviceDisplayName: defaultDeviceName)
    }

    private func clearWorkspaceData() {
        currentAccount = nil
        devices = []
        chats = []
        clearSelectedChat()
    }

    private func refreshLocalIdentityState(reportErrors: Bool) {
        do {
            hasAccountRootKey = try keychainStore.loadData(for: .accountRootSeed) != nil
            pendingApprovalPayload = try makePendingApprovalPayload()
        } catch {
            hasAccountRootKey = false
            pendingApprovalPayload = nil
            if reportErrors {
                lastErrorMessage = error.userFacingMessage
            }
        }
    }

    private func makePendingApprovalPayload() throws -> String? {
        guard let session = persistedSession, session.deviceStatus == .pending else {
            return nil
        }

        let identity = try loadStoredIdentity()
        let payload = DeviceApprovalPayload(
            version: 1,
            baseURL: session.baseURLString,
            accountId: session.accountId,
            pendingDeviceId: session.deviceId,
            deviceDisplayName: session.deviceDisplayName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentityB64: identity.credentialIdentityB64,
            transportPubkeyB64: identity.transportPublicKeyB64
        )
        return try encodeLocalJSON(payload)
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

    private func decodeLinkIntentPayload(_ rawValue: String) throws -> LinkIntentPayload {
        guard let data = rawValue.nonEmptyTrimmed?.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Вставь link payload от активного устройства.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LinkIntentPayload.self, from: data)
    }

    private func decodeDeviceApprovalPayload(_ rawValue: String) throws -> DeviceApprovalPayload {
        guard let data = rawValue.nonEmptyTrimmed?.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Вставь approval payload с нового устройства.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DeviceApprovalPayload.self, from: data)
    }

    private func encodeLocalJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)

        guard let string = String(data: data, encoding: .utf8) else {
            throw TrixAPIError.invalidPayload("Не удалось собрать локальный JSON payload.")
        }

        return string
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

struct DeviceApprovalDraft {
    var payload = ""
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
