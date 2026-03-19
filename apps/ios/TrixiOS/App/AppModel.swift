import Foundation
import UIKit

private let trixDebugCipherSuite = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"

struct CreateAccountForm {
    var profileName = ""
    var handle = ""
    var profileBio = ""
    var deviceDisplayName = UIDevice.current.name
    let platform = "ios"

    var canSubmit: Bool {
        !profileName.trix_trimmed().isEmpty && !deviceDisplayName.trix_trimmed().isEmpty
    }
}

struct LinkExistingAccountForm {
    var linkPayload = ""
    var deviceDisplayName = UIDevice.current.name
    let platform = "ios"

    var canSubmit: Bool {
        !linkPayload.trix_trimmed().isEmpty && !deviceDisplayName.trix_trimmed().isEmpty
    }
}

struct DashboardData {
    let session: AuthSessionResponse
    let profile: AccountProfileResponse
    let devices: [DeviceSummary]
    let historySyncJobs: [HistorySyncJobSummary]
    let chats: [ChatSummary]
    let inboxItems: [InboxItem]

    var sessionExpirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(session.expiresAtUnix))
    }

    var currentDevice: DeviceSummary? {
        devices.first { $0.deviceId == profile.deviceId }
    }

    var maxInboxId: UInt64? {
        inboxItems.map(\.inboxId).max()
    }
}

struct ChatSnapshot {
    let detail: ChatDetailResponse
    let history: [MessageEnvelope]
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var localIdentity: LocalDeviceIdentity?
    @Published private(set) var dashboard: DashboardData?
    @Published private(set) var activeLinkIntent: CreateLinkIntentResponse?
    @Published private(set) var systemSnapshot: ServerSnapshot?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let identityStore: LocalDeviceIdentityStore
    private var hasStarted = false

    init(identityStore: LocalDeviceIdentityStore = LocalDeviceIdentityStore()) {
        self.identityStore = identityStore
    }

    var hasProvisionedIdentity: Bool {
        localIdentity != nil
    }

    var isAwaitingApproval: Bool {
        localIdentity?.trustState == .pendingApproval && dashboard == nil
    }

    var canManageAccountDevices: Bool {
        localIdentity?.hasAccountRootKey ?? false
    }

    func start(baseURLString: String) async {
        guard !hasStarted else {
            return
        }

        hasStarted = true

        do {
            localIdentity = try identityStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }

        await refresh(baseURLString: baseURLString)
    }

    func refresh(baseURLString: String) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)

            if let localIdentity {
                do {
                    try await refreshAuthenticatedState(client: client, identity: localIdentity)
                } catch let error as APIError where isPendingApprovalAuthFailure(error, identity: localIdentity) {
                    dashboard = nil
                    systemSnapshot = try? await fetchSystemSnapshot(client: client)
                    lastUpdatedAt = Date()
                }
            } else {
                dashboard = nil
                systemSnapshot = try await fetchSystemSnapshot(client: client)
                lastUpdatedAt = Date()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccount(baseURLString: String, form: CreateAccountForm) async {
        guard !isLoading else {
            return
        }

        let profileName = form.profileName.trix_trimmed()
        let deviceDisplayName = form.deviceDisplayName.trix_trimmed()

        guard !profileName.isEmpty else {
            errorMessage = "Profile name must not be empty."
            return
        }
        guard !deviceDisplayName.isEmpty else {
            errorMessage = "Device name must not be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let request = try bootstrapMaterial.makeCreateAccountRequest(
                profileName: profileName,
                handle: form.handle.trix_trimmedOrNil(),
                profileBio: form.profileBio.trix_trimmedOrNil(),
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )
            let response: CreateAccountResponse = try await client.post("/v0/accounts", body: request)
            let localIdentity = bootstrapMaterial.makeLocalIdentity(
                accountId: response.accountId,
                deviceId: response.deviceId,
                accountSyncChatId: response.accountSyncChatId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity

            try await refreshAuthenticatedState(client: client, identity: localIdentity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeLinkIntent(
        baseURLString: String,
        payload: LinkIntentPayload,
        form: LinkExistingAccountForm
    ) async {
        guard !isLoading else {
            return
        }

        let deviceDisplayName = form.deviceDisplayName.trix_trimmed()
        guard !deviceDisplayName.isEmpty else {
            errorMessage = "Device name must not be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let client = try APIClient(baseURLString: baseURLString)
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let request = try bootstrapMaterial.makeCompleteLinkIntentRequest(
                linkToken: payload.linkToken,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )
            let response: CompleteLinkIntentResponse = try await client.post(
                "/v0/devices/link-intents/\(payload.linkIntentId)/complete",
                body: request
            )
            let localIdentity = bootstrapMaterial.makeLinkedLocalIdentity(
                accountId: response.accountId,
                deviceId: response.pendingDeviceId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            dashboard = nil
            activeLinkIntent = nil
            systemSnapshot = try await fetchSystemSnapshot(client: client)
            lastUpdatedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetLocalDevice() {
        do {
            try identityStore.delete()
            localIdentity = nil
            dashboard = nil
            activeLinkIntent = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createLinkIntent(baseURLString: String) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response: CreateLinkIntentResponse = try await context.client.post(
                "/v0/devices/link-intents",
                body: EmptyRequest(),
                accessToken: context.session.accessToken
            )
            activeLinkIntent = response
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissActiveLinkIntent() {
        activeLinkIntent = nil
    }

    @discardableResult
    func approvePendingDevice(
        baseURLString: String,
        deviceId: String
    ) async -> ApproveDeviceResponse? {
        guard !isLoading else {
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let approvePayload: DeviceApprovePayloadResponse = try await context.client.get(
                "/v0/devices/\(deviceId)/approve-payload",
                accessToken: context.session.accessToken
            )
            guard let bootstrapPayload = Data(base64Encoded: approvePayload.bootstrapPayloadB64) else {
                throw AppModelError.invalidBootstrapPayload
            }

            let signature = try context.identity.signAccountBootstrapPayload(bootstrapPayload)
            let response: ApproveDeviceResponse = try await context.client.post(
                "/v0/devices/\(deviceId)/approve",
                body: ApproveDeviceRequest(
                    accountRootSignatureB64: signature.base64EncodedString()
                ),
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func revokeDevice(
        baseURLString: String,
        deviceId: String,
        reason: String
    ) async {
        guard !isLoading else {
            return
        }

        let trimmedReason = reason.trix_trimmed()
        guard !trimmedReason.isEmpty else {
            errorMessage = "Revoke reason must not be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let signature = try context.identity.signDeviceRevoke(deviceId: deviceId, reason: trimmedReason)

            let _: RevokeDeviceResponse = try await context.client.post(
                "/v0/devices/\(deviceId)/revoke",
                body: RevokeDeviceRequest(
                    reason: trimmedReason,
                    accountRootSignatureB64: signature.base64EncodedString()
                ),
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeHistorySyncJob(
        baseURLString: String,
        jobId: String
    ) async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)

            let _: CompleteHistorySyncJobResponse = try await context.client.post(
                "/v0/history-sync/jobs/\(jobId)/complete",
                body: CompleteHistorySyncJobRequest(cursorJson: nil),
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func publishDebugKeyPackages(
        baseURLString: String,
        count: Int = 5,
        cipherSuite: String = trixDebugCipherSuite
    ) async -> PublishKeyPackagesResponse? {
        guard !isLoading else {
            return nil
        }

        guard count > 0 else {
            errorMessage = "Key package count must be greater than zero."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let packages = (0 ..< count).map { index in
                PublishKeyPackageItem(
                    cipherSuite: cipherSuite,
                    keyPackageB64: makeDebugKeyPackagePayload(
                        deviceId: context.identity.deviceId,
                        index: index
                    )
                )
            }

            let response: PublishKeyPackagesResponse = try await context.client.post(
                "/v0/key-packages:publish",
                body: PublishKeyPackagesRequest(packages: packages),
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createChat(
        baseURLString: String,
        chatType: ChatType,
        title: String,
        participantAccountIds: [String]
    ) async -> CreateChatResponse? {
        guard !isLoading else {
            return nil
        }

        let participantAccountIds = sanitizeIdentifiers(participantAccountIds)

        guard chatType != .accountSync else {
            errorMessage = "Account sync chats are managed by the server."
            return nil
        }
        guard !participantAccountIds.isEmpty else {
            errorMessage = "At least one participant account is required."
            return nil
        }
        guard chatType != .dm || participantAccountIds.count == 1 else {
            errorMessage = "DM chats require exactly one peer account."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let reservedPackages = try await reserveKeyPackagesForAccounts(
                client: context.client,
                accessToken: context.session.accessToken,
                accountIds: participantAccountIds
            )

            let request = CreateChatRequest(
                chatType: chatType,
                title: title.trix_trimmedOrNil(),
                participantAccountIds: participantAccountIds,
                reservedKeyPackageIds: reservedPackages.map(\.keyPackageId),
                initialCommit: try makeDebugControlMessage(
                    label: "chat-create-commit",
                    context: [
                        "chat_type": chatType.rawValue,
                        "participant_count": String(participantAccountIds.count)
                    ]
                ),
                welcomeMessage: try makeDebugControlMessage(
                    label: "chat-create-welcome",
                    context: [
                        "chat_type": chatType.rawValue
                    ]
                )
            )

            let response: CreateChatResponse = try await context.client.post(
                "/v0/chats",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func addChatMembers(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        participantAccountIds: [String]
    ) async -> ModifyChatMembersResponse? {
        guard !isLoading else {
            return nil
        }

        let participantAccountIds = sanitizeIdentifiers(participantAccountIds)
        guard !participantAccountIds.isEmpty else {
            errorMessage = "At least one participant account is required."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let reservedPackages = try await reserveKeyPackagesForAccounts(
                client: context.client,
                accessToken: context.session.accessToken,
                accountIds: participantAccountIds
            )

            let request = ModifyChatMembersRequest(
                epoch: epoch,
                participantAccountIds: participantAccountIds,
                reservedKeyPackageIds: reservedPackages.map(\.keyPackageId),
                commitMessage: try makeDebugControlMessage(
                    label: "chat-members-add-commit",
                    context: ["chat_id": chatId]
                ),
                welcomeMessage: try makeDebugControlMessage(
                    label: "chat-members-add-welcome",
                    context: ["chat_id": chatId]
                )
            )

            let response: ModifyChatMembersResponse = try await context.client.post(
                "/v0/chats/\(chatId)/members:add",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func removeChatMembers(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        participantAccountIds: [String]
    ) async -> ModifyChatMembersResponse? {
        guard !isLoading else {
            return nil
        }

        let participantAccountIds = sanitizeIdentifiers(participantAccountIds)
        guard !participantAccountIds.isEmpty else {
            errorMessage = "At least one participant account is required."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let request = ModifyChatMembersRequest(
                epoch: epoch,
                participantAccountIds: participantAccountIds,
                reservedKeyPackageIds: [],
                commitMessage: try makeDebugControlMessage(
                    label: "chat-members-remove-commit",
                    context: ["chat_id": chatId]
                ),
                welcomeMessage: nil
            )

            let response: ModifyChatMembersResponse = try await context.client.post(
                "/v0/chats/\(chatId)/members:remove",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func addChatDevices(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        accountId: String,
        deviceIds: [String]
    ) async -> ModifyChatDevicesResponse? {
        guard !isLoading else {
            return nil
        }

        let accountId = accountId.trix_trimmed()
        let deviceIds = sanitizeIdentifiers(deviceIds)

        guard !accountId.isEmpty else {
            errorMessage = "Account ID must not be empty."
            return nil
        }
        guard !deviceIds.isEmpty else {
            errorMessage = "At least one device ID is required."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let reservedPackages = try await reserveKeyPackagesForDevices(
                client: context.client,
                accessToken: context.session.accessToken,
                accountId: accountId,
                deviceIds: deviceIds
            )

            let request = ModifyChatDevicesRequest(
                epoch: epoch,
                deviceIds: deviceIds,
                reservedKeyPackageIds: reservedPackages.map(\.keyPackageId),
                commitMessage: try makeDebugControlMessage(
                    label: "chat-devices-add-commit",
                    context: ["chat_id": chatId, "account_id": accountId]
                ),
                welcomeMessage: try makeDebugControlMessage(
                    label: "chat-devices-add-welcome",
                    context: ["chat_id": chatId]
                )
            )

            let response: ModifyChatDevicesResponse = try await context.client.post(
                "/v0/chats/\(chatId)/devices:add",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func removeChatDevices(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        deviceIds: [String]
    ) async -> ModifyChatDevicesResponse? {
        guard !isLoading else {
            return nil
        }

        let deviceIds = sanitizeIdentifiers(deviceIds)
        guard !deviceIds.isEmpty else {
            errorMessage = "At least one device ID is required."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let request = ModifyChatDevicesRequest(
                epoch: epoch,
                deviceIds: deviceIds,
                reservedKeyPackageIds: [],
                commitMessage: try makeDebugControlMessage(
                    label: "chat-devices-remove-commit",
                    context: ["chat_id": chatId]
                ),
                welcomeMessage: nil
            )

            let response: ModifyChatDevicesResponse = try await context.client.post(
                "/v0/chats/\(chatId)/devices:remove",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func postDebugMessage(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        plaintext: String
    ) async -> CreateMessageResponse? {
        guard !isLoading else {
            return nil
        }

        let plaintext = plaintext.trix_trimmed()
        guard !plaintext.isEmpty else {
            errorMessage = "Message text must not be empty."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let request = CreateMessageRequest(
                messageId: UUID().uuidString.lowercased(),
                epoch: epoch,
                messageKind: .application,
                contentType: .text,
                ciphertextB64: Data(plaintext.utf8).base64EncodedString(),
                aadJson: .object([
                    "debug_plaintext": .string(plaintext),
                    "source": .string("ios_poc")
                ])
            )

            let response: CreateMessageResponse = try await context.client.post(
                "/v0/chats/\(chatId)/messages",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func acknowledgeInbox(
        baseURLString: String,
        inboxIds: [UInt64]
    ) async -> AckInboxResponse? {
        guard !isLoading else {
            return nil
        }

        let inboxIds = Array(Set(inboxIds)).sorted()
        guard !inboxIds.isEmpty else {
            errorMessage = "At least one inbox item is required."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response: AckInboxResponse = try await context.client.post(
                "/v0/inbox/ack",
                body: AckInboxRequest(inboxIds: inboxIds),
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func pollInboxIncremental(
        baseURLString: String,
        limit: Int = 50
    ) async -> InboxResponse? {
        guard !isLoading else {
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response: InboxResponse = try await context.client.get(
                makeInboxPath(
                    afterInboxId: dashboard?.maxInboxId,
                    limit: limit
                ),
                accessToken: context.session.accessToken
            )

            if !response.items.isEmpty {
                updateDashboardInboxItems(response.items)
            }
            lastUpdatedAt = Date()
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func leaseInboxBatch(
        baseURLString: String,
        leaseOwner: String? = nil,
        limit: Int = 25,
        afterInboxId: UInt64? = nil,
        leaseTtlSeconds: UInt64? = nil
    ) async -> LeaseInboxResponse? {
        guard !isLoading else {
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response: LeaseInboxResponse = try await context.client.post(
                "/v0/inbox/lease",
                body: LeaseInboxRequest(
                    leaseOwner: leaseOwner,
                    limit: limit,
                    afterInboxId: afterInboxId,
                    leaseTtlSeconds: leaseTtlSeconds
                ),
                accessToken: context.session.accessToken
            )

            lastUpdatedAt = Date()
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func fetchChatSnapshot(
        baseURLString: String,
        chatId: String
    ) async throws -> ChatSnapshot {
        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        async let detail: ChatDetailResponse = context.client.get(
            "/v0/chats/\(chatId)",
            accessToken: context.session.accessToken
        )
        async let history: ChatHistoryResponse = context.client.get(
            "/v0/chats/\(chatId)/history?limit=100",
            accessToken: context.session.accessToken
        )

        return try await ChatSnapshot(
            detail: detail,
            history: history.messages
        )
    }

    private func refreshAuthenticatedState(
        client: APIClient,
        identity: LocalDeviceIdentity
    ) async throws {
        async let systemSnapshot = fetchSystemSnapshot(client: client)
        let session = try await authenticate(client: client, identity: identity)
        async let profile: AccountProfileResponse = client.get(
            "/v0/accounts/me",
            accessToken: session.accessToken
        )
        async let devices: DeviceListResponse = client.get(
            "/v0/devices",
            accessToken: session.accessToken
        )
        async let historySyncJobs: HistorySyncJobListResponse = client.get(
            "/v0/history-sync/jobs?limit=50",
            accessToken: session.accessToken
        )
        async let chats: ChatListResponse = client.get(
            "/v0/chats",
            accessToken: session.accessToken
        )
        async let inbox: InboxResponse = client.get(
            makeInboxPath(afterInboxId: nil, limit: 50),
            accessToken: session.accessToken
        )

        if identity.trustState != .active {
            let activeIdentity = identity.markingActive()
            try identityStore.save(activeIdentity)
            localIdentity = activeIdentity
        }

        self.systemSnapshot = try await systemSnapshot
        dashboard = try await DashboardData(
            session: session,
            profile: profile,
            devices: devices.devices,
            historySyncJobs: historySyncJobs.jobs,
            chats: chats.chats,
            inboxItems: inbox.items
        )
        lastUpdatedAt = Date()
    }

    private func authenticate(
        client: APIClient,
        identity: LocalDeviceIdentity
    ) async throws -> AuthSessionResponse {
        let challenge: AuthChallengeResponse = try await client.post(
            "/v0/auth/challenge",
            body: AuthChallengeRequest(deviceId: identity.deviceId)
        )
        let challengeBytes = try Data.trix_base64Decoded(challenge.challengeB64)
        let signatureBytes = try identity.signChallenge(challengeBytes)

        return try await client.post(
            "/v0/auth/session",
            body: AuthSessionRequest(
                deviceId: identity.deviceId,
                challengeId: challenge.challengeId,
                signatureB64: signatureBytes.base64EncodedString()
            )
        )
    }

    private func fetchSystemSnapshot(client: APIClient) async throws -> ServerSnapshot {
        async let health: HealthResponse = client.get("/v0/system/health")
        async let version: VersionResponse = client.get("/v0/system/version")

        return try await ServerSnapshot(health: health, version: version)
    }

    private func makeAuthenticatedContext(baseURLString: String) async throws -> AuthenticatedContext {
        guard let identity = localIdentity else {
            throw AppModelError.localIdentityMissing
        }

        let client = try APIClient(baseURLString: baseURLString)
        let session = try await authenticate(client: client, identity: identity)
        return AuthenticatedContext(client: client, identity: identity, session: session)
    }

    private func reserveKeyPackagesForAccounts(
        client: APIClient,
        accessToken: String,
        accountIds: [String]
    ) async throws -> [ReservedKeyPackage] {
        var reservedPackages: [ReservedKeyPackage] = []

        for accountId in sanitizeIdentifiers(accountIds) {
            let response: AccountKeyPackagesResponse = try await client.get(
                "/v0/accounts/\(accountId)/key-packages",
                accessToken: accessToken
            )
            reservedPackages.append(contentsOf: response.packages)
        }

        return reservedPackages
    }

    private func reserveKeyPackagesForDevices(
        client: APIClient,
        accessToken: String,
        accountId: String,
        deviceIds: [String]
    ) async throws -> [ReservedKeyPackage] {
        let response: AccountKeyPackagesResponse = try await client.post(
            "/v0/key-packages:reserve",
            body: ReserveKeyPackagesRequest(
                accountId: accountId,
                deviceIds: sanitizeIdentifiers(deviceIds)
            ),
            accessToken: accessToken
        )

        return response.packages
    }

    private func makeInboxPath(afterInboxId: UInt64?, limit: Int) -> String {
        let clampedLimit = min(max(limit, 1), 500)

        if let afterInboxId {
            return "/v0/inbox?after_inbox_id=\(afterInboxId)&limit=\(clampedLimit)"
        }

        return "/v0/inbox?limit=\(clampedLimit)"
    }

    private func updateDashboardInboxItems(_ newItems: [InboxItem]) {
        guard let dashboard else {
            return
        }

        let mergedInboxItems = mergeInboxItems(
            existing: dashboard.inboxItems,
            incoming: newItems
        )
        self.dashboard = DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: dashboard.chats,
            inboxItems: mergedInboxItems
        )
    }

    private func mergeInboxItems(
        existing: [InboxItem],
        incoming: [InboxItem]
    ) -> [InboxItem] {
        var mergedById = Dictionary(uniqueKeysWithValues: existing.map { ($0.inboxId, $0) })

        for item in incoming {
            mergedById[item.inboxId] = item
        }

        return mergedById
            .values
            .sorted { $0.inboxId < $1.inboxId }
    }

    private func makeDebugKeyPackagePayload(deviceId: String, index: Int) -> String {
        let raw = "trix-ios-debug-key-package:\(deviceId):\(index):\(UUID().uuidString.lowercased())"
        return Data(raw.utf8).base64EncodedString()
    }

    private func makeDebugControlMessage(
        label: String,
        context: [String: String]
    ) throws -> ControlMessageInput {
        let aadContext = context.reduce(into: [String: JSONValue]()) { partialResult, item in
            partialResult[item.key] = .string(item.value)
        }
        let body = JSONValue.object([
            "label": .string(label),
            "issued_at": .string(ISO8601DateFormatter().string(from: Date())),
            "context": .object(aadContext)
        ])

        let payloadData = try JSONEncoder().encode(body)
        return ControlMessageInput(
            messageId: UUID().uuidString.lowercased(),
            ciphertextB64: payloadData.base64EncodedString(),
            aadJson: body
        )
    }

    private func sanitizeIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var sanitized: [String] = []

        for identifier in identifiers.map({ $0.trix_trimmed() }).filter({ !$0.isEmpty }) {
            if seen.insert(identifier).inserted {
                sanitized.append(identifier)
            }
        }

        return sanitized
    }

    private func isPendingApprovalAuthFailure(
        _ error: APIError,
        identity: LocalDeviceIdentity
    ) -> Bool {
        guard identity.trustState == .pendingApproval else {
            return false
        }

        if case let .http(statusCode, message) = error {
            return statusCode == 401 && (message?.contains("device is not active") ?? false)
        }

        return false
    }
}

private struct AuthenticatedContext {
    let client: APIClient
    let identity: LocalDeviceIdentity
    let session: AuthSessionResponse
}

private enum AppModelError: LocalizedError {
    case localIdentityMissing
    case invalidBootstrapPayload

    var errorDescription: String? {
        switch self {
        case .localIdentityMissing:
            return "Local identity is missing."
        case .invalidBootstrapPayload:
            return "Server bootstrap payload is invalid."
        }
    }
}

private extension String {
    func trix_trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trix_trimmedOrNil() -> String? {
        let trimmed = trix_trimmed()
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct EmptyRequest: Encodable {}
