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
    private(set) var isPerformingChatLifecycleAction = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let identityStore: LocalDeviceIdentityStore
    @ObservationIgnored private let notificationCoordinator = IOSNotificationCoordinator()
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var directoryAccountCache: [String: DirectoryAccountSummary] = [:]
    @ObservationIgnored private let realtimeSession = RealtimeSessionCoordinator()
    @ObservationIgnored private let authenticatedSessionCoordinator: AuthenticatedSessionCoordinator
    @ObservationIgnored private var currentServerBaseURLString: String?
    @ObservationIgnored private var hasScheduledBackgroundRefresh = false
    @ObservationIgnored private var messengerSnapshot: SafeMessengerSnapshot?
    @ObservationIgnored private var messengerReadStates: [String: LocalChatReadStateSnapshot] = [:]
    @ObservationIgnored private var conversationSnapshotCache: [String: SafeConversationSnapshot] = [:]
    @ObservationIgnored private var cachedAttachmentFiles: [String: DownloadedAttachmentFile] = [:]
    @ObservationIgnored private var attachmentDownloadTasks: [String: Task<DownloadedAttachmentFile, Error>] = [:]
    @ObservationIgnored private var apnsTokenHex: String?
    @ObservationIgnored private var backgroundRealtimeTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var linkIntentPollingTask: Task<Void, Never>?
    @ObservationIgnored private var linkIntentPendingBaselineDeviceIds: Set<String> = []
    @ObservationIgnored private var identityInvalidationGeneration: UInt64 = 0
    private static let linkIntentPollingIntervalNanoseconds: UInt64 = 3_000_000_000
    private static let didRequestNotificationAuthorizationDefaultsKey =
        "notifications.ios.authorizationRequested"

    init(identityStore: LocalDeviceIdentityStore = LocalDeviceIdentityStore()) {
        self.identityStore = identityStore
        self.authenticatedSessionCoordinator = AuthenticatedSessionCoordinator()
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
                errorMessage = error.trixUserFacingMessage
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
            let resolvedBaseURLString = try authenticatedSessionCoordinator.validatedBaseURLString(
                baseURLString
            )

            if let localIdentity {
                do {
                    try await refreshAuthenticatedState(
                        baseURLString: resolvedBaseURLString,
                        identity: localIdentity
                    )
                } catch let error as APIError where isPendingApprovalAuthFailure(error, identity: localIdentity) {
                    invalidateCachedAuthSession()
                    await stopRealtimeConnection()
                    updateDashboardState(nil)
                    conversationSnapshotCache = [:]
                    messengerSnapshot = nil
                    realtimeSession.clearCheckpoint()
                    messengerReadStates = [:]
                    await updateLocalCoreStateSnapshot(identity: localIdentity)
                    systemSnapshot = try? await fetchSystemSnapshot(
                        baseURLString: resolvedBaseURLString
                    )
                    lastUpdatedAt = Date()
                }
            } else {
                await stopRealtimeConnection()
                updateDashboardState(nil)
                conversationSnapshotCache = [:]
                localCoreState = nil
                messengerSnapshot = nil
                realtimeSession.clearCheckpoint()
                messengerReadStates = [:]
                systemSnapshot = try await fetchSystemSnapshot(
                    baseURLString: resolvedBaseURLString
                )
                lastUpdatedAt = Date()
            }
        } catch {
            if let localIdentity,
               await restoreOfflineDashboardIfPossible(
                   baseURLString: baseURLString,
                   identity: localIdentity,
                   sourceError: error
               ) {
                return
            }
            if !shouldSuppressProtectedDataError(error) {
                errorMessage = error.trixUserFacingMessage
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

        if realtimeSession.hasActiveLoop {
            return
        }

        if let localIdentity,
           let cachedAuthSession = authenticatedSessionCoordinator.currentUsableSession(
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
        errorMessage = error.trixUserFacingMessage
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
            let resolvedBaseURLString = try authenticatedSessionCoordinator.validatedBaseURLString(
                baseURLString
            )
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let response = try await TrixCoreServerBridge.createAccount(
                baseURLString: resolvedBaseURLString,
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
            await updateLocalCoreStateSnapshot(identity: localIdentity)
            conversationSnapshotCache = [:]

            try await refreshAuthenticatedState(
                baseURLString: resolvedBaseURLString,
                identity: localIdentity
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let resolvedBaseURLString = try authenticatedSessionCoordinator.validatedBaseURLString(
                baseURLString
            )
            let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
            let localIdentity = try await TrixCorePersistentBridge.completeLinkDevice(
                payload: payload,
                form: form,
                bootstrapMaterial: bootstrapMaterial
            )

            try identityStore.save(localIdentity)
            self.localIdentity = localIdentity
            await updateLocalCoreStateSnapshot(identity: localIdentity)
            updateDashboardState(nil)
            conversationSnapshotCache = [:]
            activeLinkIntent = nil
            stopLinkIntentRefreshLoop()
            invalidateCachedAuthSession()
            systemSnapshot = try await fetchSystemSnapshot(baseURLString: resolvedBaseURLString)
            lastUpdatedAt = Date()
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    func forgetLocalDevice() {
        do {
            identityInvalidationGeneration &+= 1
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
            conversationSnapshotCache = [:]
            realtimeSession.clearCheckpoint()
            messengerReadStates = [:]
            updateDashboardState(nil)
            activeLinkIntent = nil
            directoryAccountCache = [:]
            errorMessage = nil
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.createLinkDeviceIntent(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            let baselineSnapshot = try? await TrixCorePersistentBridge.loadMessengerSnapshot(
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
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.approveLinkedDevice(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                deviceId: deviceId
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let _: RevokeDeviceResponse = try await TrixCorePersistentBridge.revokeDevice(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                deviceId: deviceId,
                reason: trimmedReason
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return true
        } catch {
            errorMessage = error.trixUserFacingMessage
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

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.publishKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                count: count
            )

            await updateLocalCoreStateSnapshot(identity: context.identity)
            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            return try await TrixCoreServerBridge.getAccountKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                accountId: normalizedAccountId
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            return try await TrixCoreServerBridge.reserveKeyPackages(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                accountId: normalizedAccountId,
                deviceIds: normalizedDeviceIds
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            return try await TrixCorePersistentBridge.dryRunCreateGroupCommit(
                identity: identity,
                reservedPackages: reservedPackages
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.createConversation(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatType: chatType,
                title: title,
                participantAccountIds: participantAccountIds
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.addConversationMembers(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                participantAccountIds: participantAccountIds
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.removeConversationMembers(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                participantAccountIds: participantAccountIds
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    @discardableResult
    func leaveChat(
        baseURLString: String,
        chatId: String,
        chatType: ChatType,
        scope: FfiLeaveChatScope
    ) async -> ModifyChatMembersResponse? {
        guard chatType != .accountSync else {
            errorMessage = "This chat cannot be left."
            return nil
        }

        guard !isLoading, !isPerformingChatLifecycleAction else {
            return nil
        }

        isPerformingChatLifecycleAction = true
        errorMessage = nil

        defer {
            isPerformingChatLifecycleAction = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response = try TrixCorePersistentBridge.leaveConversation(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                scope: scope
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func dmGlobalDeleteChat(
        baseURLString: String,
        chatId: String,
        chatType: ChatType
    ) async -> ModifyChatMembersResponse? {
        guard chatType == .dm else {
            errorMessage = "Global delete is only available for direct messages."
            return nil
        }

        guard !isLoading, !isPerformingChatLifecycleAction else {
            return nil
        }

        isPerformingChatLifecycleAction = true
        errorMessage = nil

        defer {
            isPerformingChatLifecycleAction = false
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let response = try TrixCorePersistentBridge.dmGlobalDeleteConversation(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
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
            let response = try await TrixCorePersistentBridge.addConversationDevices(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                deviceIds: deviceIds
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            let response = try await TrixCorePersistentBridge.removeConversationDevices(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity,
                chatId: chatId,
                deviceIds: deviceIds
            )

            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return response
        } catch {
            errorMessage = error.trixUserFacingMessage
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
            errorMessage = error.trixUserFacingMessage
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
            errorMessage = error.trixUserFacingMessage
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
                    errorMessage = error.trixUserFacingMessage
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
                errorMessage = error.trixUserFacingMessage
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
            errorMessage = error.trixUserFacingMessage
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
            errorMessage = error.trixUserFacingMessage
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
        let account = try await TrixCoreServerBridge.getAccount(
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
        let accounts = try await TrixCoreServerBridge.searchAccountDirectory(
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
                    let account = try await TrixCoreServerBridge.getAccount(
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
            let updated = try await TrixCoreServerBridge.updateAccountProfile(
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
            try await refreshAuthenticatedState(
                baseURLString: context.baseURLString,
                identity: context.identity
            )
            return updated
        } catch {
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    func fetchConversationSnapshot(
        baseURLString: String,
        chatId: String
    ) async throws -> SafeConversationSnapshot {
        let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
        let snapshot = try await TrixCorePersistentBridge.loadConversationSnapshot(
            baseURLString: baseURLString,
            accessToken: context.session.accessToken,
            identity: context.identity,
            chatId: chatId
        )
        conversationSnapshotCache[chatId] = snapshot
        seedDirectoryAccountCache(with: snapshot.detail.participantProfiles)
        return snapshot
    }

    func cachedConversationSnapshot(chatId: String) -> SafeConversationSnapshot? {
        conversationSnapshotCache[chatId]
    }

    private func refreshAuthenticatedState(
        baseURLString: String,
        identity: LocalDeviceIdentity,
        session existingSession: AuthSessionResponse? = nil,
        restartRealtime: Bool = true
    ) async throws {
        let context = try await makeAuthenticatedContext(
            baseURLString: baseURLString,
            identity: identity,
            existingSession: existingSession
        )
        async let systemSnapshot = TrixCoreServerBridge.fetchSystemSnapshot(
            baseURLString: context.baseURLString
        )

        async let profile = TrixCoreServerBridge.getAccountProfile(
            baseURLString: context.baseURLString,
            accessToken: context.session.accessToken
        )
        async let historySyncJobs = TrixCoreServerBridge.listHistorySyncJobs(
            baseURLString: context.baseURLString,
            accessToken: context.session.accessToken
        )
        async let safeSnapshotTask: SafeMessengerSnapshot = TrixCorePersistentBridge.loadMessengerSnapshot(
            baseURLString: context.baseURLString,
            accessToken: context.session.accessToken,
            identity: context.identity
        )

        let resolvedSystemSnapshot = try await systemSnapshot
        let resolvedProfile = try await profile
        let resolvedHistorySyncJobs = try await historySyncJobs
        let resolvedSafeSnapshot = try await safeSnapshotTask

        messengerSnapshot = resolvedSafeSnapshot
        realtimeSession.replaceCheckpoint(resolvedSafeSnapshot.checkpoint)
        syncLocalIdentityWithMessengerSnapshot(
            resolvedSafeSnapshot,
            currentIdentity: context.identity
        )
        await updateLocalCoreStateSnapshot(identity: localIdentity ?? context.identity)

        self.systemSnapshot = resolvedSystemSnapshot
        let dashboard = DashboardData(
            session: context.session,
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
            baseURLString: context.baseURLString,
            accessToken: context.session.accessToken
        )

        if restartRealtime {
            await startRealtimeConnection(
                baseURLString: context.baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
        }
    }

    private func restoreOfflineDashboardIfPossible(
        baseURLString: String,
        identity: LocalDeviceIdentity,
        sourceError: Error
    ) async -> Bool {
        guard identity.trustState == .active else {
            return false
        }

        do {
            let normalizedBaseURL = normalizedBaseURLString(baseURLString)
            let snapshot = try await TrixCorePersistentBridge.loadMessengerSnapshot(
                baseURLString: normalizedBaseURL,
                accessToken: "",
                identity: identity
            )
            let profile = offlineAccountProfile(identity: identity, snapshot: snapshot)
            let session =
                authenticatedSessionCoordinator.currentUsableSession(
                    for: identity,
                    baseURLString: normalizedBaseURL,
                    leewaySeconds: 0
                ) ??
                AuthSessionResponse(
                    accessToken: "",
                    expiresAtUnix: UInt64(Date().timeIntervalSince1970),
                    accountId: profile.accountId,
                    deviceStatus: profile.deviceStatus
                )

            await stopRealtimeConnection()
            messengerSnapshot = snapshot
            realtimeSession.replaceCheckpoint(snapshot.checkpoint)
            syncLocalIdentityWithMessengerSnapshot(snapshot, currentIdentity: identity)
            await updateLocalCoreStateSnapshot(identity: localIdentity ?? identity)
            systemSnapshot = nil
            let dashboard = DashboardData(
                session: session,
                profile: profile,
                devices: sortedDevicesForDisplay(
                    snapshot.devices,
                    currentDeviceId: profile.deviceId
                ),
                historySyncJobs: [],
                chats: snapshot.chats,
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
            if !shouldSuppressProtectedDataError(sourceError) {
                errorMessage = sourceError.trixUserFacingMessage
            }
            return true
        } catch {
            return false
        }
    }

    private func refreshLinkedDevices(baseURLString: String, suppressErrors: Bool) async {
        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            let snapshot = try await TrixCorePersistentBridge.loadMessengerSnapshot(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            messengerSnapshot = snapshot
            realtimeSession.replaceCheckpoint(snapshot.checkpoint)
            await updateLocalCoreStateSnapshot(identity: localIdentity ?? context.identity)
            applyLoadedDevicesToDashboard(snapshot.devices)
        } catch {
            if !suppressErrors {
                errorMessage = error.trixUserFacingMessage
            }
        }
    }

    private func updateDashboardState(_ newDashboard: DashboardData?) {
        dashboard = newDashboard
        dashboardConversationRefreshTokens = Self.makeDashboardConversationRefreshTokens(newDashboard)
    }

    private func offlineAccountProfile(
        identity: LocalDeviceIdentity,
        snapshot: SafeMessengerSnapshot
    ) -> AccountProfileResponse {
        let cachedProfile = snapshot.chats
            .lazy
            .flatMap(\.participantProfiles)
            .first { $0.accountId == identity.accountId }

        return AccountProfileResponse(
            accountId: identity.accountId,
            handle: cachedProfile?.handle,
            profileName: cachedProfile?.profileName ?? "Offline Account",
            profileBio: cachedProfile?.profileBio,
            deviceId: snapshot.deviceId ?? identity.deviceId,
            deviceStatus: identity.trustState == .pendingApproval ? .pending : .active
        )
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
        baseURLString: String,
        accessToken: String
    ) async {
        await requestNotificationAuthorizationIfNeeded()
        registerForRemoteNotificationsIfPossible()
        guard let tokenHex = apnsTokenHex else {
            return
        }

        await registerApplePushTokenIfPossible(
            baseURLString: baseURLString,
            accessToken: accessToken,
            tokenHex: tokenHex
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
            errorMessage = error.trixUserFacingMessage
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
                authenticatedSessionCoordinator.currentUsableSession(
                    for: $0,
                    baseURLString: normalizedBaseURLString(baseURLString),
                    leewaySeconds: 60
                )?.accessToken
            }
        guard let accessToken else {
            return
        }

        await registerApplePushTokenIfPossible(
            baseURLString: baseURLString,
            accessToken: accessToken,
            tokenHex: tokenHex
        )
    }

    private func registerApplePushTokenIfPossible(
        baseURLString: String?,
        accessToken: String,
        tokenHex: String
    ) async {
        guard let baseURLString else {
            return
        }

        let _: RegisterApplePushTokenResponse? = try? await TrixCoreServerBridge.registerApplePushToken(
            baseURLString: baseURLString,
            accessToken: accessToken,
            tokenHex: tokenHex,
            environment: ApplePushRegistrationEnvironment.current
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

    private func fetchSystemSnapshot(baseURLString: String) async throws -> ServerSnapshot {
        return try await TrixCoreServerBridge.fetchSystemSnapshot(baseURLString: baseURLString)
    }

    private func makeAuthenticatedContext(
        baseURLString: String,
        identity explicitIdentity: LocalDeviceIdentity? = nil,
        existingSession: AuthSessionResponse? = nil
    ) async throws -> AuthenticatedContext {
        guard let identity = explicitIdentity ?? localIdentity else {
            throw AppModelError.localIdentityMissing
        }
        let invalidationGeneration = identityInvalidationGeneration

        let context = try await authenticatedSessionCoordinator.makeAuthenticatedContext(
            baseURLString: baseURLString,
            identity: identity,
            existingSession: existingSession
        )
        guard identityInvalidationGeneration == invalidationGeneration else {
            throw CancellationError()
        }
        if context.identity != identity {
            try identityStore.save(context.identity)
        }
        localIdentity = context.identity
        return context
    }

    private func invalidateCachedAuthSession() {
        authenticatedSessionCoordinator.invalidateCachedAuthSession(
            currentServerBaseURLString: currentServerBaseURLString
        )
    }

    private func normalizedBaseURLString(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSafeMessengerState(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) async throws {
        let snapshot = try await TrixCorePersistentBridge.loadMessengerSnapshot(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        messengerSnapshot = snapshot
        realtimeSession.replaceCheckpoint(snapshot.checkpoint)
        syncLocalIdentityWithMessengerSnapshot(snapshot, currentIdentity: identity)
        await updateLocalCoreStateSnapshot(identity: localIdentity ?? identity)

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
            let readState = try await TrixCorePersistentBridge.markConversationRead(
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
            _ = try await realtimeSession.sendTypingUpdate(chatId: chatId, isTyping: isTyping)
        } catch {
            errorMessage = error.trixUserFacingMessage
        }
    }

    @discardableResult
    func sendHistorySyncProgress(
        jobId: String,
        cursorJson: String?,
        completedChunks: UInt64?
    ) async -> Bool {
        do {
            return try await realtimeSession.sendHistorySyncProgress(
                jobId: jobId,
                cursorJson: cursorJson,
                completedChunks: completedChunks
            )
        } catch {
            errorMessage = error.trixUserFacingMessage
            return false
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
        await realtimeSession.start(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity,
            onBatch: { [weak self] batch in
                await self?.handleRealtimeUpdate(batch)
            },
            onDisconnect: { [weak self] reason in
                await self?.handleRealtimeDisconnect(reason)
            }
        )
    }

    private func stopRealtimeConnection() async {
        await realtimeSession.stop()
    }

    private func disconnectRealtimeConnection() {
        realtimeSession.disconnect()
    }

    private func handleRealtimeUpdate(
        _ batch: SafeMessengerEventBatch
    ) async {
        mergeSafeMessengerReadStates(from: batch)

        guard !batch.events.isEmpty,
              let baseURLString = currentServerBaseURLString
        else {
            return
        }

        do {
            let context = try await makeAuthenticatedContext(baseURLString: baseURLString)
            try await refreshSafeMessengerState(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
        } catch {
            scheduleBackgroundRefresh(delayNanoseconds: 300_000_000)
        }
    }

    private func handleRealtimeDisconnect(
        _ reason: String?
    ) async {
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
            let batch = try await realtimeSession.pollNewEvents(
                baseURLString: baseURLString,
                accessToken: context.session.accessToken,
                identity: context.identity
            )
            mergeSafeMessengerReadStates(from: batch)

            if !batch.events.isEmpty || localIdentity?.deviceId != context.identity.deviceId {
                try await refreshSafeMessengerState(
                    baseURLString: baseURLString,
                    accessToken: context.session.accessToken,
                    identity: context.identity
                )
            } else {
                await updateLocalCoreStateSnapshot(identity: localIdentity ?? context.identity)
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
                    identity: localIdentity ?? context.identity
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

    private func updateLocalCoreStateSnapshot(identity: LocalDeviceIdentity) async {
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
                errorMessage = error.trixUserFacingMessage
            }
            return
        }

        do {
            localCoreState = try await TrixCorePersistentBridge.localStateSnapshot(identity: identity)
        } catch {
            localCoreState = nil
            errorMessage = error.trixUserFacingMessage
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
