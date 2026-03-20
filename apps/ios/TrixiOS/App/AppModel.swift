import Foundation
import UIKit

@MainActor
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

@MainActor
struct LinkExistingAccountForm {
    var linkPayload = ""
    var deviceDisplayName = UIDevice.current.name
    let platform = "ios"

    var canSubmit: Bool {
        !linkPayload.trix_trimmed().isEmpty && !deviceDisplayName.trix_trimmed().isEmpty
    }
}

@MainActor
struct EditProfileForm {
    var profileName = ""
    var handle = ""
    var profileBio = ""

    init() {}

    init(profile: AccountProfileResponse) {
        profileName = profile.profileName
        handle = profile.handle ?? ""
        profileBio = profile.profileBio ?? ""
    }

    var canSubmit: Bool {
        !profileName.trix_trimmed().isEmpty
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
    let localTimelineItems: [LocalTimelineItemSnapshot]
    let historySource: ChatHistorySource

    var latestTimelineAnchorId: String? {
        localTimelineItems.last?.id ?? history.last?.id
    }
}

struct DebugAttachmentSendOutcome {
    let createMessage: CreateMessageResponse
    let blobId: String
    let fileName: String?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var localIdentity: LocalDeviceIdentity?
    @Published private(set) var localCoreState: LocalCoreStateSnapshot?
    @Published private(set) var dashboard: DashboardData?
    @Published private(set) var activeLinkIntent: CreateLinkIntentResponse?
    @Published private(set) var systemSnapshot: ServerSnapshot?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let identityStore: LocalDeviceIdentityStore
    private var hasStarted = false
    private var directoryAccountCache: [String: DirectoryAccountSummary] = [:]

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
                    updateLocalCoreStateSnapshot(identity: localIdentity)
                    systemSnapshot = try? await fetchSystemSnapshot(client: client)
                    lastUpdatedAt = Date()
                }
            } else {
                dashboard = nil
                localCoreState = nil
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
            let response = try TrixCoreServerBridge.createAccount(
                baseURLString: baseURLString,
                form: form,
                bootstrapMaterial: bootstrapMaterial
            )
            let localIdentity = bootstrapMaterial.makeLocalIdentity(
                accountId: response.accountId,
                deviceId: response.deviceId,
                accountSyncChatId: response.accountSyncChatId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            updateLocalCoreStateSnapshot(identity: localIdentity)

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
            let response = try TrixCoreServerBridge.completeLinkIntent(
                baseURLString: baseURLString,
                payload: payload,
                form: form,
                bootstrapMaterial: bootstrapMaterial
            )
            let localIdentity = bootstrapMaterial.makeLinkedLocalIdentity(
                accountId: response.accountId,
                deviceId: response.pendingDeviceId,
                deviceDisplayName: deviceDisplayName,
                platform: form.platform
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            updateLocalCoreStateSnapshot(identity: localIdentity)
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
            if let localIdentity {
                try? TrixCorePersistentBridge.deletePersistentState(identity: localIdentity)
            }
            try identityStore.delete()
            localIdentity = nil
            localCoreState = nil
            dashboard = nil
            activeLinkIntent = nil
            directoryAccountCache = [:]
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
            let response = try TrixCoreServerBridge.createLinkIntent(
                baseURLString: baseURLString,
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
            let response = try TrixCoreServerBridge.approvePendingDevice(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                deviceId: deviceId
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
            let _: RevokeDeviceResponse = try TrixCoreServerBridge.revokeDevice(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                deviceId: deviceId,
                reason: trimmedReason
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
    func publishKeyPackages(
        baseURLString: String,
        count: Int = 5
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
            let response = try TrixCorePersistentBridge.publishKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                count: count
            )

            updateLocalCoreStateSnapshot(identity: context.identity)
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
        draft: DebugMessageDraft
    ) async -> CreateMessageResponse? {
        guard !isLoading else {
            return nil
        }

        guard draft.canSubmit else {
            errorMessage = "Message body is incomplete."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let request = try TrixCoreMessageBridge.makeCreateMessageRequest(
                epoch: epoch,
                draft: draft
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
    func postDebugAttachment(
        baseURLString: String,
        chatId: String,
        epoch: UInt64,
        fileURL: URL
    ) async -> DebugAttachmentSendOutcome? {
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
            let preparedUpload = try TrixCoreMessageBridge.prepareAttachmentUpload(fileURL: fileURL)
            let blobClient = try FfiServerApiClient(
                baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try blobClient.setAccessToken(accessToken: context.session.accessToken)

            let blobUpload = try blobClient.createBlobUpload(
                chatId: chatId,
                mimeType: preparedUpload.mimeType,
                sizeBytes: preparedUpload.sizeBytes,
                sha256: preparedUpload.sha256
            )
            if blobUpload.needsUpload, preparedUpload.sizeBytes > blobUpload.maxUploadBytes {
                throw AppModelError.attachmentExceedsServerLimit(
                    actualBytes: preparedUpload.sizeBytes,
                    maxBytes: blobUpload.maxUploadBytes
                )
            }
            if blobUpload.needsUpload {
                let _: FfiBlobMetadata = try blobClient.uploadBlob(
                    blobId: blobUpload.blobId,
                    payload: preparedUpload.encryptedPayload
                )
            }

            let request = try TrixCoreMessageBridge.makeAttachmentCreateMessageRequest(
                epoch: epoch,
                blobId: blobUpload.blobId,
                preparedUpload: preparedUpload
            )
            let response: CreateMessageResponse = try await context.client.post(
                "/v0/chats/\(chatId)/messages",
                body: request,
                accessToken: context.session.accessToken
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return DebugAttachmentSendOutcome(
                createMessage: response,
                blobId: blobUpload.blobId,
                fileName: preparedUpload.fileName
            )
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

    func lookupAccount(
        baseURLString: String,
        accountId: String
    ) async throws -> DirectoryAccountSummary {
        let accountId = accountId.trix_trimmed()
        guard !accountId.isEmpty else {
            throw APIError.invalidPath("/v0/accounts/{account_id}")
        }

        if let cached = directoryAccountCache[accountId] {
            return cached
        }

        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        let account = try TrixCoreServerBridge.getAccount(
            baseURLString: baseURLString,
            accessToken: context.session.accessToken,
            accountId: accountId
        )
        directoryAccountCache[account.accountId] = account
        return account
    }

    func searchAccountDirectory(
        baseURLString: String,
        query: String?,
        limit: Int = 20,
        excludeSelf: Bool = true
    ) async throws -> [DirectoryAccountSummary] {
        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        let accounts = try TrixCoreServerBridge.searchAccountDirectory(
            baseURLString: baseURLString,
            accessToken: context.session.accessToken,
            query: query,
            limit: limit,
            excludeSelf: excludeSelf
        )
        for account in accounts {
            directoryAccountCache[account.accountId] = account
        }
        return accounts
    }

    func resolveDirectoryAccounts(
        baseURLString: String,
        accountIds: [String]
    ) async -> [String: DirectoryAccountSummary] {
        let accountIds = sanitizeIdentifiers(accountIds)
        guard !accountIds.isEmpty else {
            return [:]
        }

        var resolvedAccounts: [String: DirectoryAccountSummary] = [:]
        var missingAccountIds: [String] = []

        for accountId in accountIds {
            if let cached = directoryAccountCache[accountId] {
                resolvedAccounts[accountId] = cached
            } else {
                missingAccountIds.append(accountId)
            }
        }

        guard !missingAccountIds.isEmpty else {
            return resolvedAccounts
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            for accountId in missingAccountIds {
                do {
                    let account = try TrixCoreServerBridge.getAccount(
                        baseURLString: baseURLString,
                        accessToken: context.session.accessToken,
                        accountId: accountId
                    )
                    directoryAccountCache[account.accountId] = account
                    resolvedAccounts[account.accountId] = account
                } catch {
                    continue
                }
            }
        } catch {
            return resolvedAccounts
        }

        return resolvedAccounts
    }

    @discardableResult
    func updateAccountProfile(
        baseURLString: String,
        form: EditProfileForm
    ) async -> AccountProfileResponse? {
        guard !isLoading else {
            return nil
        }

        guard form.canSubmit else {
            errorMessage = "Profile name must not be empty."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let updated = try TrixCoreServerBridge.updateAccountProfile(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                form: form
            )
            directoryAccountCache[updated.accountId] = DirectoryAccountSummary(
                accountId: updated.accountId,
                handle: updated.handle,
                profileName: updated.profileName,
                profileBio: updated.profileBio
            )
            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return updated
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
        let detail: ChatDetailResponse = try await context.client.get(
            "/v0/chats/\(chatId)",
            accessToken: context.session.accessToken
        )
        seedDirectoryAccountCache(with: detail.participantProfiles)
        let localTimelineItems = try TrixCorePersistentBridge.loadLocalTimeline(
            identity: context.identity,
            chatId: chatId,
            limit: 150
        )

        if let localHistory = try TrixCorePersistentBridge.loadLocalChatHistory(
            identity: context.identity,
            chatId: chatId,
            limit: 100
        ) {
            return ChatSnapshot(
                detail: detail,
                history: localHistory.messages,
                localTimelineItems: localTimelineItems,
                historySource: .localStore
            )
        }

        async let history: ChatHistoryResponse = context.client.get(
            "/v0/chats/\(chatId)/history?limit=100",
            accessToken: context.session.accessToken
        )

        return try await ChatSnapshot(
            detail: detail,
            history: history.messages,
            localTimelineItems: localTimelineItems,
            historySource: .server
        )
    }

    @discardableResult
    func syncChatHistoriesIntoLocalStore(
        baseURLString: String,
        limitPerChat: Int = 100
    ) async -> LocalStoreSyncResult? {
        guard !isLoading else {
            return nil
        }

        guard limitPerChat > 0 else {
            errorMessage = "History sync limit must be greater than zero."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let result = try TrixCorePersistentBridge.syncChatHistoriesIntoStore(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                limitPerChat: limitPerChat
            )
            updateLocalCoreStateSnapshot(identity: context.identity)
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func leaseInboxIntoLocalStore(
        baseURLString: String,
        limit: Int = 25,
        leaseTtlSeconds: UInt64? = nil
    ) async -> LocalInboxSyncResult? {
        guard !isLoading else {
            return nil
        }

        guard limit > 0 else {
            errorMessage = "Inbox lease limit must be greater than zero."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let result = try TrixCorePersistentBridge.leaseInboxIntoStore(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                limit: limit,
                leaseTtlSeconds: leaseTtlSeconds
            )
            updateLocalCoreStateSnapshot(identity: context.identity)
            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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
        let dashboard = try await DashboardData(
            session: session,
            profile: profile,
            devices: devices.devices,
            historySyncJobs: historySyncJobs.jobs,
            chats: chats.chats,
            inboxItems: inbox.items
        )
        directoryAccountCache[dashboard.profile.accountId] = DirectoryAccountSummary(
            accountId: dashboard.profile.accountId,
            handle: dashboard.profile.handle,
            profileName: dashboard.profile.profileName,
            profileBio: dashboard.profile.profileBio
        )
        dashboard.chats.forEach { chat in
            seedDirectoryAccountCache(with: chat.participantProfiles)
        }
        self.dashboard = dashboard
        updateLocalCoreStateSnapshot(identity: localIdentity ?? identity)
        lastUpdatedAt = Date()
    }

    private func authenticate(
        client: APIClient,
        identity: LocalDeviceIdentity
    ) async throws -> AuthSessionResponse {
        return try TrixCoreServerBridge.authenticate(
            baseURLString: try client.baseURLString(),
            identity: identity
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

    func markChatReadLocally(chatId: String, throughServerSeq: UInt64?) {
        guard let localIdentity else {
            return
        }

        do {
            _ = try TrixCorePersistentBridge.markChatRead(
                identity: localIdentity,
                chatId: chatId,
                throughServerSeq: throughServerSeq
            )
            updateLocalCoreStateSnapshot(identity: localIdentity)
        } catch {
            // Local read state is opportunistic; network/UI flows should not fail on it.
        }
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

    private func seedDirectoryAccountCache(with participantProfiles: [ChatParticipantProfileSummary]) {
        for profile in participantProfiles {
            directoryAccountCache[profile.accountId] = DirectoryAccountSummary(
                accountId: profile.accountId,
                handle: profile.handle,
                profileName: profile.profileName,
                profileBio: profile.profileBio
            )
        }
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

    private func updateLocalCoreStateSnapshot(identity: LocalDeviceIdentity) {
        do {
            localCoreState = try TrixCorePersistentBridge.localStateSnapshot(identity: identity)
        } catch {
            localCoreState = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct AuthenticatedContext {
    let client: APIClient
    let identity: LocalDeviceIdentity
    let session: AuthSessionResponse
}

private enum AppModelError: LocalizedError {
    case localIdentityMissing
    case attachmentExceedsServerLimit(actualBytes: UInt64, maxBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .localIdentityMissing:
            return "Local identity is missing."
        case let .attachmentExceedsServerLimit(actualBytes, maxBytes):
            return "Attachment is \(ByteCountFormatter.string(fromByteCount: Int64(actualBytes), countStyle: .file)), which exceeds the current server upload limit of \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))."
        }
    }
}

extension String {
    func trix_trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trix_trimmedOrNil() -> String? {
        let trimmed = trix_trimmed()
        return trimmed.isEmpty ? nil : trimmed
    }
}
