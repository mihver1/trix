import Foundation

enum MacUITestFixtureSeederError: LocalizedError {
    case missingBaseURL
    case conversationScenarioRequiresApprovedStyleAccount

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "UI tests require TRIX_MACOS_UI_TEST_BASE_URL when seeding server-backed fixtures."
        case .conversationScenarioRequiresApprovedStyleAccount:
            return "Conversation UI-test scenarios require an approved-account or restore-session identity, not pending approval."
        }
    }
}

@MainActor
enum MacUITestFixtureSeeder {
    static func seedAccountState(
        _ seed: MacUITestSeedScenario,
        baseURLString: String,
        scenarioLabel: String,
        sessionStore: SessionStore,
        keychainStore: KeychainStore
    ) async throws {
        let normalized = try normalizedBaseURLString(baseURLString)
        switch seed {
        case .approvedAccount, .restoreSession:
            try await seedApprovedOrRestoreActiveAccount(
                baseURLString: normalized,
                scenarioLabel: scenarioLabel,
                sessionStore: sessionStore,
                keychainStore: keychainStore
            )
        case .pendingApproval:
            try await seedPendingApproval(
                baseURLString: normalized,
                scenarioLabel: scenarioLabel,
                sessionStore: sessionStore,
                keychainStore: keychainStore
            )
        }
    }

    static func seedConversationBundle(
        accountSeed: MacUITestSeedScenario,
        conversation: MacUITestConversationScenario,
        baseURLString: String,
        scenarioLabel: String,
        sessionStore: SessionStore,
        keychainStore: KeychainStore
    ) async throws -> MacUITestFixtureManifest {
        let normalized = try normalizedBaseURLString(baseURLString)
        guard accountSeed != .pendingApproval else {
            throw MacUITestFixtureSeederError.conversationScenarioRequiresApprovedStyleAccount
        }

        let primary = try await seedApprovedOrRestoreActiveAccount(
            baseURLString: normalized,
            scenarioLabel: scenarioLabel,
            sessionStore: sessionStore,
            keychainStore: keychainStore
        )

        switch conversation {
        case .dmAndGroup:
            return try await seedDmAndGroupManifest(
                primary: primary,
                baseURLString: normalized,
                scenarioLabel: scenarioLabel
            )
        }
    }

    // MARK: - Internals

    private struct SeededPrimaryAccount {
        let identity: DeviceIdentityMaterial
        let auth: AuthSessionResponse
        let accountId: UUID
        let deviceId: UUID
        let accountSyncChatId: UUID
        let profileName: String
    }

    private static func normalizedBaseURLString(_ raw: String) throws -> String {
        guard let url = ServerEndpoint.normalizedURL(from: raw) else {
            throw MacUITestFixtureSeederError.missingBaseURL
        }
        return url.absoluteString
    }

    private static func persist(
        identity: DeviceIdentityMaterial,
        accessToken: String?,
        session: PersistedSession,
        sessionStore: SessionStore,
        keychainStore: KeychainStore
    ) throws {
        let stored = identity.storedIdentity
        if let accountRootSeed = stored.accountRootSeed {
            try keychainStore.save(accountRootSeed, for: .accountRootSeed)
        } else {
            try keychainStore.removeValue(for: .accountRootSeed)
        }
        try keychainStore.save(stored.transportSeed, for: .transportSeed)
        try keychainStore.save(stored.credentialIdentity, for: .credentialIdentity)
        if let accessToken {
            try keychainStore.save(Data(accessToken.utf8), for: .accessToken)
        } else {
            try keychainStore.removeValue(for: .accessToken)
        }
        try sessionStore.save(session)
    }

    @discardableResult
    private static func seedApprovedOrRestoreActiveAccount(
        baseURLString: String,
        scenarioLabel: String,
        sessionStore: SessionStore,
        keychainStore: KeychainStore
    ) async throws -> SeededPrimaryAccount {
        let client = try TrixAPIClient(baseURL: ServerEndpoint.normalizedURL(from: baseURLString)!)
        let suffix = uniqueSuffix()
        let profileName = "UI Mac \(scenarioLabel) \(suffix)"
        let handle = makeHandle(scenarioLabel: scenarioLabel, suffix: suffix)
        let deviceDisplayName = "Mac UI \(scenarioLabel) \(suffix)"

        let identity = try DeviceIdentityMaterial.make(
            profileName: profileName,
            handle: handle,
            deviceDisplayName: deviceDisplayName,
            platform: DeviceIdentityMaterial.platform
        )

        let created = try await client.createAccount(
            handle: handle,
            profileName: profileName,
            profileBio: "UI smoke fixture for \(scenarioLabel)",
            deviceDisplayName: deviceDisplayName,
            identity: identity
        )

        let auth = try await client.authenticate(deviceId: created.deviceId, identity: identity)

        let session = PersistedSession(
            baseURLString: baseURLString,
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            profileName: profileName,
            handle: handle,
            deviceDisplayName: deviceDisplayName,
            deviceStatus: auth.deviceStatus
        )

        try persist(
            identity: identity,
            accessToken: nil,
            session: session,
            sessionStore: sessionStore,
            keychainStore: keychainStore
        )

        let paths = try WorkspaceStorePaths.forAccount(created.accountId)
        let messenger = try TrixMessengerClient(
            workspaceRoot: paths.rootURL,
            baseURL: baseURLString,
            accessToken: auth.accessToken,
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: deviceDisplayName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentity: identity.storedIdentity.credentialIdentity,
            accountRootPrivateKey: identity.storedIdentity.accountRootSeed,
            transportPrivateKey: identity.storedIdentity.transportSeed
        )
        _ = try await messenger.loadSnapshot()

        return SeededPrimaryAccount(
            identity: identity,
            auth: auth,
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            profileName: profileName
        )
    }

    private static func seedPendingApproval(
        baseURLString: String,
        scenarioLabel: String,
        sessionStore: SessionStore,
        keychainStore: KeychainStore
    ) async throws {
        let client = try TrixAPIClient(baseURL: ServerEndpoint.normalizedURL(from: baseURLString)!)
        let ownerSuffix = uniqueSuffix(length: 8)
        let ownerProfile = "UI \(scenarioLabel) Owner \(ownerSuffix)"
        let ownerHandle = makeHandle(prefix: "macown", scenarioLabel: scenarioLabel, suffix: ownerSuffix)
        let ownerDeviceName = "Owner \(scenarioLabel) \(ownerSuffix)"

        let ownerIdentity = try DeviceIdentityMaterial.make(
            profileName: ownerProfile,
            handle: ownerHandle,
            deviceDisplayName: ownerDeviceName,
            platform: DeviceIdentityMaterial.platform
        )

        let ownerCreated = try await client.createAccount(
            handle: ownerHandle,
            profileName: ownerProfile,
            profileBio: "UI pending fixture owner",
            deviceDisplayName: ownerDeviceName,
            identity: ownerIdentity
        )

        let ownerAuth = try await client.authenticate(deviceId: ownerCreated.deviceId, identity: ownerIdentity)

        let ownerPaths = try WorkspaceStorePaths.forAccount(ownerCreated.accountId)
        let ownerMessenger = try TrixMessengerClient(
            workspaceRoot: ownerPaths.rootURL,
            baseURL: baseURLString,
            accessToken: ownerAuth.accessToken,
            accountId: ownerCreated.accountId,
            deviceId: ownerCreated.deviceId,
            accountSyncChatId: ownerCreated.accountSyncChatId,
            deviceDisplayName: ownerDeviceName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentity: ownerIdentity.storedIdentity.credentialIdentity,
            accountRootPrivateKey: ownerIdentity.storedIdentity.accountRootSeed,
            transportPrivateKey: ownerIdentity.storedIdentity.transportSeed
        )
        _ = try await ownerMessenger.loadSnapshot()

        let intent = try await ownerMessenger.createLinkDeviceIntent()
        let linkPayload = intent.payload

        let linkSuffix = uniqueSuffix(length: 6)
        let linkedDeviceName = "UI \(scenarioLabel) Link \(linkSuffix)"
        let linkedIdentity = try DeviceIdentityMaterial.makeLinkedDevice(
            deviceDisplayName: linkedDeviceName,
            platform: DeviceIdentityMaterial.platform
        )

        let payload = try decodeLinkIntentPayload(linkPayload)
        let linkedPaths = try WorkspaceStorePaths.forAccount(payload.accountId)
        let linkedMessenger = try TrixMessengerClient(
            workspaceRoot: linkedPaths.rootURL,
            baseURL: baseURLString,
            accessToken: nil,
            accountId: payload.accountId,
            deviceId: nil,
            accountSyncChatId: nil,
            deviceDisplayName: linkedDeviceName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentity: linkedIdentity.storedIdentity.credentialIdentity,
            accountRootPrivateKey: nil,
            transportPrivateKey: linkedIdentity.storedIdentity.transportSeed
        )

        let completed = try await linkedMessenger.completeLinkDevice(
            linkPayload: linkPayload,
            deviceDisplayName: linkedDeviceName
        )

        let session = PersistedSession(
            baseURLString: baseURLString,
            accountId: completed.accountId,
            deviceId: completed.deviceId,
            accountSyncChatId: nil,
            profileName: "Linked Account",
            handle: nil,
            deviceDisplayName: linkedDeviceName,
            deviceStatus: completed.deviceStatus
        )

        try persist(
            identity: linkedIdentity,
            accessToken: nil,
            session: session,
            sessionStore: sessionStore,
            keychainStore: keychainStore
        )
    }

    private static func seedDmAndGroupManifest(
        primary: SeededPrimaryAccount,
        baseURLString: String,
        scenarioLabel: String
    ) async throws -> MacUITestFixtureManifest {
        let client = try TrixAPIClient(baseURL: ServerEndpoint.normalizedURL(from: baseURLString)!)

        let dmPeer = try await makeEphemeralPeerDevice(
            label: "UI \(scenarioLabel) DM Peer",
            baseURLString: baseURLString,
            client: client
        )
        let groupPeer = try await makeEphemeralPeerDevice(
            label: "UI \(scenarioLabel) Group Peer",
            baseURLString: baseURLString,
            client: client
        )

        let primaryPaths = try WorkspaceStorePaths.forAccount(primary.accountId)
        let primaryMessenger = try TrixMessengerClient(
            workspaceRoot: primaryPaths.rootURL,
            baseURL: baseURLString,
            accessToken: primary.auth.accessToken,
            accountId: primary.accountId,
            deviceId: primary.deviceId,
            accountSyncChatId: primary.accountSyncChatId,
            deviceDisplayName: primary.profileName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentity: primary.identity.storedIdentity.credentialIdentity,
            accountRootPrivateKey: primary.identity.storedIdentity.accountRootSeed,
            transportPrivateKey: primary.identity.storedIdentity.transportSeed
        )

        let dmResult = try await primaryMessenger.createConversation(
            chatType: .dm,
            title: nil,
            participantAccountIds: [dmPeer.accountId]
        )
        let dmChatId = dmResult.conversationId

        try await waitForConversationParticipants(
            messenger: primaryMessenger,
            chatId: dmChatId
        )

        let dmMessageText = "UI DM Seed \(uniqueSuffix(length: 6))"
        let dmSend = try await primaryMessenger.sendMessage(
            conversationId: dmChatId,
            body: .text(dmMessageText)
        )
        let dmMessageId = dmSend.message.messageId

        try await waitForTextMessage(dmMessageText, messenger: dmPeer.messenger, chatId: dmChatId)

        let groupTitle = "UI Group \(uniqueSuffix(length: 6))"
        let groupResult = try await primaryMessenger.createConversation(
            chatType: .group,
            title: groupTitle,
            participantAccountIds: [dmPeer.accountId, groupPeer.accountId]
        )
        let groupChatId = groupResult.conversationId

        try await waitForConversationParticipants(
            messenger: primaryMessenger,
            chatId: groupChatId
        )

        let groupMessageText = "UI Group Seed \(uniqueSuffix(length: 6))"
        let groupSend = try await groupPeer.messenger.sendMessage(
            conversationId: groupChatId,
            body: .text(groupMessageText)
        )
        let groupMessageId = groupSend.message.messageId

        try await waitForTextMessage(groupMessageText, messenger: primaryMessenger, chatId: groupChatId)

        _ = try await primaryMessenger.loadSnapshot()

        return MacUITestFixtureManifest(
            conversationScenario: .dmAndGroup,
            chats: [
                MacUITestFixtureChatRecord(
                    kind: .dm,
                    chatId: dmChatId.uuidString,
                    title: dmPeer.profileName
                ),
                MacUITestFixtureChatRecord(
                    kind: .group,
                    chatId: groupChatId.uuidString,
                    title: groupTitle
                ),
            ],
            messages: [
                MacUITestFixtureMessageRecord(
                    kind: .dmSeed,
                    chatKind: .dm,
                    chatId: dmChatId.uuidString,
                    messageId: dmMessageId.uuidString,
                    text: dmMessageText
                ),
                MacUITestFixtureMessageRecord(
                    kind: .groupSeed,
                    chatKind: .group,
                    chatId: groupChatId.uuidString,
                    messageId: groupMessageId.uuidString,
                    text: groupMessageText
                ),
            ]
        )
    }

    private struct EphemeralPeer {
        let accountId: UUID
        let profileName: String
        let messenger: TrixMessengerClient
    }

    private static func makeEphemeralPeerDevice(
        label: String,
        baseURLString: String,
        client: TrixAPIClient
    ) async throws -> EphemeralPeer {
        let suffix = uniqueSuffix(length: 8)
        let profileName = "\(label) \(suffix)"
        let handle = makeHandle(prefix: "macpeer", scenarioLabel: label, suffix: suffix)
        let deviceName = "\(label) Device \(suffix)"

        let identity = try DeviceIdentityMaterial.make(
            profileName: profileName,
            handle: handle,
            deviceDisplayName: deviceName,
            platform: DeviceIdentityMaterial.platform
        )

        let created = try await client.createAccount(
            handle: handle,
            profileName: profileName,
            profileBio: "peer fixture",
            deviceDisplayName: deviceName,
            identity: identity
        )

        let auth = try await client.authenticate(deviceId: created.deviceId, identity: identity)

        let paths = try WorkspaceStorePaths.forAccount(created.accountId)
        let messenger = try TrixMessengerClient(
            workspaceRoot: paths.rootURL,
            baseURL: baseURLString,
            accessToken: auth.accessToken,
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: deviceName,
            platform: DeviceIdentityMaterial.platform,
            credentialIdentity: identity.storedIdentity.credentialIdentity,
            accountRootPrivateKey: identity.storedIdentity.accountRootSeed,
            transportPrivateKey: identity.storedIdentity.transportSeed
        )
        _ = try await messenger.loadSnapshot()

        return EphemeralPeer(accountId: created.accountId, profileName: profileName, messenger: messenger)
    }

    private static func waitForConversationParticipants(
        messenger: TrixMessengerClient,
        chatId: UUID,
        timeoutSeconds: TimeInterval = 15
    ) async throws {
        let _: Bool = try await waitForCondition(timeoutSeconds: timeoutSeconds, pollIntervalSeconds: 0.25) {
            _ = try await messenger.getNewEvents(checkpoint: nil)
            let snapshot = try await messenger.loadSnapshot()
            guard let chat = snapshot.conversations.first(where: { $0.chatId == chatId }) else {
                return nil as Bool?
            }
            return chat.participantProfiles.isEmpty ? nil : true
        }
    }

    private static func waitForTextMessage(
        _ text: String,
        messenger: TrixMessengerClient,
        chatId: UUID,
        timeoutSeconds: TimeInterval = 20
    ) async throws {
        let _: Bool = try await waitForCondition(timeoutSeconds: timeoutSeconds, pollIntervalSeconds: 0.25) {
            _ = try await messenger.getNewEvents(checkpoint: nil)
            let messages = try await messenger.getAllMessages(conversationId: chatId, pageLimit: 200)
            let found = messages.contains { $0.body?.text == text }
            return found ? true : nil
        }
    }

    private static func waitForCondition<T>(
        timeoutSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval,
        operation: () async throws -> T?
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: Error?

        while Date() < deadline {
            do {
                if let value = try await operation() {
                    return value
                }
                lastError = nil
            } catch {
                lastError = error
            }

            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }

        throw lastError ?? NSError(
            domain: "MacUITestFixtureSeeder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for seeded UI fixture state."]
        )
    }

    private static func decodeLinkIntentPayload(_ rawValue: String) throws -> LinkIntentPayload {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw TrixAPIError.invalidPayload("Link payload is not valid UTF-8.")
        }
        return try JSONDecoder().decode(LinkIntentPayload.self, from: data)
    }

    private static func makeHandle(scenarioLabel: String, suffix: String) -> String {
        makeHandle(prefix: "macuitest", scenarioLabel: scenarioLabel, suffix: suffix)
    }

    private static func makeHandle(prefix: String, scenarioLabel: String, suffix: String) -> String {
        let normalizedLabel = scenarioLabel
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        let maxPrefixLength = max(0, 32 - prefix.count - suffix.count)
        let labelPart = String(normalizedLabel.prefix(maxPrefixLength))
        return "\(prefix)\(labelPart)\(suffix)"
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
