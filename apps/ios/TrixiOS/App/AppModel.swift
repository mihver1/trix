import Foundation
import Security
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

struct DebugAttachmentSendOutcome: Sendable {
    let createMessage: CreateMessageResponse
    let attachmentRef: String?
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
@Observable
final class AppModel {
    private(set) var localIdentity: LocalDeviceIdentity?
    private(set) var localCoreState: LocalCoreStateSnapshot?
    private(set) var dashboard: DashboardData?
    private(set) var dashboardConversationRefreshTokens: [String: String] = [:]
    private(set) var activeLinkIntent: CreateLinkIntentResponse?
    private(set) var systemSnapshot: ServerSnapshot?
    private(set) var lastUpdatedAt: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let identityStore: LocalDeviceIdentityStore
    @ObservationIgnored private let notificationCoordinator = IOSNotificationCoordinator()
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var directoryAccountCache: [String: DirectoryAccountSummary] = [:]
    @ObservationIgnored private var realtimeClient: RealtimeWebSocketClient?
    @ObservationIgnored private var realtimeConnectionID = UUID()
    @ObservationIgnored private var currentServerBaseURLString: String?
    @ObservationIgnored private var hasScheduledBackgroundRefresh = false
    @ObservationIgnored private let authSessionResolutionGate = AuthSessionResolutionGate()
    @ObservationIgnored private var realtimeAccessToken: String?
    @ObservationIgnored private var messengerSnapshot: SafeMessengerSnapshot?
    @ObservationIgnored private var messengerCheckpoint: String?
    @ObservationIgnored private var messengerReadStates: [String: LocalChatReadStateSnapshot] = [:]
    @ObservationIgnored private var cachedAttachmentFiles: [String: DownloadedAttachmentFile] = [:]
    @ObservationIgnored private var attachmentDownloadTasks: [String: Task<DownloadedAttachmentFile, Error>] = [:]
    @ObservationIgnored private var apnsTokenHex: String?
    @ObservationIgnored private var backgroundRealtimeTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var linkIntentPollingTask: Task<Void, Never>?
    @ObservationIgnored private var linkIntentPendingBaselineDeviceIds: Set<String> = []
    private static let linkIntentPollingIntervalNanoseconds: UInt64 = 3_000_000_000
    private static let didRequestNotificationAuthorizationDefaultsKey =
        "notifications.ios.authorizationRequested"

    init(identityStore: LocalDeviceIdentityStore = LocalDeviceIdentityStore()) {
        self.identityStore = identityStore
    }

    deinit {
        linkIntentPollingTask?.cancel()
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
            try identityStore.migrateKeychainAccessibilityIfNeeded()
            localIdentity = try identityStore.load()
        } catch {
            if !shouldSuppressProtectedDataError(error) {
                errorMessage = error.localizedDescription
            }
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
                    updateDashboardState(nil)
                    messengerSnapshot = nil
                    messengerCheckpoint = nil
                    messengerReadStates = [:]
                    updateLocalCoreStateSnapshot(identity: localIdentity)
                    systemSnapshot = try? await fetchSystemSnapshot(client: client)
                    lastUpdatedAt = Date()
                }
            } else {
                await stopRealtimeConnection()
                updateDashboardState(nil)
                localCoreState = nil
                messengerSnapshot = nil
                messengerCheckpoint = nil
                messengerReadStates = [:]
                systemSnapshot = try await fetchSystemSnapshot(client: client)
                lastUpdatedAt = Date()
            }
        } catch {
            if !shouldSuppressProtectedDataError(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearServerStatus() {
        systemSnapshot = nil
        lastUpdatedAt = nil
    }

    func handleAppDidBecomeActive(baseURLString: String) async {
        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
        endBackgroundRealtimeTask()

        if activeLinkIntent != nil {
            await refreshLinkedDevices(baseURLString: baseURLString, suppressErrors: true)
        }

        guard localIdentity != nil else {
            return
        }

        if realtimeClient != nil {
            return
        }

        if let localIdentity,
           let cachedAuthSession = authSessionResolutionGate.currentUsableSession(
               for: localIdentity,
               baseURLString: normalizedBaseURLString(baseURLString),
               leewaySeconds: 60
           ) {
            await startRealtimeConnection(
                baseURLString: baseURLString,
                accessToken: cachedAuthSession.accessToken,
                identity: localIdentity
            )
            return
        }

        await refresh(baseURLString: baseURLString)
    }

    func handleAppDidEnterBackground(baseURLString: String) {
        currentServerBaseURLString = normalizedBaseURLString(baseURLString)
        beginBackgroundRealtimeTask(baseURLString: baseURLString)
    }

    func handleRegisteredForRemoteNotifications(deviceToken: Data) async {
        apnsTokenHex = apnsTokenHexString(from: deviceToken)
        await syncApplePushTokenIfPossible()
    }

    func handleRemoteNotificationsRegistrationFailure(_ error: Error) {
        if UITestLaunchConfiguration.current.isEnabled {
            return
        }
        errorMessage = error.localizedDescription
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard isTrixInboxRemoteNotification(userInfo) else {
            return .noData
        }
        guard let baseURLString = currentServerBaseURLString, localIdentity != nil else {
            return .noData
        }

        let recovered = await runIncrementalBackgroundRecovery(
            baseURLString: baseURLString,
            resumeRealtimeConnection: false,
            postNotifications: true
        )
        if recovered {
            return .newData
        }

        await refresh(baseURLString: baseURLString)
        return errorMessage == nil ? .newData : .failed
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
            let localIdentity = try TrixCorePersistentBridge.completeLinkDevice(
                payload: payload,
                form: form,
                bootstrapMaterial: bootstrapMaterial
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            updateLocalCoreStateSnapshot(identity: localIdentity)
            updateDashboardState(nil)
            activeLinkIntent = nil
            stopLinkIntentRefreshLoop()
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
        stopLinkIntentRefreshLoop()
        disconnectRealtimeConnection()
        invalidateCachedAuthSession()
        try identityStore.delete()
        localIdentity = nil
        localCoreState = nil
            messengerSnapshot = nil
            messengerCheckpoint = nil
            messengerReadStates = [:]
            updateDashboardState(nil)
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
            stopLinkIntentRefreshLoop()
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response = try TrixCorePersistentBridge.createLinkDeviceIntent(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            let baselineSnapshot = try? TrixCorePersistentBridge.loadMessengerSnapshot(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            let baselineDevices = baselineSnapshot?.devices ?? dashboard?.devices ?? []
            linkIntentPendingBaselineDeviceIds = pendingDeviceIds(in: baselineDevices)
            applyLoadedDevicesToDashboard(baselineDevices)
            activeLinkIntent = response
            startLinkIntentRefreshLoop(baseURLString: baseURLString)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissActiveLinkIntent() {
        activeLinkIntent = nil
        stopLinkIntentRefreshLoop()
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
            let response = try TrixCorePersistentBridge.approveLinkedDevice(
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

    @discardableResult
    func revokeDevice(
        baseURLString: String,
        deviceId: String,
        reason: String
    ) async -> Bool {
        guard !isLoading else {
            return false
        }

        let trimmedReason = reason.trix_trimmed()
        guard !trimmedReason.isEmpty else {
            errorMessage = "Revoke reason must not be empty."
            return false
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let _: RevokeDeviceResponse = try TrixCorePersistentBridge.revokeDevice(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                deviceId: deviceId,
                reason: trimmedReason
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
            let _: CompleteHistorySyncJobResponse = try await TrixCoreServerBridge.completeHistorySyncJob(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                jobId: jobId,
                cursorJson: nil
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
    func fetchAccountKeyPackages(
        baseURLString: String,
        accountId: String
    ) async -> AccountKeyPackagesResponse? {
        guard !isLoading else {
            return nil
        }

        let normalizedAccountId = accountId.trix_trimmed()
        guard !normalizedAccountId.isEmpty else {
            errorMessage = "Account ID must not be empty."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            return try TrixCoreServerBridge.getAccountKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                accountId: normalizedAccountId
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func reserveAccountKeyPackages(
        baseURLString: String,
        accountId: String,
        deviceIds: [String]
    ) async -> AccountKeyPackagesResponse? {
        guard !isLoading else {
            return nil
        }

        let normalizedAccountId = accountId.trix_trimmed()
        let normalizedDeviceIds = sanitizeIdentifiers(deviceIds)
        guard !normalizedAccountId.isEmpty else {
            errorMessage = "Account ID must not be empty."
            return nil
        }
        guard !normalizedDeviceIds.isEmpty else {
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
            return try TrixCoreServerBridge.reserveKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                accountId: normalizedAccountId,
                deviceIds: normalizedDeviceIds
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func dryRunReservedKeyPackageCommit(
        reservedPackages: [ReservedKeyPackage]
    ) async -> UInt64? {
        guard !isLoading else {
            return nil
        }
        guard let identity = localIdentity else {
            errorMessage = "Local identity is missing."
            return nil
        }
        guard !reservedPackages.isEmpty else {
            errorMessage = "Reserve or load key packages first."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            return try TrixCorePersistentBridge.dryRunCreateGroupCommit(
                identity: identity,
                reservedPackages: reservedPackages
            )
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
            let response = try TrixCorePersistentBridge.createConversation(
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
            let response = try TrixCorePersistentBridge.addConversationMembers(
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
            let response = try TrixCorePersistentBridge.removeConversationMembers(
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
            let response = try TrixCorePersistentBridge.addConversationDevices(
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
            let response = try TrixCorePersistentBridge.removeConversationDevices(
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
        draft: DebugMessageDraft
    ) async -> CreateMessageResponse? {
        guard !isLoading else {
            errorMessage = "Please wait for the current action to finish."
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
            let response = try await TrixCorePersistentBridge.sendMessage(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                draft: draft
            )

            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func postReaction(
        baseURLString: String,
        chatId: String,
        targetMessageId: String,
        emoji: String,
        removeExisting: Bool
    ) async -> CreateMessageResponse? {
        var draft = DebugMessageDraft()
        draft.kind = .reaction
        draft.targetMessageId = targetMessageId
        draft.emoji = emoji
        draft.reactionAction = removeExisting ? .remove : .add
        return await postDebugMessage(
            baseURLString: baseURLString,
            chatId: chatId,
            draft: draft
        )
    }

    @discardableResult
    func postDebugAttachment(
        baseURLString: String,
        chatId: String,
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
            let response = try await TrixCorePersistentBridge.sendAttachment(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                fileURL: fileURL
            )

            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func downloadAttachment(
        baseURLString: String,
        attachment: SafeMessengerAttachment
    ) async -> DownloadedAttachmentFile? {
        guard !isLoading else {
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        return await resolveAttachmentFile(
            baseURLString: baseURLString,
            attachment: attachment,
            reportErrors: true
        )
    }

    func inlinePreviewAttachmentFile(
        baseURLString: String,
        attachment: SafeMessengerAttachment
    ) async -> DownloadedAttachmentFile? {
        await resolveAttachmentFile(
            baseURLString: baseURLString,
            attachment: attachment,
            reportErrors: false
        )
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
            let response = try await TrixCorePersistentBridge.ackInboxIntoSyncState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                inboxIds: inboxIds
            )

            try await refreshAuthenticatedState(client: context.client, identity: context.identity)
            return AckInboxResponse(ackedInboxIds: response.ackedInboxIds)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func resolveAttachmentFile(
        baseURLString: String,
        attachment: SafeMessengerAttachment,
        reportErrors: Bool
    ) async -> DownloadedAttachmentFile? {
        if let cachedFile = cachedAttachmentFile(for: attachment.attachmentRef) {
            return cachedFile
        }

        if let existingTask = attachmentDownloadTasks[attachment.attachmentRef] {
            do {
                let file = try await existingTask.value
                cacheAttachmentFile(file, for: attachment.attachmentRef)
                return file
            } catch {
                if reportErrors {
                    errorMessage = error.localizedDescription
                }
                return nil
            }
        }

        let task = Task<DownloadedAttachmentFile, Error> {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            return try await TrixCorePersistentBridge.getAttachment(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                attachment: attachment
            )
        }
        attachmentDownloadTasks[attachment.attachmentRef] = task

        do {
            let file = try await task.value
            attachmentDownloadTasks.removeValue(forKey: attachment.attachmentRef)
            cacheAttachmentFile(file, for: attachment.attachmentRef)
            return file
        } catch {
            attachmentDownloadTasks.removeValue(forKey: attachment.attachmentRef)
            if reportErrors {
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    private func cachedAttachmentFile(for attachmentRef: String) -> DownloadedAttachmentFile? {
        guard let cachedFile = cachedAttachmentFiles[attachmentRef] else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: cachedFile.fileURL.path) else {
            cachedAttachmentFiles.removeValue(forKey: attachmentRef)
            return nil
        }

        return cachedFile
    }

    private func cacheAttachmentFile(
        _ file: DownloadedAttachmentFile,
        for attachmentRef: String
    ) {
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return
        }

        cachedAttachmentFiles[attachmentRef] = file
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
            let response = try await TrixCoreServerBridge.getInbox(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                afterInboxId: dashboard?.maxInboxId,
                limit: limit
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
            let response = try await TrixCoreServerBridge.leaseInbox(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                leaseOwner: leaseOwner,
                limit: limit,
                afterInboxId: afterInboxId,
                leaseTtlSeconds: leaseTtlSeconds
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
        let detail = try await TrixCoreServerBridge.getChat(
            baseURLString: baseURLString,
            accessToken: context.session.accessToken,
            chatId: chatId
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
                do {
                    _ = try await TrixCorePersistentBridge.syncPendingHistoryRepairs(
                        baseURLString: baseURLString,
                        accessToken: context.session.accessToken,
                        identity: context.identity,
                        chatIds: [chatId]
                    )
                } catch {
                    errorMessage = error.localizedDescription
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
            do {
                _ = try await TrixCorePersistentBridge.syncPendingHistoryRepairs(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: context.identity,
                    chatIds: [chatId]
                )
            } catch {
                errorMessage = error.localizedDescription
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

    func fetchConversationSnapshot(
        baseURLString: String,
        chatId: String
    ) async throws -> SafeConversationSnapshot {
        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        let snapshot = try TrixCorePersistentBridge.loadConversationSnapshot(
            baseURLString: baseURLString,
            accessToken: context.session.accessToken,
            identity: context.identity,
            chatId: chatId
        )
        seedDirectoryAccountCache(with: snapshot.detail.participantProfiles)
        return snapshot
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
        let baseURLString = try client.baseURLString()
        var afterServerSeq = startAfterServerSeq
        var bootstrapHistoryMessages: [MessageEnvelope] = []
        var recentMessages: [MessageEnvelope] = []
        var hasRecoveredProjection = !bootstrapProjection

        while afterServerSeq < targetLastServerSeq {
            let page = try await TrixCoreServerBridge.getChatHistory(
                baseURLString: baseURLString,
                accessToken: accessToken,
                chatId: chatId,
                afterServerSeq: afterServerSeq,
                limit: pageLimit
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
            do {
                _ = try await TrixCorePersistentBridge.syncPendingHistoryRepairs(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: context.identity,
                    chatIds: result.changedChatIds.isEmpty ? nil : result.changedChatIds
                )
            } catch {
                errorMessage = error.localizedDescription
            }
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
            do {
                _ = try await TrixCorePersistentBridge.syncPendingHistoryRepairs(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: context.identity,
                    chatIds: result.report.changedChatIds.isEmpty ? nil : result.report.changedChatIds
                )
            } catch {
                errorMessage = error.localizedDescription
            }
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
        let baseURLString = try client.baseURLString()

        async let systemSnapshot = TrixCoreServerBridge.fetchSystemSnapshot(
            baseURLString: baseURLString
        )
        let session = try await resolveAuthenticatedSession(
            client: client,
            identity: identity,
            existingSession: existingSession
        )
        let effectiveIdentity = try reconcileAuthenticatedIdentity(
            baseURLString: baseURLString,
            accessToken: session.accessToken,
            identity: identity
        )

        async let profile = TrixCoreServerBridge.getAccountProfile(
            baseURLString: baseURLString,
            accessToken: session.accessToken
        )
        async let historySyncJobs = TrixCoreServerBridge.listHistorySyncJobs(
            baseURLString: baseURLString,
            accessToken: session.accessToken
        )
        async let safeSnapshotTask: SafeMessengerSnapshot = TrixCorePersistentBridge.loadMessengerSnapshot(
            baseURLString: baseURLString,
            accessToken: session.accessToken,
            identity: effectiveIdentity
        )

        let resolvedSystemSnapshot = try await systemSnapshot
        let resolvedProfile = try await profile
        let resolvedHistorySyncJobs = try await historySyncJobs
        let resolvedSafeSnapshot = try await safeSnapshotTask

        messengerSnapshot = resolvedSafeSnapshot
        messengerCheckpoint = resolvedSafeSnapshot.checkpoint
        syncLocalIdentityWithMessengerSnapshot(
            resolvedSafeSnapshot,
            currentIdentity: effectiveIdentity
        )
        updateLocalCoreStateSnapshot(identity: localIdentity ?? effectiveIdentity)

        self.systemSnapshot = resolvedSystemSnapshot
        let dashboard = DashboardData(
            session: session,
            profile: resolvedProfile,
            devices: sortedDevicesForDisplay(
                resolvedSafeSnapshot.devices,
                currentDeviceId: resolvedProfile.deviceId
            ),
            historySyncJobs: resolvedHistorySyncJobs.jobs,
            chats: resolvedSafeSnapshot.chats,
            inboxItems: []
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
        updateDashboardState(dashboard)
        lastUpdatedAt = Date()
        await ensureApplePushDeliveryConfigured(
            client: client,
            accessToken: session.accessToken
        )

        if restartRealtime {
            await startRealtimeConnection(
                baseURLString: baseURLString,
                accessToken: session.accessToken,
                identity: effectiveIdentity
            )
        }
    }

    private func refreshLinkedDevices(baseURLString: String, suppressErrors: Bool) async {
        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let snapshot = try TrixCorePersistentBridge.loadMessengerSnapshot(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            messengerSnapshot = snapshot
            messengerCheckpoint = snapshot.checkpoint
            updateLocalCoreStateSnapshot(identity: localIdentity ?? context.identity)
            applyLoadedDevicesToDashboard(snapshot.devices)
        } catch {
            if !suppressErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateDashboardState(_ newDashboard: DashboardData?) {
        dashboard = newDashboard
        dashboardConversationRefreshTokens = Self.makeDashboardConversationRefreshTokens(newDashboard)
    }

    private static func makeDashboardConversationRefreshTokens(_ dashboard: DashboardData?) -> [String: String] {
        guard let dashboard else {
            return [:]
        }

        var latestInboxIdByChatId: [String: UInt64] = [:]
        for item in dashboard.inboxItems {
            let chatId = item.message.chatId
            latestInboxIdByChatId[chatId] = max(latestInboxIdByChatId[chatId] ?? 0, item.inboxId)
        }

        var tokens: [String: String] = [:]
        tokens.reserveCapacity(max(dashboard.chats.count, latestInboxIdByChatId.count))

        for chat in dashboard.chats {
            let latestInboxId = latestInboxIdByChatId[chat.chatId] ?? 0
            tokens[chat.chatId] = "\(latestInboxId)-\(chat.lastServerSeq)"
        }

        for (chatId, latestInboxId) in latestInboxIdByChatId where tokens[chatId] == nil {
            tokens[chatId] = "\(latestInboxId)-0"
        }

        return tokens
    }

    private func ensureApplePushDeliveryConfigured(
        client: APIClient,
        accessToken: String
    ) async {
        await requestNotificationAuthorizationIfNeeded()
        registerForRemoteNotificationsIfPossible()
        guard let tokenHex = apnsTokenHex else {
            return
        }

        let _: RegisterApplePushTokenResponse? = try? await client.put(
            "/v0/devices/push-token",
            body: RegisterApplePushTokenRequest(
                tokenHex: tokenHex,
                environment: ApplePushRegistrationEnvironment.current
            ),
            accessToken: accessToken
        )
    }

    private func requestNotificationAuthorizationIfNeeded() async {
        guard !UITestLaunchConfiguration.current.isEnabled else {
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        guard !UserDefaults.standard.bool(
            forKey: Self.didRequestNotificationAuthorizationDefaultsKey
        ) else {
            return
        }

        UserDefaults.standard.set(
            true,
            forKey: Self.didRequestNotificationAuthorizationDefaultsKey
        )

        do {
            try await notificationCoordinator.requestAuthorizationIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerForRemoteNotificationsIfPossible() {
        guard !UITestLaunchConfiguration.current.isEnabled else {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func syncApplePushTokenIfPossible() async {
        guard let tokenHex = apnsTokenHex else {
            return
        }
        guard let baseURLString = currentServerBaseURLString else {
            return
        }
        let accessToken =
            dashboard?.session.accessToken ??
            localIdentity.flatMap {
                authSessionResolutionGate.currentUsableSession(
                    for: $0,
                    baseURLString: normalizedBaseURLString(baseURLString),
                    leewaySeconds: 60
                )?.accessToken
            }
        guard let accessToken else {
            return
        }
        guard let client = try? APIClient(baseURLString: baseURLString) else {
            return
        }

        let _: RegisterApplePushTokenResponse? = try? await client.put(
            "/v0/devices/push-token",
            body: RegisterApplePushTokenRequest(
                tokenHex: tokenHex,
                environment: ApplePushRegistrationEnvironment.current
            ),
            accessToken: accessToken
        )
    }

    private func applyLoadedDevicesToDashboard(_ devices: [DeviceSummary]) {
        guard let dashboard else {
            return
        }

        let sortedDevices = sortedDevicesForDisplay(
            devices,
            currentDeviceId: dashboard.profile.deviceId
        )
        let newPendingIds = pendingDeviceIds(in: sortedDevices)
            .subtracting(linkIntentPendingBaselineDeviceIds)

        updateDashboardState(DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: sortedDevices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: dashboard.chats,
            inboxItems: dashboard.inboxItems
        ))
        lastUpdatedAt = Date()

        guard activeLinkIntent != nil,
              newPendingIds.isEmpty == false else {
            return
        }

        activeLinkIntent = nil
        stopLinkIntentRefreshLoop()
    }

    private func startLinkIntentRefreshLoop(baseURLString: String) {
        guard let activeLinkIntent else {
            return
        }

        linkIntentPollingTask?.cancel()
        linkIntentPollingTask = nil
        let normalizedBaseURL = normalizedBaseURLString(baseURLString)
        let linkIntentId = activeLinkIntent.linkIntentId
        let expiresAtUnix = activeLinkIntent.expiresAtUnix

        linkIntentPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                guard self.activeLinkIntent?.linkIntentId == linkIntentId else {
                    return
                }

                let nowUnix = UInt64(Date().timeIntervalSince1970)
                if nowUnix >= expiresAtUnix {
                    self.activeLinkIntent = nil
                    self.stopLinkIntentRefreshLoop()
                    return
                }

                if !self.isLoading {
                    await self.refreshLinkedDevices(
                        baseURLString: normalizedBaseURL,
                        suppressErrors: true
                    )
                }

                let remainingNanoseconds = UInt64(
                    min(
                        Double(expiresAtUnix - nowUnix),
                        Double(Self.linkIntentPollingIntervalNanoseconds) / 1_000_000_000
                    ) * 1_000_000_000
                )
                try? await Task.sleep(nanoseconds: max(remainingNanoseconds, 250_000_000))
            }
        }
    }

    private func stopLinkIntentRefreshLoop() {
        linkIntentPollingTask?.cancel()
        linkIntentPollingTask = nil
        linkIntentPendingBaselineDeviceIds = []
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
        guard let baseURLString = try? client.baseURLString() else {
            return
        }
        for chatId in chatIds.sorted() {
            do {
                let detail = try await TrixCoreServerBridge.getChat(
                    baseURLString: baseURLString,
                    accessToken: accessToken,
                    chatId: chatId
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
        let baseURLString = try client.baseURLString()
        return try await TrixCoreServerBridge.fetchSystemSnapshot(baseURLString: baseURLString)
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
        let normalizedBaseURL = try client.baseURLString()
        return try await authSessionResolutionGate.resolve(
            identity: identity,
            baseURLString: normalizedBaseURL,
            existingSession: existingSession,
            leewaySeconds: 60
        ) { [self] in
            try await authenticate(client: client, identity: identity)
        }
    }

    private func invalidateCachedAuthSession() {
        if let invalidatedSession = authSessionResolutionGate.invalidate(),
           let baseURLString = currentServerBaseURLString {
            try? TrixCoreServerBridge.clearAccessToken(
                baseURLString: baseURLString,
                accessToken: invalidatedSession.accessToken
            )
        }
        realtimeAccessToken = nil
    }

    private func normalizedBaseURLString(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSafeMessengerState(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) async throws {
        let snapshot = try TrixCorePersistentBridge.loadMessengerSnapshot(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        messengerSnapshot = snapshot
        messengerCheckpoint = snapshot.checkpoint
        syncLocalIdentityWithMessengerSnapshot(snapshot, currentIdentity: identity)
        updateLocalCoreStateSnapshot(identity: localIdentity ?? identity)

        if let dashboard {
            updateDashboardState(DashboardData(
                session: dashboard.session,
                profile: dashboard.profile,
                devices: sortedDevicesForDisplay(
                    snapshot.devices,
                    currentDeviceId: dashboard.profile.deviceId
                ),
                historySyncJobs: dashboard.historySyncJobs,
                chats: snapshot.chats,
                inboxItems: []
            ))
            lastUpdatedAt = Date()

            if activeLinkIntent != nil {
                applyLoadedDevicesToDashboard(snapshot.devices)
            }
        }
    }

    private func syncLocalIdentityWithMessengerSnapshot(
        _ snapshot: SafeMessengerSnapshot,
        currentIdentity: LocalDeviceIdentity
    ) {
        let resolvedAccountId = snapshot.accountId ?? currentIdentity.accountId
        let resolvedDeviceId = snapshot.deviceId ?? currentIdentity.deviceId
        let resolvedSyncChatId = snapshot.accountSyncChatId ?? currentIdentity.accountSyncChatId
        guard resolvedAccountId != currentIdentity.accountId
                || resolvedDeviceId != currentIdentity.deviceId
                || resolvedSyncChatId != currentIdentity.accountSyncChatId
        else {
            return
        }

        let updatedIdentity = LocalDeviceIdentity(
            accountId: resolvedAccountId,
            deviceId: resolvedDeviceId,
            accountSyncChatId: resolvedSyncChatId,
            deviceDisplayName: currentIdentity.deviceDisplayName,
            platform: currentIdentity.platform,
            credentialIdentity: currentIdentity.credentialIdentity,
            accountRootPrivateKeyRaw: currentIdentity.accountRootPrivateKeyRaw,
            transportPrivateKeyRaw: currentIdentity.transportPrivateKeyRaw,
            trustState: currentIdentity.trustState,
            capabilityState: currentIdentity.capabilityState
        )
        try? identityStore.save(updatedIdentity)
        localIdentity = updatedIdentity
    }

    @discardableResult
    func markChatReadLocally(chatId: String, throughServerSeq: UInt64?) -> Bool {
        guard let localIdentity else {
            return false
        }

        do {
            _ = try TrixCorePersistentBridge.markChatRead(
                identity: localIdentity,
                chatId: chatId,
                throughServerSeq: throughServerSeq
            )
            updateLocalCoreStateSnapshot(identity: localIdentity)
            return true
        } catch {
            // Local read state is opportunistic; network/UI flows should not fail on it.
            return false
        }
    }

    @discardableResult
    func acknowledgeChatRead(
        baseURLString: String,
        chatId: String,
        throughServerSeq: UInt64?,
        receiptTargetMessageId: String?
    ) async -> Bool {
        guard localIdentity != nil else {
            return false
        }

        let previousReadCursor = localCoreState?.chatReadState(for: chatId)?.readCursorServerSeq ?? 0
        guard markChatReadLocally(chatId: chatId, throughServerSeq: throughServerSeq) else {
            return false
        }

        guard let throughServerSeq,
              throughServerSeq > previousReadCursor,
              let receiptTargetMessageId = receiptTargetMessageId?.trix_trimmedOrNil()
        else {
            return true
        }

        await sendReadReceipt(
            baseURLString: baseURLString,
            chatId: chatId,
            receiptTargetMessageId: receiptTargetMessageId
        )

        return true
    }

    @discardableResult
    func acknowledgeConversationRead(
        baseURLString: String,
        chatId: String,
        throughMessageId: String?,
        receiptTargetMessageId: String?
    ) async -> Bool {
        guard localIdentity != nil else {
            return false
        }

        let previousReadCursor = messengerReadStates[chatId]?.readCursorServerSeq ?? 0

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let readState = try TrixCorePersistentBridge.markConversationRead(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                throughMessageId: throughMessageId
            )
            messengerReadStates[chatId] = readState
            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )

            guard readState.readCursorServerSeq > previousReadCursor,
                  let receiptTargetMessageId = receiptTargetMessageId?.trix_trimmedOrNil()
            else {
                return true
            }

            await sendReadReceipt(
                baseURLString: baseURLString,
                chatId: chatId,
                receiptTargetMessageId: receiptTargetMessageId
            )
            return true
        } catch {
            return false
        }
    }

    func sendTypingUpdate(chatId: String, isTyping: Bool) async {
        do {
            try await realtimeClient?.sendTypingUpdate(chatId: chatId, isTyping: isTyping)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendHistorySyncProgress(
        jobId: String,
        cursorJson: String?,
        completedChunks: UInt64?
    ) async {
        do {
            try await realtimeClient?.sendHistorySyncProgress(
                jobId: jobId,
                cursorJson: cursorJson,
                completedChunks: completedChunks
            )
        } catch {
            errorMessage = error.localizedDescription
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

        let client = RealtimeWebSocketClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity,
            checkpoint: messengerCheckpoint,
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

        messengerCheckpoint = update.batch.checkpoint ?? messengerCheckpoint
        mergeSafeMessengerReadStates(from: update.batch)

        guard !update.batch.events.isEmpty,
              let baseURLString = currentServerBaseURLString
        else {
            return
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let effectiveIdentity = try reconcileAuthenticatedIdentity(
                baseURLString: try context.client.baseURLString(),
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: effectiveIdentity
            )
        } catch {
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

            guard self.canAccessProtectedData() else {
                await self.stopRealtimeConnection()
                self.finishBackgroundRefresh()
                return
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

    private func beginBackgroundRealtimeTask(baseURLString: String) {
        guard localIdentity != nil else {
            return
        }

        endBackgroundRealtimeTask()
        backgroundRealtimeTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "chat.trix.ios.realtime.handoff"
        ) { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                await self.stopRealtimeConnection()
                self.endBackgroundRealtimeTask()
            }
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard self.backgroundRealtimeTaskID != .invalid else {
                return
            }

            guard self.canAccessProtectedData() else {
                await self.stopRealtimeConnection()
                self.endBackgroundRealtimeTask()
                return
            }

            let recovered = await self.runIncrementalBackgroundRecovery(
                baseURLString: baseURLString
            )
            if !recovered {
                await self.refresh(baseURLString: baseURLString)
            }
            await self.stopRealtimeConnection()
            self.endBackgroundRealtimeTask()
        }
    }

    private func endBackgroundRealtimeTask() {
        guard backgroundRealtimeTaskID != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(backgroundRealtimeTaskID)
        backgroundRealtimeTaskID = .invalid
    }

    private func finishBackgroundRefresh() {
        hasScheduledBackgroundRefresh = false
    }

    private func runIncrementalBackgroundRecovery(
        baseURLString: String,
        resumeRealtimeConnection: Bool = true,
        postNotifications: Bool = false
    ) async -> Bool {
        guard dashboard != nil else {
            return false
        }
        guard canAccessProtectedData() else {
            return false
        }

        do {
            let previousSnapshot = messengerSnapshot
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let effectiveIdentity = try reconcileAuthenticatedIdentity(
                baseURLString: try context.client.baseURLString(),
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            let batch = try TrixCorePersistentBridge.getNewMessengerEvents(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: effectiveIdentity,
                checkpoint: messengerCheckpoint
            )
            messengerCheckpoint = batch.checkpoint ?? messengerCheckpoint
            mergeSafeMessengerReadStates(from: batch)

            if !batch.events.isEmpty || localIdentity?.deviceId != effectiveIdentity.deviceId {
                try await refreshSafeMessengerState(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: effectiveIdentity
                )
            } else {
                updateLocalCoreStateSnapshot(identity: localIdentity ?? effectiveIdentity)
            }

            if postNotifications, let currentSnapshot = messengerSnapshot {
                await postBackgroundMessageNotificationsIfNeeded(
                    previousSnapshot: previousSnapshot,
                    currentSnapshot: currentSnapshot
                )
            }
            if resumeRealtimeConnection {
                await startRealtimeConnection(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: localIdentity ?? effectiveIdentity
                )
            }
            return true
        } catch {
            return false
        }
    }

    private func mergeSafeMessengerReadStates(from batch: SafeMessengerEventBatch) {
        for event in batch.events {
            guard let readState = event.readState else {
                continue
            }
            messengerReadStates[readState.chatId] = readState
        }
    }

    private func postBackgroundMessageNotificationsIfNeeded(
        previousSnapshot: SafeMessengerSnapshot?,
        currentSnapshot: SafeMessengerSnapshot
    ) async {
        guard UIApplication.shared.applicationState != .active else {
            return
        }
        guard let currentAccountId = currentSnapshot.accountId else {
            return
        }

        let previousByChatId = Dictionary(
            uniqueKeysWithValues: (previousSnapshot?.chatListItems ?? []).map { ($0.chatId, $0) }
        )

        for item in currentSnapshot.chatListItems {
            guard item.chatType != .accountSync else {
                continue
            }

            let previousServerSeq = previousByChatId[item.chatId]?.lastServerSeq ?? 0
            guard item.lastServerSeq > previousServerSeq else {
                continue
            }
            guard item.previewSenderAccountId != currentAccountId else {
                continue
            }

            await notificationCoordinator.postMessageNotification(
                identifier: "chat-\(item.chatId)-\(item.lastServerSeq)",
                title: "\(item.displayTitle): New message",
                body: item.previewText ?? ""
            )
        }
    }

    private func canAccessProtectedData() -> Bool {
        UIApplication.shared.isProtectedDataAvailable
    }

    private func shouldSuppressProtectedDataError(_ error: Error) -> Bool {
        guard !canAccessProtectedData() else {
            return false
        }

        return keychainOSStatus(from: error) == errSecInteractionNotAllowed
    }

    private func isTrixInboxRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let trixPayload = userInfo["trix"] as? [String: Any] else {
            return userInfo["aps"] != nil
        }

        return (trixPayload["event"] as? String) == "inbox_update"
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

        updateDashboardState(DashboardData(
            session: session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: mergedChats,
                inboxItems: remainingInboxItems
            ),
            inboxItems: remainingInboxItems
        ))
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
        updateDashboardState(DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: dashboard.chats,
                inboxItems: mergedInboxItems
            ),
            inboxItems: mergedInboxItems
        ))
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
        updateDashboardState(DashboardData(
            session: dashboard.session,
            profile: dashboard.profile,
            devices: dashboard.devices,
            historySyncJobs: dashboard.historySyncJobs,
            chats: mergeChatSummaries(
                existing: dashboard.chats,
                inboxItems: remainingInboxItems
            ),
            inboxItems: remainingInboxItems
        ))
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
        if let messengerSnapshot {
            do {
                let paths = try PersistentCorePaths(identity: identity)
                let chatReadStates = messengerSnapshot.chatListItems.map { item in
                    messengerReadStates[item.chatId] ?? LocalChatReadStateSnapshot(
                        chatId: item.chatId,
                        readCursorServerSeq: 0,
                        unreadCount: item.unreadCount
                    )
                }

                localCoreState = LocalCoreStateSnapshot(
                    mlsStorageRoot: paths.mlsStorageRoot.path,
                    historyDatabasePath: paths.stateDatabasePath.path,
                    syncStatePath: paths.stateDatabasePath.path,
                    ciphersuiteLabel: "Managed by FfiMessengerClient",
                    leaseOwner: "safe_messenger",
                    lastAckedInboxId: nil,
                    localChats: messengerSnapshot.chats,
                    localChatListItems: messengerSnapshot.chatListItems,
                    chatCursors: messengerSnapshot.chatListItems.map {
                        LocalChatCursorSnapshot(chatId: $0.chatId, lastServerSeq: $0.lastServerSeq)
                    },
                    chatReadStates: chatReadStates
                )
            } catch {
                localCoreState = nil
                errorMessage = error.localizedDescription
            }
            return
        }

        do {
            localCoreState = try TrixCorePersistentBridge.localStateSnapshot(identity: identity)
        } catch {
            localCoreState = nil
            errorMessage = error.localizedDescription
        }
    }

    private func sendReadReceipt(
        baseURLString: String,
        chatId: String,
        receiptTargetMessageId: String
    ) async {
        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            var receiptDraft = DebugMessageDraft()
            receiptDraft.kind = .receipt
            receiptDraft.targetMessageId = receiptTargetMessageId
            receiptDraft.receiptKind = .read
            receiptDraft.receiptAtUnix = String(UInt64(Date().timeIntervalSince1970))

            _ = try await TrixCorePersistentBridge.sendMessage(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                draft: receiptDraft
            )

            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
        } catch {
            // Read receipts are opportunistic; keep the chat open even if they fail.
        }
    }
}

private struct AuthenticatedContext {
    let client: APIClient
    let identity: LocalDeviceIdentity
    let session: AuthSessionResponse
}

@MainActor
final class AuthSessionResolutionGate {
    private var cachedAuthSession: CachedAuthSession?
    private var inFlightResolution: (key: AuthSessionResolutionKey, task: Task<AuthSessionResponse, Error>)?

    func currentUsableSession(
        for identity: LocalDeviceIdentity,
        baseURLString: String,
        leewaySeconds: UInt64
    ) -> AuthSessionResponse? {
        guard let cachedAuthSession,
              cachedAuthSession.isUsable(
                  for: identity,
                  baseURLString: normalize(baseURLString),
                  leewaySeconds: leewaySeconds
              ) else {
            return nil
        }

        return cachedAuthSession.session
    }

    func resolve(
        identity: LocalDeviceIdentity,
        baseURLString: String,
        existingSession: AuthSessionResponse?,
        leewaySeconds: UInt64,
        authenticate: @escaping @MainActor () async throws -> AuthSessionResponse
    ) async throws -> AuthSessionResponse {
        let normalizedBaseURL = normalize(baseURLString)
        if let existingSession {
            cache(existingSession, for: identity, baseURLString: normalizedBaseURL)
            return existingSession
        }

        if let cachedAuthSession,
           cachedAuthSession.isUsable(
               for: identity,
               baseURLString: normalizedBaseURL,
               leewaySeconds: leewaySeconds
           ) {
            return cachedAuthSession.session
        }

        let key = AuthSessionResolutionKey(
            baseURLString: normalizedBaseURL,
            accountId: identity.accountId,
            deviceId: identity.deviceId
        )
        if let inFlightResolution,
           inFlightResolution.key == key {
            return try await inFlightResolution.task.value
        }

        let task = Task { @MainActor in
            try await authenticate()
        }
        inFlightResolution = (key, task)

        do {
            let session = try await task.value
            cache(session, for: identity, baseURLString: normalizedBaseURL)
            if inFlightResolution?.key == key {
                inFlightResolution = nil
            }
            return session
        } catch {
            if inFlightResolution?.key == key {
                inFlightResolution = nil
            }
            throw error
        }
    }

    func invalidate() -> AuthSessionResponse? {
        let invalidatedSession = cachedAuthSession?.session
        cachedAuthSession = nil
        inFlightResolution?.task.cancel()
        inFlightResolution = nil
        return invalidatedSession
    }

    private func cache(
        _ session: AuthSessionResponse,
        for identity: LocalDeviceIdentity,
        baseURLString: String
    ) {
        cachedAuthSession = CachedAuthSession(
            baseURLString: normalize(baseURLString),
            accountId: identity.accountId,
            deviceId: identity.deviceId,
            session: session
        )
    }

    private func normalize(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AuthSessionResolutionKey: Equatable {
    let baseURLString: String
    let accountId: String
    let deviceId: String
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

private func sortedDevicesForDisplay(
    _ devices: [DeviceSummary],
    currentDeviceId: String?
) -> [DeviceSummary] {
    devices.sorted { lhs, rhs in
        let lhsPriority = deviceDisplayPriority(lhs, currentDeviceId: currentDeviceId)
        let rhsPriority = deviceDisplayPriority(rhs, currentDeviceId: currentDeviceId)

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.deviceId.localizedCaseInsensitiveCompare(rhs.deviceId) == .orderedAscending
    }
}

private func deviceDisplayPriority(
    _ device: DeviceSummary,
    currentDeviceId: String?
) -> Int {
    switch device.deviceStatus {
    case .pending:
        return 0
    case .active:
        return device.deviceId == currentDeviceId ? 1 : 2
    case .revoked:
        return 3
    }
}

private func pendingDeviceIds(in devices: [DeviceSummary]) -> Set<String> {
    Set(
        devices.compactMap { device in
            device.deviceStatus == .pending ? device.deviceId : nil
        }
    )
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
