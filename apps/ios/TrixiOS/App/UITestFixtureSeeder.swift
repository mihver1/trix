import Foundation

struct UITestFixtureChatRecord: Codable, Equatable {
    let kind: UITestFixtureChatKind
    let chatId: String
    let title: String
}

struct UITestFixtureMessageRecord: Codable, Equatable {
    let kind: UITestFixtureMessageKind
    let chatKind: UITestFixtureChatKind
    let chatId: String
    let messageId: String
    let text: String
}

struct UITestFixtureManifest: Codable, Equatable {
    let conversationScenario: TrixUITestConversationScenario
    let chats: [UITestFixtureChatRecord]
    let messages: [UITestFixtureMessageRecord]

    func chatRecord(for kind: UITestFixtureChatKind) -> UITestFixtureChatRecord? {
        chats.first { $0.kind == kind }
    }

    func messageRecord(for kind: UITestFixtureMessageKind) -> UITestFixtureMessageRecord? {
        messages.first { $0.kind == kind }
    }

    func fixtureChatKind(for chatId: String) -> UITestFixtureChatKind? {
        chats.first { $0.chatId == chatId }?.kind
    }

    func fixtureMessageKind(for messageId: String) -> UITestFixtureMessageKind? {
        messages.first { $0.messageId == messageId }?.kind
    }
}

enum UITestFixtureManifestStore {
    private static let defaultsKey = "ui-test.fixture-manifest"
    nonisolated(unsafe) private static var cachedManifest: UITestFixtureManifest?
    nonisolated(unsafe) private static var hasLoadedManifest = false

    static func load() -> UITestFixtureManifest? {
        if hasLoadedManifest {
            return cachedManifest
        }

        hasLoadedManifest = true

        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            cachedManifest = nil
            return nil
        }

        let manifest = try? JSONDecoder().decode(UITestFixtureManifest.self, from: data)
        cachedManifest = manifest
        return manifest
    }

    static func save(_ manifest: UITestFixtureManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cachedManifest = manifest
        hasLoadedManifest = true
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        cachedManifest = nil
        hasLoadedManifest = true
    }

    static func chatFixtureKind(for chatId: String) -> UITestFixtureChatKind? {
        load()?.fixtureChatKind(for: chatId)
    }

    static func messageFixtureKind(for messageId: String) -> UITestFixtureMessageKind? {
        load()?.fixtureMessageKind(for: messageId)
    }
}

enum UITestFixtureSeederError: LocalizedError {
    case conversationScenarioRequiresApprovedAccount

    var errorDescription: String? {
        switch self {
        case .conversationScenarioRequiresApprovedAccount:
            return "Conversation UI-test scenarios require an approved-account identity."
        }
    }
}

final class UITestScenarioDevice {
    let baseURL: String
    let label: String
    let profileName: String
    var identity: LocalDeviceIdentity

    private var session: AuthSessionResponse?
    private var eventCheckpoint: String?

    init(
        baseURL: String,
        label: String,
        profileName: String,
        identity: LocalDeviceIdentity,
        session: AuthSessionResponse? = nil
    ) {
        self.baseURL = baseURL
        self.label = label
        self.profileName = profileName
        self.identity = identity
        self.session = session
    }

    func authenticate(forceRefresh: Bool = false) throws -> AuthSessionResponse {
        if !forceRefresh, let session {
            return session
        }

        let session = try TrixCoreServerBridge.authenticate(
            baseURLString: baseURL,
            identity: identity
        )
        self.session = session
        if session.deviceStatus == .active, identity.trustState != .active {
            identity = identity.markingActive()
        }
        return session
    }

    func loadSnapshot(forceRefreshSession: Bool = false) throws -> SafeMessengerSnapshot {
        let snapshot = try TrixCorePersistentBridge.loadMessengerSnapshot(
            baseURLString: baseURL,
            accessToken: try authenticate(forceRefresh: forceRefreshSession).accessToken,
            identity: identity
        )
        mergeIdentity(from: snapshot)
        return snapshot
    }

    func loadConversation(
        chatId: String,
        limit: Int = 150
    ) throws -> SafeConversationSnapshot {
        try TrixCorePersistentBridge.loadConversationSnapshot(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity,
            chatId: chatId,
            messageLimit: limit
        )
    }

    func pollEvents() throws -> SafeMessengerEventBatch {
        let batch = try TrixCorePersistentBridge.getNewMessengerEvents(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity,
            checkpoint: eventCheckpoint
        )
        eventCheckpoint = batch.checkpoint ?? eventCheckpoint
        return batch
    }

    func createConversation(
        chatType: ChatType,
        title: String? = nil,
        participantAccountIds: [String]
    ) throws -> CreateChatResponse {
        try TrixCorePersistentBridge.createConversation(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity,
            chatType: chatType,
            title: title,
            participantAccountIds: participantAccountIds
        )
    }

    func createDM(peerAccountId: String) throws -> CreateChatResponse {
        try createConversation(
            chatType: .dm,
            participantAccountIds: [peerAccountId]
        )
    }

    func createGroup(
        title: String,
        participantAccountIds: [String]
    ) throws -> CreateChatResponse {
        try createConversation(
            chatType: .group,
            title: title,
            participantAccountIds: participantAccountIds
        )
    }

    func sendText(chatId: String, text: String) throws -> CreateMessageResponse {
        var draft = DebugMessageDraft()
        draft.text = text

        return try TrixCorePersistentBridge.sendMessage(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity,
            chatId: chatId,
            draft: draft
        )
    }

    func createLinkIntent() throws -> CreateLinkIntentResponse {
        try TrixCorePersistentBridge.createLinkDeviceIntent(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity
        )
    }

    func approveLinkedDevice(deviceId: String) throws -> ApproveDeviceResponse {
        try TrixCorePersistentBridge.approveLinkedDevice(
            baseURLString: baseURL,
            accessToken: try authenticate().accessToken,
            identity: identity,
            deviceId: deviceId
        )
    }

    private func mergeIdentity(from snapshot: SafeMessengerSnapshot) {
        let resolvedAccountId = snapshot.accountId ?? identity.accountId
        let resolvedDeviceId = snapshot.deviceId ?? identity.deviceId
        let resolvedSyncChatId = snapshot.accountSyncChatId ?? identity.accountSyncChatId

        guard resolvedAccountId != identity.accountId
                || resolvedDeviceId != identity.deviceId
                || resolvedSyncChatId != identity.accountSyncChatId
        else {
            return
        }

        identity = LocalDeviceIdentity(
            accountId: resolvedAccountId,
            deviceId: resolvedDeviceId,
            accountSyncChatId: resolvedSyncChatId,
            deviceDisplayName: identity.deviceDisplayName,
            platform: identity.platform,
            credentialIdentity: identity.credentialIdentity,
            accountRootPrivateKeyRaw: identity.accountRootPrivateKeyRaw,
            transportPrivateKeyRaw: identity.transportPrivateKeyRaw,
            trustState: identity.trustState,
            capabilityState: identity.capabilityState
        )
    }
}

struct UITestSeededLaunchState {
    let identity: LocalDeviceIdentity
    let fixtureManifest: UITestFixtureManifest?
}

@MainActor
enum UITestFixtureSeeder {
    static func seedLaunchState(
        seedScenario: TrixUITestSeedScenario?,
        conversationScenario: TrixUITestConversationScenario?,
        baseURLString: String,
        scenarioLabel: String
    ) async throws -> UITestSeededLaunchState {
        if let conversationScenario {
            guard seedScenario != .pendingApproval else {
                throw UITestFixtureSeederError.conversationScenarioRequiresApprovedAccount
            }
            return try await seedConversationScenario(
                conversationScenario,
                baseURLString: baseURLString,
                scenarioLabel: scenarioLabel
            )
        }

        guard let seedScenario else {
            throw UITestFixtureSeederError.conversationScenarioRequiresApprovedAccount
        }

        let identity: LocalDeviceIdentity
        switch seedScenario {
        case .approvedAccount:
            identity = try createApprovedAccountIdentity(
                baseURLString: baseURLString,
                scenarioLabel: scenarioLabel
            )
        case .pendingApproval:
            identity = try createPendingApprovalIdentity(
                baseURLString: baseURLString,
                scenarioLabel: scenarioLabel
            )
        }

        return UITestSeededLaunchState(identity: identity, fixtureManifest: nil)
    }

    static func createApprovedAccountIdentity(
        baseURLString: String,
        scenarioLabel: String
    ) throws -> LocalDeviceIdentity {
        let suffix = uniqueSuffix()
        let form = makeAccountForm(label: "UI \(scenarioLabel)", suffix: suffix)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let created = try TrixCoreServerBridge.createAccount(
            baseURLString: baseURLString,
            form: form,
            bootstrapMaterial: bootstrapMaterial
        )
        return bootstrapMaterial.makeLocalIdentity(
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: form.deviceDisplayName,
            platform: form.platform
        )
    }

    static func createPendingApprovalIdentity(
        baseURLString: String,
        scenarioLabel: String
    ) throws -> LocalDeviceIdentity {
        let owner = try createScenarioDevice(
            baseURL: baseURLString,
            label: "UI \(scenarioLabel) Owner"
        )
        let linkIntent = try owner.createLinkIntent()
        let payload = try LinkIntentPayload.parse(linkIntent.qrPayload)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        return try TrixCorePersistentBridge.completeLinkDevice(
            payload: payload,
            form: makeLinkForm(label: "UI \(scenarioLabel) Link \(uniqueSuffix(length: 6))"),
            bootstrapMaterial: bootstrapMaterial
        )
    }

    static func createScenarioDevice(
        baseURL: String,
        label: String
    ) throws -> UITestScenarioDevice {
        let suffix = uniqueSuffix(length: 8)
        let form = makeAccountForm(label: label, suffix: suffix)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let created = try TrixCoreServerBridge.createAccount(
            baseURLString: baseURL,
            form: form,
            bootstrapMaterial: bootstrapMaterial
        )
        let identity = bootstrapMaterial.makeLocalIdentity(
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: form.deviceDisplayName,
            platform: form.platform
        )
        let device = UITestScenarioDevice(
            baseURL: baseURL,
            label: label,
            profileName: form.profileName,
            identity: identity
        )
        _ = try device.loadSnapshot(forceRefreshSession: true)
        return device
    }

    static func createApprovedLinkedDevice(
        trustedOwner: UITestScenarioDevice,
        label: String
    ) throws -> UITestScenarioDevice {
        let linkIntent = try trustedOwner.createLinkIntent()
        let payload = try LinkIntentPayload.parse(linkIntent.qrPayload)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let linkedIdentity = try TrixCorePersistentBridge.completeLinkDevice(
            payload: payload,
            form: makeLinkForm(label: label),
            bootstrapMaterial: bootstrapMaterial
        )
        let linkedDevice = UITestScenarioDevice(
            baseURL: payload.baseURL,
            label: label,
            profileName: label,
            identity: linkedIdentity
        )

        let approval = try trustedOwner.approveLinkedDevice(deviceId: linkedIdentity.deviceId)
        guard approval.deviceStatus == .active else {
            throw UITestFixtureSeederError.conversationScenarioRequiresApprovedAccount
        }

        _ = try linkedDevice.authenticate(forceRefresh: true)
        _ = try linkedDevice.loadSnapshot(forceRefreshSession: true)
        return linkedDevice
    }

    static func waitForConversation(
        on device: UITestScenarioDevice,
        chatId: String,
        timeoutSeconds: TimeInterval = 10,
        pollIntervalSeconds: TimeInterval = 0.25
    ) async throws -> SafeConversationSnapshot {
        try await waitForCondition(
            timeoutSeconds: timeoutSeconds,
            pollIntervalSeconds: pollIntervalSeconds
        ) {
            let batch = try device.pollEvents()
            if !batch.events.isEmpty {
                _ = try device.loadSnapshot()
            }
            let snapshot = try device.loadConversation(chatId: chatId)
            guard !snapshot.detail.participantProfiles.isEmpty else {
                return nil
            }
            return snapshot
        }
    }

    static func waitForTextMessage(
        _ text: String,
        on device: UITestScenarioDevice,
        chatId: String,
        timeoutSeconds: TimeInterval = 10,
        pollIntervalSeconds: TimeInterval = 0.25
    ) async throws -> SafeMessengerMessage {
        try await waitForCondition(
            timeoutSeconds: timeoutSeconds,
            pollIntervalSeconds: pollIntervalSeconds
        ) {
            let batch = try device.pollEvents()
            if !batch.events.isEmpty {
                _ = try device.loadSnapshot()
            }
            let snapshot = try device.loadConversation(chatId: chatId)
            return snapshot.messages.first { $0.body?.text == text }
        }
    }

    private static func seedConversationScenario(
        _ conversationScenario: TrixUITestConversationScenario,
        baseURLString: String,
        scenarioLabel: String
    ) async throws -> UITestSeededLaunchState {
        switch conversationScenario {
        case .dmAndGroup:
            let primary = try createScenarioDevice(
                baseURL: baseURLString,
                label: "UI \(scenarioLabel) Owner"
            )
            let dmPeer = try createScenarioDevice(
                baseURL: baseURLString,
                label: "UI \(scenarioLabel) DM Peer"
            )
            let groupPeer = try createScenarioDevice(
                baseURL: baseURLString,
                label: "UI \(scenarioLabel) Group Peer"
            )

            let dmConversation = try primary.createDM(peerAccountId: dmPeer.identity.accountId)
            _ = try await waitForConversation(on: dmPeer, chatId: dmConversation.chatId)

            let dmMessageText = "UI DM Seed \(uniqueSuffix(length: 6))"
            let dmMessage = try dmPeer.sendText(chatId: dmConversation.chatId, text: dmMessageText)
            _ = try await waitForTextMessage(
                dmMessageText,
                on: primary,
                chatId: dmConversation.chatId
            )

            let groupTitle = "UI Group \(uniqueSuffix(length: 6))"
            let groupConversation = try primary.createGroup(
                title: groupTitle,
                participantAccountIds: [dmPeer.identity.accountId, groupPeer.identity.accountId]
            )
            _ = try await waitForConversation(on: dmPeer, chatId: groupConversation.chatId)
            _ = try await waitForConversation(on: groupPeer, chatId: groupConversation.chatId)

            let groupMessageText = "UI Group Seed \(uniqueSuffix(length: 6))"
            let groupMessage = try groupPeer.sendText(
                chatId: groupConversation.chatId,
                text: groupMessageText
            )
            _ = try await waitForTextMessage(
                groupMessageText,
                on: primary,
                chatId: groupConversation.chatId
            )

            _ = try primary.loadSnapshot(forceRefreshSession: true)

            let manifest = UITestFixtureManifest(
                conversationScenario: .dmAndGroup,
                chats: [
                    UITestFixtureChatRecord(
                        kind: .dm,
                        chatId: dmConversation.chatId,
                        title: dmPeer.profileName
                    ),
                    UITestFixtureChatRecord(
                        kind: .group,
                        chatId: groupConversation.chatId,
                        title: groupTitle
                    ),
                ],
                messages: [
                    UITestFixtureMessageRecord(
                        kind: .dmSeed,
                        chatKind: .dm,
                        chatId: dmConversation.chatId,
                        messageId: dmMessage.messageId,
                        text: dmMessageText
                    ),
                    UITestFixtureMessageRecord(
                        kind: .groupSeed,
                        chatKind: .group,
                        chatId: groupConversation.chatId,
                        messageId: groupMessage.messageId,
                        text: groupMessageText
                    ),
                ]
            )

            return UITestSeededLaunchState(
                identity: primary.identity,
                fixtureManifest: manifest
            )
        }
    }

    private static func waitForCondition<T>(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval,
        operation: () throws -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?

        while Date() < deadline {
            do {
                if let value = try operation() {
                    return value
                }
                lastError = nil
            } catch {
                lastError = error
            }

            try? await Task.sleep(
                nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000)
            )
        }

        throw lastError ?? NSError(
            domain: "UITestFixtureSeeder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for seeded UI fixture state."]
        )
    }

    private static func makeAccountForm(
        label: String,
        suffix: String
    ) -> CreateAccountForm {
        let normalizedHandlePrefix = label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let handleBase = "iosuitest"
        let maxHandlePrefixLength = max(0, 32 - handleBase.count - suffix.count)
        let handlePrefix = String(normalizedHandlePrefix.prefix(maxHandlePrefixLength))

        var form = CreateAccountForm()
        form.profileName = "\(label) \(suffix)"
        form.handle = "\(handleBase)\(handlePrefix)\(suffix)"
        form.profileBio = "UI smoke fixture for \(label)"
        form.deviceDisplayName = "\(label) Device \(suffix)"
        return form
    }

    private static func makeLinkForm(label: String) -> LinkExistingAccountForm {
        var form = LinkExistingAccountForm()
        form.deviceDisplayName = label
        return form
    }

    private static func uniqueSuffix(length: Int = 8) -> String {
        String(
            UUID().uuidString
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .prefix(length)
        )
    }
}
