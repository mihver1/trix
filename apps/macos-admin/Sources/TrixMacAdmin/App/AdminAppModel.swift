import SwiftUI

enum AdminOperatorError: Error, Equatable, LocalizedError {
    case noClusterOrSession
    case disableTargetMissing
    case clusterNameConfirmationMismatch
    case reactivateTargetMissing

    var errorDescription: String? {
        switch self {
        case .noClusterOrSession:
            return "No active cluster or session."
        case .disableTargetMissing:
            return "No user selected for disable."
        case .clusterNameConfirmationMismatch:
            return "Type the exact cluster name to confirm."
        case .reactivateTargetMissing:
            return "No user selected for reactivate."
        }
    }
}

@MainActor
final class AdminAppModel: ObservableObject {
    @Published private(set) var profiles: [ClusterProfile] = []
    @Published var selectedClusterID: UUID?
    @Published var clusterEditorDraft: ClusterProfile?
    @Published var loginError: String?
    @Published var isSigningIn = false
    @Published private(set) var activeSession: StoredAdminSession?

    @Published var selectedWorkspaceSection: AdminWorkspaceSection = .overview
    @Published private(set) var overview: AdminOverviewState?
    @Published private(set) var registrationSettings: AdminRegistrationSettingsResponse?
    @Published private(set) var serverSettings: AdminServerSettingsResponse?
    @Published private(set) var requiresReauthentication = false
    @Published var workspaceError: String?
    @Published private(set) var isWorkspaceLoading = false

    @Published private(set) var users: [AdminUserSummary] = []
    @Published private(set) var usersNextCursor: String?
    @Published var userSearchText = ""
    @Published private(set) var isUsersLoading = false
    @Published var usersError: String?

    @Published private(set) var userDetail: AdminUserSummary?
    @Published private(set) var isUserDetailLoading = false
    @Published var userDetailError: String?

    @Published var isProvisionSheetPresented = false
    @Published private(set) var lastProvisioningArtifact: AdminUserProvisioningArtifact?
    @Published var provisionError: String?
    @Published private(set) var isProvisioning = false

    @Published private(set) var disableTargetUserID: UUID?
    @Published var disableConfirmationText = ""
    @Published private(set) var isDisablingUser = false

    @Published private(set) var reactivateTargetUserID: UUID?
    @Published var reactivateConfirmationText = ""
    @Published private(set) var isReactivatingUser = false

    @Published private(set) var featureFlagDefinitions: [AdminFeatureFlagDefinition] = []
    @Published private(set) var featureFlagOverrides: [AdminFeatureFlagOverride] = []
    @Published var featureFlagsError: String?
    @Published private(set) var isFeatureFlagsLoading = false

    @Published private(set) var debugMetricSessions: [AdminDebugMetricSession] = []
    @Published private(set) var debugMetricBatches: [AdminDebugMetricBatch] = []
    @Published var debugMetricSessionsFilterAccountText = ""
    @Published var selectedDebugMetricSessionId: String?
    @Published var debugMetricsError: String?
    @Published private(set) var isDebugMetricSessionsLoading = false
    @Published private(set) var isDebugMetricBatchesLoading = false

    private var featureFlagsDataGeneration: UInt64 = 0
    private var debugSessionsDataGeneration: UInt64 = 0
    private var debugBatchesDataGeneration: UInt64 = 0

    /// Invalidates in-flight user list loads when cluster/session changes or a new list fetch supersedes a prior one.
    private var userListDataGeneration: UInt64 = 0
    private var userSearchDebounceTask: Task<Void, Never>?

    let requestCoordinator = AdminRequestCoordinator()

    private let profileStore: ClusterProfileStore
    private let sessionStore: AdminSessionStore
    private let api: any AdminAPIProtocol

    /// Background refresh from cluster/selection changes; cancelled when `refreshWorkspaceData()` runs explicitly.
    private var scheduledWorkspaceRefresh: Task<Void, Never>?

    /// Bumped when scheduling a new full refresh or when a mutation invalidates in-flight refresh results.
    private var workspaceDataGeneration: UInt64 = 0

    var editorIsNewCluster = false

    var selectedCluster: ClusterProfile? {
        profiles.first { $0.id == selectedClusterID }
    }

    var isClusterEditorValid: Bool {
        guard let draft = clusterEditorDraft else { return false }
        let nameOk = !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let scheme = draft.baseURL.scheme?.lowercased()
        let urlOk = scheme == "https" || scheme == "http"
        let envOk = !draft.environmentLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nameOk && urlOk && envOk
    }

    init(
        profileStore: ClusterProfileStore,
        sessionStore: AdminSessionStore,
        api: any AdminAPIProtocol = AdminAPIClient()
    ) {
        self.profileStore = profileStore
        self.sessionStore = sessionStore
        self.api = api
    }

    convenience init() {
        let root = (try? ClusterProfileStore.defaultRootURL())
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("TrixMacAdmin", isDirectory: true)
        self.init(
            profileStore: ClusterProfileStore(rootURL: root),
            sessionStore: AdminSessionStore(rootURL: root, keychain: AdminKeychainStore()),
            api: AdminAPIClient()
        )
    }

    func start() async {
        do {
            let snapshot = try profileStore.load()
            profiles = snapshot.profiles
            let resolvedID: UUID?
            if let id = snapshot.lastSelectedClusterID, profiles.contains(where: { $0.id == id }) {
                resolvedID = id
            } else {
                resolvedID = profiles.first?.id
            }
            await requestCoordinator.setActiveCluster(resolvedID)
            selectedClusterID = resolvedID
            refreshActiveSession()
            scheduleWorkspaceRefresh()
        } catch {
            profiles = []
            await requestCoordinator.setActiveCluster(nil)
            selectedClusterID = nil
            activeSession = nil
            clearWorkspaceState()
        }
    }

    /// Updates the request coordinator before published selection so `perform(clusterID:)` cannot race stale active state.
    func selectCluster(_ id: UUID?) async {
        await requestCoordinator.setActiveCluster(id)
        selectedClusterID = id
        persistProfiles()
        refreshActiveSession()
        clearWorkspaceState()
        scheduleWorkspaceRefresh()
    }

    func selectCluster(_ profile: ClusterProfile) async {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        await selectCluster(profile.id)
    }

    func beginAddCluster() {
        editorIsNewCluster = true
        clusterEditorDraft = ClusterProfile(
            id: UUID(),
            displayName: "",
            baseURL: URL(string: "https://example.com")!,
            environmentLabel: "",
            authMode: .localCredentials
        )
    }

    func beginEditSelectedCluster() {
        guard let id = selectedClusterID, let profile = profiles.first(where: { $0.id == id }) else {
            return
        }
        editorIsNewCluster = false
        clusterEditorDraft = profile
    }

    func cancelClusterEditor() {
        clusterEditorDraft = nil
    }

    func saveClusterEditor() async {
        guard let draft = clusterEditorDraft, isClusterEditorValid else { return }
        if let idx = profiles.firstIndex(where: { $0.id == draft.id }) {
            profiles[idx] = draft
        } else {
            await requestCoordinator.setActiveCluster(draft.id)
            profiles.append(draft)
            selectedClusterID = draft.id
        }
        clusterEditorDraft = nil
        persistProfiles()
        refreshActiveSession()
        clearWorkspaceState()
        scheduleWorkspaceRefresh()
    }

    func removeCluster(id: UUID) async {
        profiles.removeAll { $0.id == id }
        try? sessionStore.clearSession(clusterID: id)
        if selectedClusterID == id {
            let nextID = profiles.first?.id
            await requestCoordinator.setActiveCluster(nextID)
            selectedClusterID = nextID
        }
        persistProfiles()
        refreshActiveSession()
        clearWorkspaceState()
        scheduleWorkspaceRefresh()
    }

    func signIn(username: String, password: String) async {
        guard let cluster = selectedCluster else {
            loginError = "Select a cluster."
            return
        }
        isSigningIn = true
        loginError = nil
        defer { isSigningIn = false }
        let client = api
        do {
            let response = try await requestCoordinator.perform(clusterID: cluster.id) {
                try await client.createSession(
                    cluster: cluster,
                    username: username,
                    password: password
                )
            }
            try sessionStore.saveSession(response, clusterID: cluster.id)
            refreshActiveSession()
            requiresReauthentication = false
            await refreshWorkspaceData()
        } catch is CancellationError {
            loginError = "Request cancelled (cluster changed)."
        } catch {
            loginError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let cluster = selectedCluster, let session = activeSession else { return }
        abortInFlightWorkspaceRefresh()
        let client = api
        try? await requestCoordinator.perform(clusterID: cluster.id) {
            try await client.deleteSession(cluster: cluster, accessToken: session.accessToken)
        }
        try? sessionStore.clearSession(clusterID: cluster.id)
        refreshActiveSession()
        requiresReauthentication = false
        clearWorkspaceState()
    }

    func refreshWorkspaceData() async {
        cancelScheduledWorkspaceRefresh()
        beginNewWorkspaceDataEpoch()
        let generation = workspaceDataGeneration
        await runWorkspaceRefresh(dataGeneration: generation)
    }

    private func scheduleWorkspaceRefresh() {
        cancelScheduledWorkspaceRefresh()
        beginNewWorkspaceDataEpoch()
        let generation = workspaceDataGeneration
        scheduledWorkspaceRefresh = Task { await runWorkspaceRefresh(dataGeneration: generation) }
    }

    private func cancelScheduledWorkspaceRefresh() {
        scheduledWorkspaceRefresh?.cancel()
        scheduledWorkspaceRefresh = nil
    }

    private func beginNewWorkspaceDataEpoch() {
        workspaceDataGeneration &+= 1
    }

    /// Cancels scheduled refresh, bumps epoch so in-flight `runWorkspaceRefresh` completions cannot publish, and clears loading.
    /// Used when no immediate replacement refresh will own the spinner (sign-out, settings mutations).
    private func abortInFlightWorkspaceRefresh() {
        cancelScheduledWorkspaceRefresh()
        beginNewWorkspaceDataEpoch()
        isWorkspaceLoading = false
    }

    /// Cancels any pending scheduled refresh and invalidates in-flight full refresh results before mutating workspace data.
    private func prepareWorkspaceMutationEpoch() {
        abortInFlightWorkspaceRefresh()
    }

    private func runWorkspaceRefresh(dataGeneration: UInt64) async {
        guard let cluster = selectedCluster, let session = activeSession else {
            clearWorkspaceState()
            return
        }
        let clusterID = cluster.id
        let displayName = cluster.displayName
        let token = session.accessToken
        isWorkspaceLoading = true
        workspaceError = nil
        defer {
            if workspaceDataGeneration == dataGeneration {
                isWorkspaceLoading = false
            }
        }

        let client = api
        do {
            async let overviewTask = requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchOverview(cluster: cluster, accessToken: token)
            }
            async let registrationTask = requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchRegistrationSettings(cluster: cluster, accessToken: token)
            }
            async let serverTask = requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchServerSettings(cluster: cluster, accessToken: token)
            }
            let (ov, reg, srv) = try await (overviewTask, registrationTask, serverTask)
            guard await isStillActiveCluster(clusterID) else { return }
            guard workspaceDataGeneration == dataGeneration else { return }
            overview = AdminOverviewState(clusterID: clusterID, clusterDisplayName: displayName, response: ov)
            registrationSettings = reg
            serverSettings = srv
            requiresReauthentication = false
        } catch is CancellationError {
            // Superseded by another cluster selection or an explicit `refreshWorkspaceData()` cancel.
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            guard workspaceDataGeneration == dataGeneration else { return }
            if Self.isUnauthorized(error) {
                requiresReauthentication = true
                try? sessionStore.clearSession(clusterID: clusterID)
                refreshActiveSession()
                clearWorkspaceState()
            } else {
                workspaceError = error.localizedDescription
            }
        }
    }

    func setPublicRegistrationEnabled(_ enabled: Bool) async throws {
        guard let cluster = selectedCluster, let session = activeSession else { return }
        prepareWorkspaceMutationEpoch()
        let mutationGeneration = workspaceDataGeneration
        let clusterID = cluster.id
        let client = api
        try await requestCoordinator.perform(clusterID: clusterID) {
            _ = try await client.updateRegistrationSettings(
                cluster: cluster,
                accessToken: session.accessToken,
                allowPublicAccountRegistration: enabled
            )
        }
        let canonical = try await requestCoordinator.perform(clusterID: clusterID) {
            try await client.fetchRegistrationSettings(cluster: cluster, accessToken: session.accessToken)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        guard workspaceDataGeneration == mutationGeneration else { return }
        registrationSettings = canonical
        await refreshOverviewOnly(
            clusterID: clusterID,
            displayName: cluster.displayName,
            token: session.accessToken,
            dataGeneration: mutationGeneration
        )
    }

    func updateServerSettings(patch: PatchAdminServerSettingsRequest) async throws {
        guard let cluster = selectedCluster, let session = activeSession else { return }
        prepareWorkspaceMutationEpoch()
        let mutationGeneration = workspaceDataGeneration
        let clusterID = cluster.id
        let client = api
        try await requestCoordinator.perform(clusterID: clusterID) {
            _ = try await client.updateServerSettings(
                cluster: cluster,
                accessToken: session.accessToken,
                patch: patch
            )
        }
        let canonical = try await requestCoordinator.perform(clusterID: clusterID) {
            try await client.fetchServerSettings(cluster: cluster, accessToken: session.accessToken)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        guard workspaceDataGeneration == mutationGeneration else { return }
        serverSettings = canonical
    }

    private func refreshOverviewOnly(clusterID: UUID, displayName: String, token: String, dataGeneration: UInt64) async {
        guard let cluster = selectedCluster, cluster.id == clusterID else { return }
        let client = api
        do {
            let ov = try await requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchOverview(cluster: cluster, accessToken: token)
            }
            guard await isStillActiveCluster(clusterID) else { return }
            guard workspaceDataGeneration == dataGeneration else { return }
            overview = AdminOverviewState(clusterID: clusterID, clusterDisplayName: displayName, response: ov)
        } catch {
            guard workspaceDataGeneration == dataGeneration else { return }
            if Self.isUnauthorized(error) {
                requiresReauthentication = true
                try? sessionStore.clearSession(clusterID: clusterID)
                refreshActiveSession()
                clearWorkspaceState()
            }
        }
    }

    private func isStillActiveCluster(_ clusterID: UUID) async -> Bool {
        guard selectedClusterID == clusterID else { return false }
        let active = await requestCoordinator.activeClusterID
        return active == clusterID
    }

    private func clearWorkspaceState() {
        overview = nil
        registrationSettings = nil
        serverSettings = nil
        workspaceError = nil
        featureFlagDefinitions = []
        featureFlagOverrides = []
        featureFlagsError = nil
        isFeatureFlagsLoading = false
        debugMetricSessions = []
        debugMetricBatches = []
        debugMetricSessionsFilterAccountText = ""
        selectedDebugMetricSessionId = nil
        debugMetricsError = nil
        isDebugMetricSessionsLoading = false
        isDebugMetricBatchesLoading = false
        featureFlagsDataGeneration &+= 1
        debugSessionsDataGeneration &+= 1
        debugBatchesDataGeneration &+= 1
        clearUsersWorkspaceState()
    }

    private func clearUsersWorkspaceState() {
        userSearchDebounceTask?.cancel()
        userSearchDebounceTask = nil
        userListDataGeneration &+= 1
        users = []
        usersNextCursor = nil
        userSearchText = ""
        isUsersLoading = false
        usersError = nil
        userDetail = nil
        isUserDetailLoading = false
        userDetailError = nil
        lastProvisioningArtifact = nil
        provisionError = nil
        isProvisioning = false
        isProvisionSheetPresented = false
        cancelDisableFlow()
        cancelReactivateFlow()
    }

    func scheduleDebouncedUserListReload() {
        userSearchDebounceTask?.cancel()
        let generationSnapshot = userListDataGeneration
        userSearchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.userListDataGeneration == generationSnapshot else { return }
            await self.refreshUserList(replacingList: true)
        }
    }

    func refreshUserList(replacingList: Bool) async {
        guard let cluster = selectedCluster, let session = activeSession else {
            users = []
            usersNextCursor = nil
            return
        }
        let clusterID = cluster.id
        beginNewUserListEpochIfReplacing(replacingList)
        let generation = userListDataGeneration
        let query = userSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = replacingList ? nil : usersNextCursor
        isUsersLoading = true
        usersError = nil
        defer {
            if userListDataGeneration == generation {
                isUsersLoading = false
            }
        }
        let client = api
        do {
            let page = try await requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchUsers(
                    cluster: cluster,
                    accessToken: session.accessToken,
                    query: query.isEmpty ? nil : query,
                    status: nil,
                    cursor: cursor,
                    limit: 50
                )
            }
            guard await isStillActiveCluster(clusterID) else { return }
            guard userListDataGeneration == generation else { return }
            if replacingList {
                users = page.users
            } else {
                users.append(contentsOf: page.users)
            }
            usersNextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            guard userListDataGeneration == generation else { return }
            usersError = error.localizedDescription
        }
    }

    func loadMoreUsersIfNeeded() async {
        guard usersNextCursor != nil, !isUsersLoading else { return }
        await refreshUserList(replacingList: false)
    }

    func loadUserDetail(accountId: UUID) async {
        guard let cluster = selectedCluster, let session = activeSession else {
            userDetail = nil
            return
        }
        let clusterID = cluster.id
        userDetailError = nil
        isUserDetailLoading = true
        defer { isUserDetailLoading = false }
        let client = api
        do {
            let detail = try await requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchUserDetail(cluster: cluster, accessToken: session.accessToken, accountId: accountId)
            }
            guard await isStillActiveCluster(clusterID) else { return }
            userDetail = detail
        } catch is CancellationError {
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            userDetailError = error.localizedDescription
            userDetail = nil
        }
    }

    func clearUserDetail() {
        userDetail = nil
        userDetailError = nil
    }

    func beginProvisionUser() {
        provisionError = nil
        isProvisionSheetPresented = true
    }

    func cancelProvisionUser() {
        isProvisionSheetPresented = false
        provisionError = nil
    }

    func clearLastProvisioningArtifact() {
        lastProvisioningArtifact = nil
    }

    func provisionUser(handle: String?, profileName: String, profileBio: String?, ttlSeconds: UInt64 = 86_400) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        isProvisioning = true
        provisionError = nil
        defer { isProvisioning = false }
        let client = api
        let body = CreateAdminUserProvisionRequest(
            handle: Self.trimmedOptional(handle),
            profileName: trimmedName,
            profileBio: Self.trimmedOptional(profileBio),
            ttlSeconds: ttlSeconds
        )
        let response = try await requestCoordinator.perform(clusterID: clusterID) {
            try await client.provisionUser(cluster: cluster, accessToken: session.accessToken, request: body)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        lastProvisioningArtifact = AdminUserProvisioningArtifact.fromProvisionResponse(response)
        isProvisionSheetPresented = false
        await refreshUserList(replacingList: true)
        await refreshWorkspaceData()
    }

    func beginDisable(userID: UUID, clusterName: String) {
        guard let cluster = selectedCluster, cluster.displayName == clusterName else {
            return
        }
        disableTargetUserID = userID
        disableConfirmationText = ""
    }

    func cancelDisableFlow() {
        disableTargetUserID = nil
        disableConfirmationText = ""
        isDisablingUser = false
    }

    func confirmDisableUser() async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        guard let userID = disableTargetUserID else {
            throw AdminOperatorError.disableTargetMissing
        }
        let expected = cluster.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = disableConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed == expected else {
            throw AdminOperatorError.clusterNameConfirmationMismatch
        }
        let clusterID = cluster.id
        isDisablingUser = true
        defer { isDisablingUser = false }
        let client = api
        try await requestCoordinator.perform(clusterID: clusterID) {
            try await client.disableUser(cluster: cluster, accessToken: session.accessToken, accountId: userID, reason: nil)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        cancelDisableFlow()
        await refreshUserList(replacingList: true)
        if userDetail?.accountId == userID {
            await loadUserDetail(accountId: userID)
        }
        await refreshWorkspaceData()
    }

    func beginReactivate(userID: UUID, clusterName: String) {
        guard let cluster = selectedCluster, cluster.displayName == clusterName else {
            return
        }
        reactivateTargetUserID = userID
        reactivateConfirmationText = ""
    }

    func cancelReactivateFlow() {
        reactivateTargetUserID = nil
        reactivateConfirmationText = ""
        isReactivatingUser = false
    }

    func confirmReactivateUser() async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        guard let userID = reactivateTargetUserID else {
            throw AdminOperatorError.reactivateTargetMissing
        }
        let expected = cluster.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = reactivateConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed == expected else {
            throw AdminOperatorError.clusterNameConfirmationMismatch
        }
        let clusterID = cluster.id
        isReactivatingUser = true
        defer { isReactivatingUser = false }
        let client = api
        try await requestCoordinator.perform(clusterID: clusterID) {
            try await client.reactivateUser(cluster: cluster, accessToken: session.accessToken, accountId: userID)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        cancelReactivateFlow()
        await refreshUserList(replacingList: true)
        if userDetail?.accountId == userID {
            await loadUserDetail(accountId: userID)
        }
        await refreshWorkspaceData()
    }

    // MARK: - Feature flags

    func refreshFeatureFlagsWorkspace() async {
        guard let cluster = selectedCluster, let session = activeSession else {
            featureFlagDefinitions = []
            featureFlagOverrides = []
            return
        }
        let clusterID = cluster.id
        featureFlagsDataGeneration &+= 1
        let generation = featureFlagsDataGeneration
        isFeatureFlagsLoading = true
        featureFlagsError = nil
        defer {
            if featureFlagsDataGeneration == generation {
                isFeatureFlagsLoading = false
            }
        }
        let client = api
        do {
            async let defs = requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchFeatureFlagDefinitions(cluster: cluster, accessToken: session.accessToken)
            }
            async let ovs = requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchFeatureFlagOverrides(
                    cluster: cluster,
                    accessToken: session.accessToken,
                    query: FeatureFlagOverrideListQuery()
                )
            }
            let (d, o) = try await (defs, ovs)
            guard await isStillActiveCluster(clusterID) else { return }
            guard featureFlagsDataGeneration == generation else { return }
            featureFlagDefinitions = d.definitions
            featureFlagOverrides = o.overrides
        } catch is CancellationError {
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            guard featureFlagsDataGeneration == generation else { return }
            featureFlagsError = error.localizedDescription
        }
    }

    func createFeatureFlagDefinition(flagKey: String, description: String, defaultEnabled: Bool) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        let req = CreateAdminFeatureFlagDefinitionRequest(
            flagKey: flagKey.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            defaultEnabled: defaultEnabled
        )
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.createFeatureFlagDefinition(cluster: cluster, accessToken: session.accessToken, request: req)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        await refreshFeatureFlagsWorkspace()
    }

    func archiveFeatureFlagDefinition(flagKey: String) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        let unix = UInt64(Date().timeIntervalSince1970)
        let patch = PatchAdminFeatureFlagDefinitionRequest(deletedAtUnix: .set(unix))
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.patchFeatureFlagDefinition(
                cluster: cluster,
                accessToken: session.accessToken,
                flagKey: flagKey,
                patch: patch
            )
        }
        guard await isStillActiveCluster(clusterID) else { return }
        await refreshFeatureFlagsWorkspace()
    }

    func createFeatureFlagOverride(request: CreateAdminFeatureFlagOverrideRequest) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.createFeatureFlagOverride(cluster: cluster, accessToken: session.accessToken, request: request)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        await refreshFeatureFlagsWorkspace()
    }

    func deleteFeatureFlagOverride(overrideId: UUID) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.deleteFeatureFlagOverride(cluster: cluster, accessToken: session.accessToken, overrideId: overrideId)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        await refreshFeatureFlagsWorkspace()
    }

    // MARK: - Debug metrics

    func refreshDebugMetricSessions() async {
        guard let cluster = selectedCluster, let session = activeSession else {
            debugMetricSessions = []
            return
        }
        let clusterID = cluster.id
        debugSessionsDataGeneration &+= 1
        let generation = debugSessionsDataGeneration
        isDebugMetricSessionsLoading = true
        debugMetricsError = nil
        defer {
            if debugSessionsDataGeneration == generation {
                isDebugMetricSessionsLoading = false
            }
        }
        let trimmed = debugMetricSessionsFilterAccountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountFilter = UUID(uuidString: trimmed)
        let client = api
        do {
            let list = try await requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchDebugMetricSessions(
                    cluster: cluster,
                    accessToken: session.accessToken,
                    accountId: accountFilter,
                    limit: 200
                )
            }
            guard await isStillActiveCluster(clusterID) else { return }
            guard debugSessionsDataGeneration == generation else { return }
            debugMetricSessions = list.sessions
        } catch is CancellationError {
        } catch let err as AdminAPIError {
            guard await isStillActiveCluster(clusterID) else { return }
            guard debugSessionsDataGeneration == generation else { return }
            if case let .unexpectedStatus(code, _) = err, code == 404 {
                debugMetricsError = "Debug metrics are not enabled on this server."
                debugMetricSessions = []
            } else {
                debugMetricsError = err.localizedDescription
            }
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            guard debugSessionsDataGeneration == generation else { return }
            debugMetricsError = error.localizedDescription
        }
    }

    func refreshDebugMetricBatches() async {
        guard let cluster = selectedCluster, let session = activeSession,
              let sid = selectedDebugMetricSessionId,
              let sessionUUID = UUID(uuidString: sid)
        else {
            debugMetricBatches = []
            return
        }
        let clusterID = cluster.id
        debugBatchesDataGeneration &+= 1
        let generation = debugBatchesDataGeneration
        isDebugMetricBatchesLoading = true
        defer {
            if debugBatchesDataGeneration == generation {
                isDebugMetricBatchesLoading = false
            }
        }
        let client = api
        do {
            let list = try await requestCoordinator.perform(clusterID: clusterID) {
                try await client.fetchDebugMetricBatches(
                    cluster: cluster,
                    accessToken: session.accessToken,
                    sessionId: sessionUUID,
                    limit: 100
                )
            }
            guard await isStillActiveCluster(clusterID) else { return }
            guard debugBatchesDataGeneration == generation else { return }
            debugMetricBatches = list.batches
        } catch is CancellationError {
        } catch {
            guard await isStillActiveCluster(clusterID) else { return }
            guard debugBatchesDataGeneration == generation else { return }
            debugMetricsError = error.localizedDescription
        }
    }

    func createDebugMetricSession(accountId: UUID, deviceId: UUID?, userVisibleMessage: String, ttlSeconds: UInt64) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        let req = CreateAdminDebugMetricSessionRequest(
            accountId: accountId,
            deviceId: deviceId,
            userVisibleMessage: userVisibleMessage,
            ttlSeconds: ttlSeconds
        )
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.createDebugMetricSession(cluster: cluster, accessToken: session.accessToken, request: req)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        await refreshDebugMetricSessions()
    }

    func revokeDebugMetricSession(sessionId: UUID) async throws {
        guard let cluster = selectedCluster, let session = activeSession else {
            throw AdminOperatorError.noClusterOrSession
        }
        let clusterID = cluster.id
        _ = try await requestCoordinator.perform(clusterID: clusterID) {
            try await self.api.revokeDebugMetricSession(cluster: cluster, accessToken: session.accessToken, sessionId: sessionId)
        }
        guard await isStillActiveCluster(clusterID) else { return }
        let revoked = sessionId.uuidString.lowercased()
        if selectedDebugMetricSessionId?.lowercased() == revoked {
            selectedDebugMetricSessionId = nil
            debugMetricBatches = []
        }
        await refreshDebugMetricSessions()
    }

    private func beginNewUserListEpochIfReplacing(_ replacing: Bool) {
        if replacing {
            userListDataGeneration &+= 1
        }
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard let err = error as? AdminAPIError else { return false }
        switch err {
        case .unauthorized:
            return true
        case let .unexpectedStatus(code, _):
            return code == 401
        default:
            return false
        }
    }

    private func persistProfiles() {
        try? profileStore.save(profiles, lastSelectedClusterID: selectedClusterID)
    }

    private func refreshActiveSession() {
        guard let id = selectedClusterID else {
            activeSession = nil
            return
        }
        activeSession = try? sessionStore.loadSession(clusterID: id)
    }
}
