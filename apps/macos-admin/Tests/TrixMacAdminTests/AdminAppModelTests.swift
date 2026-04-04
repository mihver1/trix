import XCTest
@testable import TrixMacAdmin

// MARK: - Test harness (explicit session preload; no production placeholder sessions)

private extension AdminAppModel {
    /// Ephemeral on-disk stores. Call `saveSession` on `sessionStore` for each cluster that needs an active session before selecting that cluster.
    @MainActor
    static func testHarness(api: any AdminAPIProtocol) -> (model: AdminAppModel, sessionStore: AdminSessionStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let keychain = AdminKeychainStore(service: "com.softgrid.trixadmin.unit-tests.\(UUID().uuidString)")
        let sessionStore = AdminSessionStore(rootURL: root, keychain: keychain)
        let profileStore = ClusterProfileStore(rootURL: root)
        let model = AdminAppModel(profileStore: profileStore, sessionStore: sessionStore, api: api)
        return (model, sessionStore)
    }
}

private func seedActiveAdminSession(sessionStore: AdminSessionStore, clusterID: UUID) throws {
    let exp = UInt64(Date().timeIntervalSince1970) + 86_400 * 365
    try sessionStore.saveSession(
        AdminSessionResponse(accessToken: "unit-test-token", expiresAtUnix: exp, username: "admin"),
        clusterID: clusterID
    )
}

@MainActor
final class MockAdminAPIClient: AdminAPIProtocol {
    private struct OverviewJob: Sendable {
        let id: UUID
        let delayNanoseconds: UInt64
        let title: String

        init(delayNanoseconds: UInt64, title: String) {
            self.id = UUID()
            self.delayNanoseconds = delayNanoseconds
            self.title = title
        }
    }

    private var overviewQueues: [UUID: [OverviewJob]] = [:]
    private var registrationAllow: [UUID: Bool] = [:]

    var nextOverviewError: AdminAPIError?
    var updatedRegistrationStates: [Bool] = []

    var usersListResponse = AdminUserListResponse(users: [], nextCursor: nil)
    var nextProvisionResponse: CreateAdminUserProvisionResponse?
    var disabledUserIDs: [UUID] = []
    var reactivatedUserIDs: [UUID] = []

    func enqueueDelayedOverview(clusterID: UUID, title: String) {
        overviewQueues[clusterID, default: []].append(OverviewJob(delayNanoseconds: 200_000_000, title: title))
    }

    func enqueueImmediateOverview(clusterID: UUID, title: String) {
        overviewQueues[clusterID, default: []].append(OverviewJob(delayNanoseconds: 0, title: title))
    }

    private func gateUnauthorized() throws {
        if let e = nextOverviewError {
            throw e
        }
    }

    func createSession(
        cluster: ClusterProfile,
        username: String,
        password: String
    ) async throws -> AdminSessionResponse {
        let exp = UInt64(Date().timeIntervalSince1970) + 3600
        return AdminSessionResponse(accessToken: "mock-token", expiresAtUnix: exp, username: username)
    }

    func deleteSession(cluster: ClusterProfile, accessToken: String) async throws {}

    func fetchOverview(cluster: ClusterProfile, accessToken: String) async throws -> AdminOverviewResponse {
        try gateUnauthorized()
        let q = overviewQueues[cluster.id] ?? []
        guard !q.isEmpty else {
            return Self.makeOverview(version: cluster.displayName)
        }
        let job = q[0]
        if job.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: job.delayNanoseconds)
        }
        try gateUnauthorized()
        var q2 = overviewQueues[cluster.id] ?? []
        guard let first = q2.first, first.id == job.id else {
            return Self.makeOverview(version: cluster.displayName)
        }
        q2.removeFirst()
        overviewQueues[cluster.id] = q2
        return Self.makeOverview(version: job.title)
    }

    func fetchRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String
    ) async throws -> AdminRegistrationSettingsResponse {
        try gateUnauthorized()
        let v = registrationAllow[cluster.id] ?? true
        return AdminRegistrationSettingsResponse(allowPublicAccountRegistration: v)
    }

    func updateRegistrationSettings(
        cluster: ClusterProfile,
        accessToken: String,
        allowPublicAccountRegistration: Bool
    ) async throws -> AdminRegistrationSettingsResponse {
        try gateUnauthorized()
        updatedRegistrationStates.append(allowPublicAccountRegistration)
        registrationAllow[cluster.id] = allowPublicAccountRegistration
        return AdminRegistrationSettingsResponse(allowPublicAccountRegistration: allowPublicAccountRegistration)
    }

    func fetchServerSettings(cluster: ClusterProfile, accessToken: String) async throws -> AdminServerSettingsResponse {
        try gateUnauthorized()
        return AdminServerSettingsResponse(brandDisplayName: nil, supportContact: nil, policyText: nil)
    }

    func updateServerSettings(
        cluster: ClusterProfile,
        accessToken: String,
        patch: PatchAdminServerSettingsRequest
    ) async throws -> AdminServerSettingsResponse {
        try gateUnauthorized()
        return try await fetchServerSettings(cluster: cluster, accessToken: accessToken)
    }

    func fetchUsers(
        cluster: ClusterProfile,
        accessToken: String,
        query: String?,
        status: String?,
        cursor: String?,
        limit: Int?
    ) async throws -> AdminUserListResponse {
        try gateUnauthorized()
        _ = query
        _ = status
        _ = cursor
        _ = limit
        return usersListResponse
    }

    func fetchUserDetail(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID
    ) async throws -> AdminUserSummary {
        try gateUnauthorized()
        if let found = usersListResponse.users.first(where: { $0.accountId == accountId }) {
            return found
        }
        return AdminUserSummary(
            accountId: accountId,
            handle: nil,
            profileName: "User",
            profileBio: nil,
            createdAtUnix: 0,
            disabled: false
        )
    }

    func provisionUser(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminUserProvisionRequest
    ) async throws -> CreateAdminUserProvisionResponse {
        try gateUnauthorized()
        if let nextProvisionResponse {
            return nextProvisionResponse
        }
        let exp = UInt64(Date().timeIntervalSince1970) + 3600
        return CreateAdminUserProvisionResponse(
            provisionId: UUID().uuidString,
            provisionToken: "default-token",
            expiresAtUnix: exp,
            profileName: request.profileName,
            handle: request.handle,
            profileBio: request.profileBio
        )
    }

    func disableUser(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID,
        reason: String?
    ) async throws {
        try gateUnauthorized()
        _ = reason
        disabledUserIDs.append(accountId)
    }

    func reactivateUser(cluster: ClusterProfile, accessToken: String, accountId: UUID) async throws {
        try gateUnauthorized()
        reactivatedUserIDs.append(accountId)
    }

    private static func makeOverview(version: String) -> AdminOverviewResponse {
        AdminOverviewResponse(
            status: "ok",
            service: "trix",
            version: version,
            gitSha: nil,
            healthStatus: .ok,
            uptimeMs: 0,
            allowPublicAccountRegistration: true,
            userCount: 0,
            disabledUserCount: 0,
            adminUsername: "admin",
            adminSessionExpiresAtUnix: 9_999_999_999,
            debugMetricsEnabled: false
        )
    }

    func fetchFeatureFlagDefinitions(
        cluster: ClusterProfile,
        accessToken: String
    ) async throws -> AdminFeatureFlagDefinitionListResponse {
        try gateUnauthorized()
        return AdminFeatureFlagDefinitionListResponse(definitions: [])
    }

    func createFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition {
        try gateUnauthorized()
        return AdminFeatureFlagDefinition(
            flagKey: request.flagKey,
            description: request.description,
            defaultEnabled: request.defaultEnabled,
            deletedAtUnix: nil,
            updatedAtUnix: 0
        )
    }

    func patchFeatureFlagDefinition(
        cluster: ClusterProfile,
        accessToken: String,
        flagKey: String,
        patch: PatchAdminFeatureFlagDefinitionRequest
    ) async throws -> AdminFeatureFlagDefinition {
        try gateUnauthorized()
        let del: UInt64?
        switch patch.deletedAtUnix {
        case .unchanged, .clear:
            del = nil
        case .set(let u):
            del = u
        }
        return AdminFeatureFlagDefinition(
            flagKey: flagKey,
            description: patch.description ?? "",
            defaultEnabled: patch.defaultEnabled ?? false,
            deletedAtUnix: del,
            updatedAtUnix: 0
        )
    }

    func fetchFeatureFlagOverrides(
        cluster: ClusterProfile,
        accessToken: String,
        query: FeatureFlagOverrideListQuery
    ) async throws -> AdminFeatureFlagOverrideListResponse {
        try gateUnauthorized()
        _ = query
        return AdminFeatureFlagOverrideListResponse(overrides: [])
    }

    func createFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride {
        try gateUnauthorized()
        return AdminFeatureFlagOverride(
            overrideId: UUID().uuidString,
            flagKey: request.flagKey,
            scope: request.scope,
            platform: request.platform,
            accountId: request.accountId,
            deviceId: request.deviceId,
            enabled: request.enabled,
            expiresAtUnix: request.expiresAtUnix,
            updatedAtUnix: 0
        )
    }

    func patchFeatureFlagOverride(
        cluster: ClusterProfile,
        accessToken: String,
        overrideId: UUID,
        patch: PatchAdminFeatureFlagOverrideRequest
    ) async throws -> AdminFeatureFlagOverride {
        try gateUnauthorized()
        return AdminFeatureFlagOverride(
            overrideId: overrideId.uuidString,
            flagKey: "mock",
            scope: .global,
            platform: nil,
            accountId: nil,
            deviceId: nil,
            enabled: patch.enabled ?? true,
            expiresAtUnix: nil,
            updatedAtUnix: 0
        )
    }

    func deleteFeatureFlagOverride(cluster: ClusterProfile, accessToken: String, overrideId: UUID) async throws {
        try gateUnauthorized()
        _ = overrideId
    }

    func fetchDebugMetricSessions(
        cluster: ClusterProfile,
        accessToken: String,
        accountId: UUID?,
        limit: Int?
    ) async throws -> AdminDebugMetricSessionListResponse {
        try gateUnauthorized()
        _ = accountId
        _ = limit
        return AdminDebugMetricSessionListResponse(sessions: [])
    }

    func createDebugMetricSession(
        cluster: ClusterProfile,
        accessToken: String,
        request: CreateAdminDebugMetricSessionRequest
    ) async throws -> AdminDebugMetricSessionResponse {
        try gateUnauthorized()
        let session = AdminDebugMetricSession(
            sessionId: UUID().uuidString,
            accountId: request.accountId,
            deviceId: request.deviceId,
            userVisibleMessage: request.userVisibleMessage,
            createdAtUnix: 0,
            expiresAtUnix: 0,
            revokedAtUnix: nil,
            createdByAdmin: "mock"
        )
        return AdminDebugMetricSessionResponse(session: session)
    }

    func revokeDebugMetricSession(cluster: ClusterProfile, accessToken: String, sessionId: UUID) async throws {
        try gateUnauthorized()
        _ = sessionId
    }

    func fetchDebugMetricBatches(
        cluster: ClusterProfile,
        accessToken: String,
        sessionId: UUID,
        limit: Int?
    ) async throws -> AdminDebugMetricBatchListResponse {
        try gateUnauthorized()
        _ = sessionId
        _ = limit
        return AdminDebugMetricBatchListResponse(batches: [])
    }
}

@MainActor
final class AdminAppModelTests: XCTestCase {
    func testSwitchClusterDropsStaleOverviewResponse() async throws {
        let client = MockAdminAPIClient()
        let eu = ClusterProfile(id: UUID(), displayName: "prod-eu", baseURL: URL(string: "https://eu.example")!, environmentLabel: "prod")
        let us = ClusterProfile(id: UUID(), displayName: "STAGING", baseURL: URL(string: "https://staging.example")!, environmentLabel: "staging")
        let (model, sessionStore) = AdminAppModel.testHarness(api: client)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: eu.id)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: us.id)

        client.enqueueDelayedOverview(clusterID: eu.id, title: "EU")
        client.enqueueImmediateOverview(clusterID: us.id, title: "STAGING")

        await model.selectCluster(eu)
        await model.selectCluster(us)
        await model.refreshWorkspaceData()

        XCTAssertEqual(model.overview?.clusterDisplayName, "STAGING")
    }

    func testTogglePublicRegistrationRefreshesCanonicalSettings() async throws {
        let client = MockAdminAPIClient()
        let cluster = ClusterProfile(id: UUID(), displayName: "prod-eu", baseURL: URL(string: "https://eu.example")!, environmentLabel: "prod")
        let (model, sessionStore) = AdminAppModel.testHarness(api: client)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: cluster.id)

        await model.selectCluster(cluster)
        try await model.setPublicRegistrationEnabled(false)

        XCTAssertEqual(client.updatedRegistrationStates, [false])
        XCTAssertEqual(model.registrationSettings?.allowPublicAccountRegistration, false)
    }

    func testExpiredSessionSurfacesReconnectRequirement() async throws {
        let client = MockAdminAPIClient()
        client.nextOverviewError = .unauthorized
        let cluster = ClusterProfile(
            id: UUID(),
            displayName: "prod-eu",
            baseURL: URL(string: "https://eu.example")!,
            environmentLabel: "prod",
            authMode: .localCredentials
        )
        let (model, sessionStore) = AdminAppModel.testHarness(api: client)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: cluster.id)

        await model.selectCluster(cluster)
        await model.refreshWorkspaceData()

        XCTAssertTrue(model.requiresReauthentication)
    }

    func testConfirmDisableUserRequiresMatchingClusterName() async throws {
        let client = MockAdminAPIClient()
        let cluster = ClusterProfile(
            id: UUID(),
            displayName: "prod-eu",
            baseURL: URL(string: "https://eu.example")!,
            environmentLabel: "prod"
        )
        let (model, sessionStore) = AdminAppModel.testHarness(api: client)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: cluster.id)

        await model.selectCluster(cluster)
        let userID = UUID()
        model.beginDisable(userID: userID, clusterName: "prod-eu")
        model.disableConfirmationText = "prod-eu"
        try await model.confirmDisableUser()

        XCTAssertEqual(client.disabledUserIDs, [userID])
    }

    func testProvisionFlowStoresReturnedOnboardingArtifact() async throws {
        let client = MockAdminAPIClient()
        client.nextProvisionResponse = CreateAdminUserProvisionResponse(
            provisionId: UUID().uuidString,
            provisionToken: "invite-token",
            expiresAtUnix: 1_700_000_000,
            profileName: "Alice",
            handle: "alice",
            profileBio: nil
        )
        let cluster = ClusterProfile(
            id: UUID(),
            displayName: "prod-eu",
            baseURL: URL(string: "https://eu.example")!,
            environmentLabel: "prod"
        )
        let (model, sessionStore) = AdminAppModel.testHarness(api: client)
        try seedActiveAdminSession(sessionStore: sessionStore, clusterID: cluster.id)

        await model.selectCluster(cluster)
        try await model.provisionUser(handle: "alice", profileName: "Alice", profileBio: nil)

        XCTAssertEqual(model.lastProvisioningArtifact?.onboardingToken, "invite-token")
    }
}
