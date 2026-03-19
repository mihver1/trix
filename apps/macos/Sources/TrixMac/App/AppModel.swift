import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var serverBaseURLString: String
    @Published var draft: OnboardingDraft
    @Published var health: HealthResponse?
    @Published var version: VersionResponse?
    @Published var currentAccount: AccountProfileResponse?
    @Published var devices: [DeviceSummary] = []
    @Published var chats: [ChatSummary] = []
    @Published var selectedChatID: UUID?
    @Published var selectedChatDetail: ChatDetailResponse?
    @Published var selectedChatHistory: [MessageEnvelope] = []
    @Published var isRefreshingStatus = false
    @Published var isCreatingAccount = false
    @Published var isRestoringSession = false
    @Published var isRefreshingWorkspace = false
    @Published var isLoadingSelectedChat = false
    @Published var lastErrorMessage: String?

    private let sessionStore: SessionStore
    private let keychainStore: KeychainStore
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
        self.serverBaseURLString = "http://127.0.0.1:8080"
        self.draft = OnboardingDraft(deviceDisplayName: defaultDeviceName)
    }

    var isAuthenticated: Bool {
        currentAccount != nil && accessToken != nil
    }

    var hasPersistedSession: Bool {
        persistedSession != nil
    }

    var showsWorkspace: Bool {
        isAuthenticated || hasPersistedSession
    }

    var canCreateAccount: Bool {
        draft.profileName.nonEmptyTrimmed != nil &&
            draft.deviceDisplayName.nonEmptyTrimmed != nil &&
            ServerEndpoint.normalizedURL(from: serverBaseURLString) != nil
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
            }
        } catch {
            lastErrorMessage = error.userFacingMessage
        }

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
                deviceDisplayName: deviceDisplayName
            )

            try save(identity: identity, authSession: authSession, persistedSession: session)
            try await loadWorkspace(client: client, accessToken: authSession.accessToken)
            await refreshServerStatus()
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
            accessToken = authSession.accessToken
            try keychainStore.save(
                Data(authSession.accessToken.utf8),
                for: .accessToken
            )
            try await loadWorkspace(client: client, accessToken: authSession.accessToken)
        } catch let error as TrixAPIError {
            if error.isCredentialFailure {
                try? clearSession()
                serverBaseURLString = session.baseURLString
                draft.profileName = session.profileName
                draft.handle = session.handle ?? ""
                draft.deviceDisplayName = session.deviceDisplayName
                lastErrorMessage = "Сохранённая сессия больше невалидна. Создай устройство заново."
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
        authSession: AuthSessionResponse,
        persistedSession: PersistedSession
    ) throws {
        let storedIdentity = identity.storedIdentity

        try keychainStore.save(storedIdentity.accountRootSeed, for: .accountRootSeed)
        try keychainStore.save(storedIdentity.transportSeed, for: .transportSeed)
        try keychainStore.save(storedIdentity.credentialIdentity, for: .credentialIdentity)
        try keychainStore.save(Data(authSession.accessToken.utf8), for: .accessToken)
        try sessionStore.save(persistedSession)

        self.persistedSession = persistedSession
        self.accessToken = authSession.accessToken
    }

    private func loadStoredIdentity() throws -> DeviceIdentityMaterial {
        guard
            let accountRootSeed = try keychainStore.loadData(for: .accountRootSeed),
            let transportSeed = try keychainStore.loadData(for: .transportSeed),
            let credentialIdentity = try keychainStore.loadData(for: .credentialIdentity)
        else {
            throw TrixAPIError.invalidPayload("Не удалось загрузить ключи устройства из Keychain.")
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
        currentAccount = nil
        devices = []
        chats = []
        clearSelectedChat()
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

struct OnboardingDraft {
    var profileName = ""
    var handle = ""
    var profileBio = ""
    var deviceDisplayName: String
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
