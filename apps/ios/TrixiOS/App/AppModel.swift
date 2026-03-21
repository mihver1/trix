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

struct DownloadedAttachmentFile: Identifiable, Sendable {
    let fileURL: URL
    let fileName: String
    let mimeType: String?

    var id: String { fileURL.absoluteString }
}

private struct ChatHistoryBackfillResult {
    let recentMessages: [MessageEnvelope]
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
    private var realtimeClient: RealtimeWebSocketClient?
    private var realtimeConnectionID = UUID()
    private var currentServerBaseURLString: String?
    private var hasScheduledBackgroundRefresh = false
    private var cachedAuthSession: CachedAuthSession?
    private var realtimeAccessToken: String?
    private var cachedAttachmentFiles: [String: DownloadedAttachmentFile] = [:]
    private var attachmentDownloadTasks: [String: Task<DownloadedAttachmentFile, Error>] = [:]

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
        localIdentity?.hasFullAccountAccess ?? false
    }

    var requiresDeviceCapabilityUpgrade: Bool {
        localIdentity?.needsAccountRootUpgrade ?? false
    }

    var deviceCapabilitySummary: String {
        guard let localIdentity else {
            return "This device is not linked yet."
        }

        switch localIdentity.capabilityState {
        case .fullAccountAccess:
            return "This device can approve or remove other devices."
        case .transportOnly:
            return "This device is waiting for approval before account management becomes available."
        case .requiresRootUpgrade:
            return "Messaging works, but device management stays limited until this device imports account management keys."
        }
    }

    func start(baseURLString: String) async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        currentServerBaseURLString = normalizedBaseURLString(baseURLString)

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

        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
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
                    invalidateCachedAuthSession()
                    await stopRealtimeConnection()
                    dashboard = nil
                    updateLocalCoreStateSnapshot(identity: localIdentity)
                    systemSnapshot = try? await fetchSystemSnapshot(client: client)
                    lastUpdatedAt = Date()
                }
            } else {
                await stopRealtimeConnection()
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

        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
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

        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
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
            let preparedState = try TrixCorePersistentBridge.prepareLinkedDeviceState(
                payload: payload,
                form: form,
                bootstrapMaterial: bootstrapMaterial
            )
            let response = try TrixCoreServerBridge.completeLinkIntent(
                baseURLString: baseURLString,
                payload: payload,
                form: form,
                preparedState: preparedState
            )
            let localIdentity = try TrixCorePersistentBridge.finalizeLinkedDeviceState(
                preparedState: preparedState,
                pendingDeviceId: response.pendingDeviceId
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            updateLocalCoreStateSnapshot(identity: localIdentity)
            dashboard = nil
            activeLinkIntent = nil
            invalidateCachedAuthSession()
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
        disconnectRealtimeConnection()
        invalidateCachedAuthSession()
        try identityStore.delete()
        localIdentity = nil
        localCoreState = nil
        cachedAttachmentFiles = [:]
        attachmentDownloadTasks = [:]
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

        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
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
            let response = try TrixCorePersistentBridge.createChatControl(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatType: chatType,
                title: title,
                participantAccountIds: participantAccountIds
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
            let response = try TrixCorePersistentBridge.addChatMembersControl(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                participantAccountIds: participantAccountIds
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
            let response = try TrixCorePersistentBridge.removeChatMembersControl(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                participantAccountIds: participantAccountIds
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
            let response = try TrixCorePersistentBridge.addChatDevicesControl(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                deviceIds: deviceIds
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
            let response = try TrixCorePersistentBridge.removeChatDevicesControl(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                deviceIds: deviceIds
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
            let response = try TrixCorePersistentBridge.sendMessageBody(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                body: try TrixCoreMessageBridge.messageBody(for: draft)
            )

            updateLocalCoreStateSnapshot(identity: context.identity)
            applyLocalCoreStateOverlay(
                session: context.session,
                ackedInboxIds: [],
                changedChatIds: [chatId]
            )
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
            let attachmentUpload = try TrixCoreMessageBridge.readAttachmentUploadMaterial(fileURL: fileURL)
            let blobClient = try FfiServerApiClient(
                baseUrl: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try blobClient.setAccessToken(accessToken: context.session.accessToken)

            let uploadedAttachment = try blobClient.uploadAttachment(
                chatId: chatId,
                payload: attachmentUpload.payload,
                params: attachmentUpload.params
            )
            let response = try TrixCorePersistentBridge.sendMessageBody(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                body: uploadedAttachment.body
            )

            updateLocalCoreStateSnapshot(identity: context.identity)
            applyLocalCoreStateOverlay(
                session: context.session,
                ackedInboxIds: [],
                changedChatIds: [chatId]
            )
            return DebugAttachmentSendOutcome(
                createMessage: response,
                blobId: uploadedAttachment.blobId,
                fileName: uploadedAttachment.body.fileName
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func downloadAttachment(
        baseURLString: String,
        body: FfiMessageBody
    ) async -> DownloadedAttachmentFile? {
        guard !isLoading else {
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            return try await resolveAttachmentFile(
                baseURLString: baseURLString,
                body: body
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cachedAttachmentFile(for body: FfiMessageBody) -> DownloadedAttachmentFile? {
        let cacheKey = attachmentCacheKey(for: body)
        guard let cachedFile = cachedAttachmentFiles[cacheKey] else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: cachedFile.fileURL.path) else {
            cachedAttachmentFiles.removeValue(forKey: cacheKey)
            return nil
        }
        return cachedFile
    }

    func resolveAttachmentFile(
        baseURLString: String,
        body: FfiMessageBody
    ) async throws -> DownloadedAttachmentFile {
        if let cachedFile = cachedAttachmentFile(for: body) {
            return cachedFile
        }

        let cacheKey = attachmentCacheKey(for: body)
        if let existingTask = attachmentDownloadTasks[cacheKey] {
            return try await existingTask.value
        }

        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        let normalizedBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = context.session.accessToken

        let task = Task { () throws -> DownloadedAttachmentFile in
            let blobClient = try FfiServerApiClient(baseUrl: normalizedBaseURL)
            try blobClient.setAccessToken(accessToken: accessToken)

            let downloadedAttachment = try blobClient.downloadAttachment(body: body)
            let fileName = TrixCoreMessageBridge.suggestedAttachmentFileName(for: downloadedAttachment.body)
            let downloadsDirectory = try Self.attachmentCacheDirectory()
            let destinationDirectory = downloadsDirectory.appendingPathComponent(cacheKey, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            let destinationURL = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                try downloadedAttachment.plaintext.write(to: destinationURL, options: .atomic)
            }

            return DownloadedAttachmentFile(
                fileURL: destinationURL,
                fileName: fileName,
                mimeType: downloadedAttachment.body.mimeType
            )
        }

        attachmentDownloadTasks[cacheKey] = task
        defer {
            attachmentDownloadTasks.removeValue(forKey: cacheKey)
        }

        let downloadedFile = try await task.value
        cachedAttachmentFiles[cacheKey] = downloadedFile
        return downloadedFile
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
        _ = try? TrixCorePersistentBridge.applyChatDetail(
            identity: context.identity,
            detail: detail
        )

        var localTimelineItems = try TrixCorePersistentBridge.loadLocalTimeline(
            identity: context.identity,
            chatId: chatId,
            limit: 150
        )
        var localHistory = try TrixCorePersistentBridge.loadLocalChatHistory(
            identity: context.identity,
            chatId: chatId,
            limit: 100
        )
        var localProjectedCursor = try TrixCorePersistentBridge.projectedCursor(
            identity: context.identity,
            chatId: chatId
        ) ?? 0

        if let existingHistory = localHistory {
            let localHistoryServerSeq = existingHistory.messages.map(\.serverSeq).max() ?? 0
            let needsProjectionCatchUp = localHistoryServerSeq > localProjectedCursor

            if needsProjectionCatchUp {
                let projected = (try? TrixCorePersistentBridge.projectChatMessagesIfPossible(
                    identity: context.identity,
                    chatId: chatId,
                    limit: 500
                )) ?? false
                if !projected {
                    _ = try? TrixCorePersistentBridge.recoverConversationProjectionIfNeeded(
                        identity: context.identity,
                        chatId: chatId,
                        historyMessages: existingHistory.messages,
                        limit: 500
                    )
                }

                localTimelineItems = try TrixCorePersistentBridge.loadLocalTimeline(
                    identity: context.identity,
                    chatId: chatId,
                    limit: 150
                )
                localHistory = try TrixCorePersistentBridge.loadLocalChatHistory(
                    identity: context.identity,
                    chatId: chatId,
                    limit: 100
                )
                localProjectedCursor = try TrixCorePersistentBridge.projectedCursor(
                    identity: context.identity,
                    chatId: chatId
                ) ?? 0
                updateLocalCoreStateSnapshot(identity: context.identity)
            }
        }

        let localServerSeq = localHistory?.messages.map(\.serverSeq).max() ?? 0
        let needsProjectionBootstrap = localTimelineItems.isEmpty || localServerSeq > localProjectedCursor
        let shouldBackfillFromServer = localHistory == nil
            || localServerSeq < detail.lastServerSeq
            || needsProjectionBootstrap

        if shouldBackfillFromServer {
            let backfillResult = try await backfillChatHistoryFromServer(
                client: context.client,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                targetLastServerSeq: detail.lastServerSeq,
                startAfterServerSeq: needsProjectionBootstrap ? 0 : localServerSeq,
                bootstrapProjection: needsProjectionBootstrap
            )

            localTimelineItems = try TrixCorePersistentBridge.loadLocalTimeline(
                identity: context.identity,
                chatId: chatId,
                limit: 150
            )
            localHistory = try TrixCorePersistentBridge.loadLocalChatHistory(
                identity: context.identity,
                chatId: chatId,
                limit: 100
            )
            updateLocalCoreStateSnapshot(identity: context.identity)

            if !localTimelineItems.isEmpty || backfillResult.recentMessages.isEmpty {
                return ChatSnapshot(
                    detail: detail,
                    history: localHistory?.messages ?? [],
                    localTimelineItems: localTimelineItems,
                    historySource: .localStore
                )
            }

            return ChatSnapshot(
                detail: detail,
                history: backfillResult.recentMessages,
                localTimelineItems: localTimelineItems,
                historySource: .server
            )
        }

        return ChatSnapshot(
            detail: detail,
            history: localHistory?.messages ?? [],
            localTimelineItems: localTimelineItems,
            historySource: .localStore
        )
    }

    private func backfillChatHistoryFromServer(
        client: APIClient,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatId: String,
        targetLastServerSeq: UInt64,
        startAfterServerSeq: UInt64,
        bootstrapProjection: Bool,
        pageLimit: Int = 500,
        recentWindowLimit: Int = 150
    ) async throws -> ChatHistoryBackfillResult {
        var afterServerSeq = startAfterServerSeq
        var bootstrapHistoryMessages: [MessageEnvelope] = []
        var recentMessages: [MessageEnvelope] = []
        var hasRecoveredProjection = !bootstrapProjection

        while afterServerSeq < targetLastServerSeq {
            let page: ChatHistoryResponse = try await client.get(
                makeChatHistoryPath(
                    chatId: chatId,
                    afterServerSeq: afterServerSeq,
                    limit: pageLimit
                ),
                accessToken: accessToken
            )

            guard !page.messages.isEmpty else {
                break
            }

            _ = try? TrixCorePersistentBridge.applyChatHistory(
                identity: identity,
                chatId: chatId,
                messages: page.messages
            )
            appendRecentHistoryMessages(
                page.messages,
                into: &recentMessages,
                limit: recentWindowLimit
            )

            if !hasRecoveredProjection {
                bootstrapHistoryMessages.append(contentsOf: page.messages)
                hasRecoveredProjection = (try? TrixCorePersistentBridge.recoverConversationProjectionIfNeeded(
                    identity: identity,
                    chatId: chatId,
                    historyMessages: bootstrapHistoryMessages,
                    limit: pageLimit
                )) ?? false
            }

            if hasRecoveredProjection {
                _ = try? TrixCorePersistentBridge.projectChatMessagesIfPossible(
                    identity: identity,
                    chatId: chatId,
                    limit: pageLimit
                )
            }

            guard let lastServerSeq = page.messages.map(\.serverSeq).max(),
                  lastServerSeq > afterServerSeq
            else {
                break
            }

            afterServerSeq = lastServerSeq

            if page.messages.count < pageLimit {
                break
            }
        }

        return ChatHistoryBackfillResult(recentMessages: recentMessages)
    }

    private func makeChatHistoryPath(
        chatId: String,
        afterServerSeq: UInt64,
        limit: Int
    ) -> String {
        let clampedLimit = min(max(limit, 1), 500)
        if afterServerSeq > 0 {
            return "/v0/chats/\(chatId)/history?after_server_seq=\(afterServerSeq)&limit=\(clampedLimit)"
        }

        return "/v0/chats/\(chatId)/history?limit=\(clampedLimit)"
    }

    private func appendRecentHistoryMessages(
        _ messages: [MessageEnvelope],
        into window: inout [MessageEnvelope],
        limit: Int
    ) {
        guard limit > 0 else {
            window = []
            return
        }

        window.append(contentsOf: messages)
        if window.count > limit {
            window.removeFirst(window.count - limit)
        }
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
        identity: LocalDeviceIdentity,
        session existingSession: AuthSessionResponse? = nil,
        restartRealtime: Bool = true
    ) async throws {
        async let systemSnapshot = fetchSystemSnapshot(client: client)
        let session = try await resolveAuthenticatedSession(
            client: client,
            identity: identity,
            existingSession: existingSession
        )
        let effectiveIdentity = try reconcileAuthenticatedIdentity(
            baseURLString: try client.baseURLString(),
            accessToken: session.accessToken,
            identity: identity
        )
        _ = try? TrixCorePersistentBridge.repairLinkedDevicePersistentStateIfNeeded(
            identity: effectiveIdentity
        )

        do {
            _ = try TrixCorePersistentBridge.ensureOwnDeviceKeyPackages(
                baseURLString: try client.baseURLString(),
                accessToken: session.accessToken,
                identity: effectiveIdentity
            )
        } catch {
            errorMessage = error.localizedDescription
        }

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

        let resolvedSystemSnapshot = try await systemSnapshot
        let resolvedProfile = try await profile
        let resolvedDevices = try await devices
        let resolvedHistorySyncJobs = try await historySyncJobs
        let resolvedChats = try await chats
        let resolvedInbox = try await inbox

        let changedChatIds = applyServerStateToLocalStore(
            identity: effectiveIdentity,
            chats: resolvedChats.chats,
            inboxItems: resolvedInbox.items
        )
        await hydrateAndProjectChangedChats(
            client: client,
            accessToken: session.accessToken,
            identity: effectiveIdentity,
            chatIds: changedChatIds
        )
        let acknowledgedInboxIds = await acknowledgeInboxIntoLocalSyncStateIfPossible(
            baseURLString: try client.baseURLString(),
            accessToken: session.accessToken,
            identity: effectiveIdentity,
            inboxItems: resolvedInbox.items
        )
        updateLocalCoreStateSnapshot(identity: effectiveIdentity)
        let acknowledgedSet = Set(acknowledgedInboxIds)
        let remainingInboxItems = resolvedInbox.items.filter { !acknowledgedSet.contains($0.inboxId) }

        self.systemSnapshot = resolvedSystemSnapshot
        let dashboard = DashboardData(
            session: session,
            profile: resolvedProfile,
            devices: resolvedDevices.devices,
            historySyncJobs: resolvedHistorySyncJobs.jobs,
            chats: mergeChatSummaries(
                existing: resolvedChats.chats,
                inboxItems: remainingInboxItems
            ),
            inboxItems: remainingInboxItems
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
        lastUpdatedAt = Date()

        if restartRealtime {
            await startRealtimeConnection(
                baseURLString: try client.baseURLString(),
                accessToken: session.accessToken,
                identity: effectiveIdentity
            )
        }
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

    private func reconcileAuthenticatedIdentity(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) throws -> LocalDeviceIdentity {
        var effectiveIdentity = identity.trustState == .active ? identity : identity.markingActive()

        if !effectiveIdentity.hasFullAccountAccess {
            do {
                let transferBundle = try TrixCoreServerBridge.fetchDeviceTransferBundle(
                    baseURLString: baseURLString,
                    accessToken: accessToken,
                    deviceId: effectiveIdentity.deviceId
                )
                if let transferBundleData = Data(base64Encoded: transferBundle.transferBundleB64),
                   !transferBundleData.isEmpty {
                    effectiveIdentity = try effectiveIdentity.importingAccountRoot(
                        fromTransferBundle: transferBundleData
                    )
                } else {
                    effectiveIdentity = effectiveIdentity.markingRequiresRootUpgrade()
                }
            } catch {
                effectiveIdentity = effectiveIdentity.markingRequiresRootUpgrade()
            }
        }

        if effectiveIdentity != identity {
            try identityStore.save(effectiveIdentity)
            localIdentity = effectiveIdentity
        }

        return effectiveIdentity
    }

    private func applyServerStateToLocalStore(
        identity: LocalDeviceIdentity,
        chats: [ChatSummary],
        inboxItems: [InboxItem]
    ) -> Set<String> {
        do {
            let chatListReport = try TrixCorePersistentBridge.applyChatList(
                identity: identity,
                chats: chats
            )
            var changedChatIds = Set(chatListReport.changedChatIds)
            if !inboxItems.isEmpty {
                let inboxReport = try TrixCorePersistentBridge.applyInboxItems(
                    identity: identity,
                    items: inboxItems
                )
                changedChatIds.formUnion(inboxReport.changedChatIds)
            }
            return changedChatIds
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func hydrateAndProjectChangedChats(
        client: APIClient,
        accessToken: String,
        identity: LocalDeviceIdentity,
        chatIds: Set<String>
    ) async {
        for chatId in chatIds.sorted() {
            do {
                let detail: ChatDetailResponse = try await client.get(
                    "/v0/chats/\(chatId)",
                    accessToken: accessToken
                )
                seedDirectoryAccountCache(with: detail.participantProfiles)
                _ = try TrixCorePersistentBridge.applyChatDetail(
                    identity: identity,
                    detail: detail
                )
            } catch {
                continue
            }
        }
    }

    private func acknowledgeInboxIntoLocalSyncStateIfPossible(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        inboxItems: [InboxItem]
    ) async -> [UInt64] {
        let inboxIds = Array(Set(inboxItems.map(\.inboxId))).sorted()
        guard !inboxIds.isEmpty else {
            return []
        }

        do {
            let response = try TrixCorePersistentBridge.ackInboxIntoSyncState(
                baseURLString: baseURLString,
                accessToken: accessToken,
                identity: identity,
                inboxIds: inboxIds
            )
            return response.ackedInboxIds
        } catch {
            return []
        }
    }

    private func fetchSystemSnapshot(client: APIClient) async throws -> ServerSnapshot {
        async let health: HealthResponse = client.get("/v0/system/health")
        async let version: VersionResponse = client.get("/v0/system/version")

        return try await ServerSnapshot(health: health, version: version)
    }

    private func attachmentCacheKey(for body: FfiMessageBody) -> String {
        let rawValue: String
        if let blobId = body.blobId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !blobId.isEmpty {
            rawValue = blobId
        } else {
            rawValue = TrixCoreMessageBridge.suggestedAttachmentFileName(for: body)
        }
        return rawValue.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
    }

    private static func attachmentCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrixAttachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeAuthenticatedContext(baseURLString: String) async throws -> AuthenticatedContext {
        guard let identity = localIdentity else {
            throw AppModelError.localIdentityMissing
        }

        let client = try APIClient(baseURLString: baseURLString)
        let session = try await resolveAuthenticatedSession(
            client: client,
            identity: identity
        )
        return AuthenticatedContext(client: client, identity: identity, session: session)
    }

    private func resolveAuthenticatedSession(
        client: APIClient,
        identity: LocalDeviceIdentity,
        existingSession: AuthSessionResponse? = nil
    ) async throws -> AuthSessionResponse {
        if let existingSession {
            cacheAuthenticatedSession(existingSession, for: identity, baseURLString: try client.baseURLString())
            return existingSession
        }

        let normalizedBaseURL = try client.baseURLString()
        if let cachedAuthSession,
           cachedAuthSession.isUsable(
               for: identity,
               baseURLString: normalizedBaseURL,
               leewaySeconds: 60
           ) {
            return cachedAuthSession.session
        }

        let session = try await authenticate(client: client, identity: identity)
        cacheAuthenticatedSession(session, for: identity, baseURLString: normalizedBaseURL)
        return session
    }

    private func cacheAuthenticatedSession(
        _ session: AuthSessionResponse,
        for identity: LocalDeviceIdentity,
        baseURLString: String
    ) {
        cachedAuthSession = CachedAuthSession(
            baseURLString: normalizedBaseURLString(baseURLString),
            accountId: identity.accountId,
            deviceId: identity.deviceId,
            session: session
        )
    }

    private func invalidateCachedAuthSession() {
        cachedAuthSession = nil
        realtimeAccessToken = nil
    }

    private func normalizedBaseURLString(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func makeInboxPath(afterInboxId: UInt64?, limit: Int) -> String {
        let clampedLimit = min(max(limit, 1), 500)

        if let afterInboxId {
            return "/v0/inbox?after_inbox_id=\(afterInboxId)&limit=\(clampedLimit)"
        }

        return "/v0/inbox?limit=\(clampedLimit)"
    }

    private func startRealtimeConnection(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) async {
        let normalizedBaseURL = normalizedBaseURLString(baseURLString)
        if realtimeClient != nil,
           realtimeAccessToken == accessToken,
           normalizedBaseURLString(currentServerBaseURLString ?? "") == normalizedBaseURL,
           localIdentity?.deviceId == identity.deviceId {
            return
        }

        await stopRealtimeConnection()

        let connectionID = UUID()
        realtimeConnectionID = connectionID

        do {
            let client = try RealtimeWebSocketClient(
                baseURLString: baseURLString,
                accessToken: accessToken,
                identity: identity,
                onEvent: { [weak self] update in
                    await self?.handleRealtimeUpdate(update, connectionID: connectionID)
                },
                onDisconnect: { [weak self] reason in
                    await self?.handleRealtimeDisconnect(reason, connectionID: connectionID)
                }
            )
            realtimeClient = client
            realtimeAccessToken = accessToken
            await client.start()
        } catch {
            realtimeClient = nil
            realtimeAccessToken = nil
            errorMessage = error.localizedDescription
            scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
        }
    }

    private func stopRealtimeConnection() async {
        let client = realtimeClient
        realtimeClient = nil
        realtimeAccessToken = nil
        realtimeConnectionID = UUID()
        await client?.stop()
    }

    private func disconnectRealtimeConnection() {
        let client = realtimeClient
        realtimeClient = nil
        realtimeAccessToken = nil
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
        case .hello:
            lastUpdatedAt = Date()
        case .inboxItems:
            if let localIdentity,
               let baseURLString = currentServerBaseURLString,
               let accessToken = realtimeAccessToken,
               let client = try? APIClient(baseURLString: baseURLString) {
                await hydrateAndProjectChangedChats(
                    client: client,
                    accessToken: accessToken,
                    identity: localIdentity,
                    chatIds: Set(update.event.report?.changedChatIds ?? [])
                )
                updateLocalCoreStateSnapshot(identity: localIdentity)
            } else if let localIdentity {
                updateLocalCoreStateSnapshot(identity: localIdentity)
            }
            if let dashboard {
                let applied = applyLocalCoreStateOverlay(
                    session: dashboard.session,
                    ackedInboxIds: [],
                    changedChatIds: update.event.report?.changedChatIds ?? []
                )
                if !applied {
                    scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
                }
            } else {
                scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
            }
        case .acked:
            if let localIdentity {
                updateLocalCoreStateSnapshot(identity: localIdentity)
            }
            removeDashboardInboxItems(update.event.serverAckedInboxIds)
        case .pong:
            break
        case .sessionReplaced:
            invalidateCachedAuthSession()
            disconnectRealtimeConnection()
            if let reason = update.event.sessionReplacedReason?.trix_trimmedOrNil() {
                errorMessage = reason
            }
            scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
        case .error:
            errorMessage = update.event.errorMessage ?? "Realtime transport error."
        case .disconnected:
            disconnectRealtimeConnection()
            scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
        }
    }

    private func handleRealtimeDisconnect(
        _ reason: String?,
        connectionID: UUID
    ) async {
        guard realtimeConnectionID == connectionID else {
            return
        }

        realtimeClient = nil
        if let reason,
           !reason.trix_trimmed().isEmpty,
           dashboard == nil {
            errorMessage = reason
        }
        scheduleBackgroundRefresh(delayNanoseconds: 1_500_000_000)
    }

    private func scheduleBackgroundRefresh(delayNanoseconds: UInt64) {
        guard !hasScheduledBackgroundRefresh,
              let baseURLString = currentServerBaseURLString,
              localIdentity != nil
        else {
            return
        }

        hasScheduledBackgroundRefresh = true

        Task { [weak self] in
            guard let self else {
                return
            }

            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            guard !self.isLoading else {
                self.finishBackgroundRefresh()
                self.scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
                return
            }

            let recovered = await self.runIncrementalBackgroundRecovery(
                baseURLString: baseURLString
            )
            if !recovered {
                await self.refresh(baseURLString: baseURLString)
            }
            self.finishBackgroundRefresh()
        }
    }

    private func finishBackgroundRefresh() {
        hasScheduledBackgroundRefresh = false
    }

    private func runIncrementalBackgroundRecovery(baseURLString: String) async -> Bool {
        guard dashboard != nil else {
            return false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let effectiveIdentity = try reconcileAuthenticatedIdentity(
                baseURLString: try context.client.baseURLString(),
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            _ = try? TrixCorePersistentBridge.repairLinkedDevicePersistentStateIfNeeded(
                identity: effectiveIdentity
            )
            let result = try TrixCorePersistentBridge.pollRealtimeOnce(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: effectiveIdentity
            )
            await hydrateAndProjectChangedChats(
                client: context.client,
                accessToken: context.session.accessToken,
                identity: effectiveIdentity,
                chatIds: Set(result.report.changedChatIds)
            )
            updateLocalCoreStateSnapshot(identity: effectiveIdentity)
            let applied = applyLocalCoreStateOverlay(
                session: context.session,
                ackedInboxIds: result.ackedInboxIds,
                changedChatIds: result.report.changedChatIds
            )
            if applied {
                await startRealtimeConnection(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: effectiveIdentity
                )
            }
            return applied
        } catch {
            return false
        }
    }

    private func applyLocalCoreStateOverlay(
        session: AuthSessionResponse,
        ackedInboxIds: [UInt64],
        changedChatIds: [String]
    ) -> Bool {
        guard let dashboard else {
            return false
        }

        let acknowledgedSet = Set(ackedInboxIds)
        let remainingInboxItems = dashboard.inboxItems.filter { !acknowledgedSet.contains($0.inboxId) }
        let mergedChats = mergeDashboardChatsWithLocalState(existing: dashboard.chats)
        let mergedChatIds = Set(mergedChats.map(\.chatId))

        self.dashboard = DashboardData(
            session: session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: mergedChats,
                inboxItems: remainingInboxItems
            ),
            inboxItems: remainingInboxItems
        )
        lastUpdatedAt = Date()

        return Set(changedChatIds).isSubset(of: mergedChatIds)
    }

    private func updateDashboardInboxItems(
        _ newItems: [InboxItem],
        scheduleRefreshForUnknownChats: Bool = false
    ) {
        guard let dashboard else {
            return
        }

        let knownChatIds = Set(dashboard.chats.map(\.chatId))
        let incomingChatIds = Set(newItems.map(\.message.chatId))
        let mergedInboxItems = mergeInboxItems(
            existing: dashboard.inboxItems,
            incoming: newItems
        )
        self.dashboard = DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: dashboard.chats,
                inboxItems: mergedInboxItems
            ),
            inboxItems: mergedInboxItems
        )
        lastUpdatedAt = Date()

        if scheduleRefreshForUnknownChats,
           !incomingChatIds.subtracting(knownChatIds).isEmpty {
            scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
        }
    }

    private func removeDashboardInboxItems(_ ackedInboxIds: [UInt64]) {
        guard let dashboard else {
            return
        }

        let acknowledgedSet = Set(ackedInboxIds)
        guard !acknowledgedSet.isEmpty else {
            lastUpdatedAt = Date()
            return
        }

        let remainingInboxItems = dashboard.inboxItems.filter { !acknowledgedSet.contains($0.inboxId) }
        self.dashboard = DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: dashboard.chats,
                inboxItems: remainingInboxItems
            ),
            inboxItems: remainingInboxItems
        )
        lastUpdatedAt = Date()
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

    private func mergeChatSummaries(
        existing: [ChatSummary],
        inboxItems: [InboxItem]
    ) -> [ChatSummary] {
        let inboxMessagesByChatId = Dictionary(grouping: inboxItems.map(\.message), by: \.chatId)

        return existing
            .map { chat in
                let latestInboxMessage = inboxMessagesByChatId[chat.chatId]?
                    .max { lhs, rhs in lhs.serverSeq < rhs.serverSeq }
                let leasedCount = UInt64(inboxMessagesByChatId[chat.chatId]?.count ?? 0)

                return ChatSummary(
                    chatId: chat.chatId,
                    chatType: chat.chatType,
                    title: chat.title,
                    lastServerSeq: max(chat.lastServerSeq, latestInboxMessage?.serverSeq ?? 0),
                    epoch: max(chat.epoch, latestInboxMessage?.epoch ?? 0),
                    pendingMessageCount: max(chat.pendingMessageCount, leasedCount),
                    lastMessage: resolvedLatestMessage(
                        current: chat.lastMessage,
                        incoming: latestInboxMessage
                    ),
                    participantProfiles: chat.participantProfiles
                )
            }
            .sorted(by: sortDashboardChatSummaries)
    }

    private func resolvedLatestMessage(
        current: MessageEnvelope?,
        incoming: MessageEnvelope?
    ) -> MessageEnvelope? {
        switch (current, incoming) {
        case let (.some(current), .some(incoming)):
            return incoming.serverSeq >= current.serverSeq ? incoming : current
        case let (.some(current), .none):
            return current
        case let (.none, .some(incoming)):
            return incoming
        case (.none, .none):
            return nil
        }
    }

    private func chatSummarySortComparator(lhs: ChatSummary, rhs: ChatSummary) -> Bool {
        let lhsDate = lhs.lastMessage?.createdAtDate ?? .distantPast
        let rhsDate = rhs.lastMessage?.createdAtDate ?? .distantPast

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        if lhs.lastServerSeq != rhs.lastServerSeq {
            return lhs.lastServerSeq > rhs.lastServerSeq
        }

        return lhs.chatId < rhs.chatId
    }

    private func mergeDashboardChatsWithLocalState(existing: [ChatSummary]) -> [ChatSummary] {
        guard let localCoreState else {
            return existing.sorted(by: sortDashboardChatSummaries)
        }

        var chatsById = Dictionary(uniqueKeysWithValues: existing.map { ($0.chatId, $0) })
        for localChat in localCoreState.localChats {
            chatsById[localChat.chatId] = mergedChatSummary(
                existing: chatsById[localChat.chatId],
                local: localChat
            )
        }

        return chatsById
            .values
            .sorted(by: sortDashboardChatSummaries)
    }

    private func mergedChatSummary(
        existing: ChatSummary?,
        local: ChatSummary
    ) -> ChatSummary {
        ChatSummary(
            chatId: local.chatId,
            chatType: local.chatType,
            title: local.title?.trix_trimmedOrNil() ?? existing?.title?.trix_trimmedOrNil(),
            lastServerSeq: max(local.lastServerSeq, existing?.lastServerSeq ?? 0),
            epoch: max(local.epoch, existing?.epoch ?? 0),
            pendingMessageCount: max(local.pendingMessageCount, existing?.pendingMessageCount ?? 0),
            lastMessage: resolvedLatestMessage(
                current: existing?.lastMessage,
                incoming: local.lastMessage
            ),
            participantProfiles: local.participantProfiles.isEmpty
                ? (existing?.participantProfiles ?? [])
                : local.participantProfiles
        )
    }

    private func sortDashboardChatSummaries(lhs: ChatSummary, rhs: ChatSummary) -> Bool {
        let lhsLocalItem = localCoreState?.chatListItem(for: lhs.chatId)
        let rhsLocalItem = localCoreState?.chatListItem(for: rhs.chatId)

        let lhsDate = lhsLocalItem?.previewDate ?? lhs.lastMessage?.createdAtDate ?? .distantPast
        let rhsDate = rhsLocalItem?.previewDate ?? rhs.lastMessage?.createdAtDate ?? .distantPast

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        let lhsSeq = max(
            lhsLocalItem?.previewServerSeq ?? 0,
            max(lhsLocalItem?.lastServerSeq ?? 0, lhs.lastServerSeq)
        )
        let rhsSeq = max(
            rhsLocalItem?.previewServerSeq ?? 0,
            max(rhsLocalItem?.lastServerSeq ?? 0, rhs.lastServerSeq)
        )

        if lhsSeq != rhsSeq {
            return lhsSeq > rhsSeq
        }

        return chatSummarySortComparator(lhs: lhs, rhs: rhs)
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

private struct CachedAuthSession {
    let baseURLString: String
    let accountId: String
    let deviceId: String
    let session: AuthSessionResponse

    func isUsable(
        for identity: LocalDeviceIdentity,
        baseURLString: String,
        leewaySeconds: UInt64
    ) -> Bool {
        guard self.baseURLString == baseURLString,
              accountId == identity.accountId,
              deviceId == identity.deviceId,
              session.deviceStatus != .revoked
        else {
            return false
        }

        let nowUnix = UInt64(Date().timeIntervalSince1970)
        return session.expiresAtUnix > nowUnix + leewaySeconds
    }
}

private enum AppModelError: LocalizedError {
    case localIdentityMissing

    var errorDescription: String? {
        switch self {
        case .localIdentityMissing:
            return "Local identity is missing."
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
