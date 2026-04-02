import XCTest
@testable import Trix

@MainActor
final class ServerBackedSmokeTests: XCTestCase {
    private final class ScenarioDevice {
        let baseURL: String
        let label: String
        var identity: LocalDeviceIdentity

        private var session: AuthSessionResponse?
        private var eventCheckpoint: String?

        init(
            baseURL: String,
            label: String,
            identity: LocalDeviceIdentity,
            session: AuthSessionResponse? = nil
        ) {
            self.baseURL = baseURL
            self.label = label
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
            eventCheckpoint = snapshot.checkpoint
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
            do {
                let batch = try RealtimeWebSocketClient.pollNewEvents(
                    baseURLString: baseURL,
                    accessToken: try authenticate().accessToken,
                    identity: identity,
                    checkpoint: eventCheckpoint
                )
                eventCheckpoint = batch.checkpoint ?? eventCheckpoint
                return batch
            } catch let error as FfiMessengerError {
                guard case .RequiresResync = error else {
                    throw error
                }
                _ = try loadSnapshot()
                let batch = try RealtimeWebSocketClient.pollNewEvents(
                    baseURLString: baseURL,
                    accessToken: try authenticate().accessToken,
                    identity: identity,
                    checkpoint: eventCheckpoint
                )
                eventCheckpoint = batch.checkpoint ?? eventCheckpoint
                return batch
            }
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

        func getServerChatDetail(chatId: String) throws -> ChatDetailResponse {
            try TrixCoreServerBridge.getChatDetail(
                baseURLString: baseURL,
                accessToken: try authenticate().accessToken,
                chatId: chatId
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

    private func configuredBaseURL() -> String {
        ProcessInfo.processInfo.environment["TRIX_IOS_SERVER_SMOKE_BASE_URL"]?
            .trix_trimmedOrNil() ?? "http://localhost:8080"
    }

    private func skipUnlessServerReachable(at baseURL: String) async throws {
        let healthURL = try XCTUnwrap(URL(string: "\(baseURL)/v0/system/health"))

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw XCTSkip(
                    "Server-backed iOS smoke skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "Server-backed iOS smoke skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
    }

    private func uniqueSuffix(length: Int = 12) -> String {
        String(
            UUID().uuidString
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .prefix(length)
        )
    }

    private func makeAccountForm(label: String, suffix: String) -> CreateAccountForm {
        let handlePrefix = label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        var form = CreateAccountForm()
        form.profileName = "\(label) \(suffix)"
        form.handle = "ios\(handlePrefix)\(suffix)"
        form.profileBio = "Server-backed iOS scenario for \(label)"
        form.deviceDisplayName = "\(label) Device \(suffix)"
        return form
    }

    private func makeLinkForm(label: String) -> LinkExistingAccountForm {
        var form = LinkExistingAccountForm()
        form.deviceDisplayName = label
        return form
    }

    private func createScenarioDevice(
        baseURL: String,
        label: String
    ) throws -> ScenarioDevice {
        let form = makeAccountForm(label: label, suffix: uniqueSuffix(length: 8))
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
        let device = ScenarioDevice(
            baseURL: baseURL,
            label: label,
            identity: identity
        )
        _ = try device.loadSnapshot(forceRefreshSession: true)
        return device
    }

    private func createApprovedLinkedDevice(
        trustedOwner: ScenarioDevice,
        label: String
    ) throws -> ScenarioDevice {
        let linkIntent = try trustedOwner.createLinkIntent()
        let payload = try LinkIntentPayload.parse(linkIntent.qrPayload)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let linkedIdentity = try TrixCorePersistentBridge.completeLinkDevice(
            payload: payload,
            form: makeLinkForm(label: label),
            bootstrapMaterial: bootstrapMaterial
        )
        let linkedDevice = ScenarioDevice(
            baseURL: payload.baseURL,
            label: label,
            identity: linkedIdentity
        )

        let approval = try trustedOwner.approveLinkedDevice(deviceId: linkedIdentity.deviceId)
        XCTAssertEqual(approval.deviceStatus, .active)

        _ = try linkedDevice.authenticate(forceRefresh: true)
        _ = try linkedDevice.loadSnapshot(forceRefreshSession: true)
        return linkedDevice
    }

    private func waitForCondition<T>(
        description: String,
        timeoutSeconds: TimeInterval = 10,
        pollIntervalSeconds: TimeInterval = 0.25,
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

        let message: String
        if let lastError {
            message = "\(description) timed out: \(lastError.localizedDescription)"
        } else {
            message = "\(description) timed out."
        }
        XCTFail(message)
        throw NSError(
            domain: "ServerBackedSmokeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func waitForConversation(
        on device: ScenarioDevice,
        chatId: String
    ) async throws -> SafeConversationSnapshot {
        try await waitForCondition(
            description: "Conversation \(chatId) on \(device.label)"
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

    private func waitForServerChatDetail(
        on device: ScenarioDevice,
        chatId: String,
        minimumDeviceCount: Int
    ) async throws -> ChatDetailResponse {
        try await waitForCondition(
            description: "Server chat detail \(chatId) on \(device.label)"
        ) {
            let detail = try device.getServerChatDetail(chatId: chatId)
            guard detail.deviceMembers.count >= minimumDeviceCount else {
                return nil
            }
            return detail
        }
    }

    private func waitForTextMessage(
        _ text: String,
        on device: ScenarioDevice,
        chatId: String
    ) async throws -> SafeMessengerMessage {
        try await waitForCondition(
            description: "Message '\(text)' on \(device.label)"
        ) {
            let batch: SafeMessengerEventBatch
            do {
                batch = try device.pollEvents()
            } catch {
                throw NSError(
                    domain: "ServerBackedSmokeTests",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "pollEvents failed on \(device.label): \(error.localizedDescription)"
                    ]
                )
            }
            if !batch.events.isEmpty {
                do {
                    _ = try device.loadSnapshot()
                } catch {
                    throw NSError(
                        domain: "ServerBackedSmokeTests",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey: "loadSnapshot failed on \(device.label): \(error.localizedDescription)"
                        ]
                    )
                }
            }
            let snapshot: SafeConversationSnapshot
            do {
                snapshot = try device.loadConversation(chatId: chatId)
            } catch {
                throw NSError(
                    domain: "ServerBackedSmokeTests",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "loadConversation(\(chatId)) failed on \(device.label): \(error.localizedDescription)"
                    ]
                )
            }
            return snapshot.messages.first { $0.body?.text == text }
        }
    }

    private func cleanupPersistentState(for devices: [ScenarioDevice]) {
        var seen = Set<String>()
        for device in devices {
            let key = "\(device.identity.accountId):\(device.identity.deviceId)"
            guard seen.insert(key).inserted else {
                continue
            }
            try? TrixCorePersistentBridge.deletePersistentState(identity: device.identity)
        }
    }

    func testAccountBootstrapAuthenticateAndCreateLinkIntentAgainstServer() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)
        let suffix = uniqueSuffix()

        let snapshot = try await TrixCoreServerBridge.fetchSystemSnapshot(baseURLString: baseURL)
        XCTAssertEqual(snapshot.health.status, .ok)
        XCTAssertFalse(snapshot.health.version.isEmpty)
        XCTAssertFalse(snapshot.version.version.isEmpty)

        let form = makeAccountForm(label: "iOS Smoke", suffix: suffix)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let created = try TrixCoreServerBridge.createAccount(
            baseURLString: baseURL,
            form: form,
            bootstrapMaterial: bootstrapMaterial
        )

        XCTAssertFalse(created.accountId.isEmpty)
        XCTAssertFalse(created.deviceId.isEmpty)
        XCTAssertFalse(created.accountSyncChatId.isEmpty)

        let identity = bootstrapMaterial.makeLocalIdentity(
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: form.deviceDisplayName,
            platform: form.platform
        )
        let session = try TrixCoreServerBridge.authenticate(
            baseURLString: baseURL,
            identity: identity
        )

        XCTAssertEqual(session.accountId, created.accountId)
        XCTAssertEqual(session.deviceStatus, .active)
        XCTAssertFalse(session.accessToken.isEmpty)
        XCTAssertGreaterThan(session.expiresAtUnix, 0)

        let profile = try await TrixCoreServerBridge.getAccountProfile(
            baseURLString: baseURL,
            accessToken: session.accessToken
        )
        XCTAssertEqual(profile.accountId, created.accountId)
        XCTAssertEqual(profile.deviceId, created.deviceId)
        XCTAssertEqual(profile.deviceStatus, .active)
        XCTAssertEqual(profile.profileName, form.profileName.trix_trimmed())
        XCTAssertEqual(profile.handle, form.handle.trix_trimmedOrNil())

        let devices = try await TrixCoreServerBridge.listDevices(
            baseURLString: baseURL,
            accessToken: session.accessToken
        )
        XCTAssertEqual(devices.accountId, created.accountId)

        let currentDevice = try XCTUnwrap(
            devices.devices.first { $0.deviceId == created.deviceId }
        )
        XCTAssertEqual(currentDevice.platform, form.platform)
        XCTAssertEqual(currentDevice.deviceStatus, .active)

        let linkIntent = try TrixCoreServerBridge.createLinkIntent(
            baseURLString: baseURL,
            accessToken: session.accessToken
        )
        XCTAssertFalse(linkIntent.linkIntentId.isEmpty)
        XCTAssertFalse(linkIntent.qrPayload.isEmpty)
        XCTAssertGreaterThan(linkIntent.expiresAtUnix, 0)

        let payload = try LinkIntentPayload.parse(linkIntent.qrPayload)
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.accountId, created.accountId)
        XCTAssertEqual(payload.linkIntentId, linkIntent.linkIntentId)
        XCTAssertFalse(payload.baseURL.isEmpty)
        XCTAssertFalse(payload.linkToken.isEmpty)
    }

    func testTwoUsersCanCreateDMAndExchangeMessagesAgainstServer() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)

        var devicesToCleanup: [ScenarioDevice] = []
        defer { cleanupPersistentState(for: devicesToCleanup) }

        let alice = try createScenarioDevice(baseURL: baseURL, label: "Alice Scenario")
        devicesToCleanup.append(alice)
        let bob = try createScenarioDevice(baseURL: baseURL, label: "Bob Scenario")
        devicesToCleanup.append(bob)

        let created = try alice.createDM(peerAccountId: bob.identity.accountId)
        XCTAssertEqual(created.chatType, .dm)

        let bobConversation = try await waitForConversation(on: bob, chatId: created.chatId)
        XCTAssertEqual(bobConversation.detail.chatType, .dm)
        XCTAssertTrue(
            bobConversation.detail.participantProfiles.contains {
                $0.accountId == alice.identity.accountId
            }
        )

        let firstText = "alice-to-bob-\(uniqueSuffix(length: 6))"
        _ = try alice.sendText(chatId: created.chatId, text: firstText)

        let bobFirstMessage = try await waitForTextMessage(
            firstText,
            on: bob,
            chatId: created.chatId
        )
        XCTAssertEqual(bobFirstMessage.senderAccountId, alice.identity.accountId)
        XCTAssertEqual(bobFirstMessage.senderDeviceId, alice.identity.deviceId)
        XCTAssertEqual(bobFirstMessage.body?.kind, .text)

        let replyText = "bob-to-alice-\(uniqueSuffix(length: 6))"
        _ = try bob.sendText(chatId: created.chatId, text: replyText)

        let aliceReplyMessage = try await waitForTextMessage(
            replyText,
            on: alice,
            chatId: created.chatId
        )
        XCTAssertEqual(aliceReplyMessage.senderAccountId, bob.identity.accountId)
        XCTAssertEqual(aliceReplyMessage.senderDeviceId, bob.identity.deviceId)
        XCTAssertEqual(aliceReplyMessage.body?.text, replyText)
    }

    func testLinkedDeviceParticipatesInFreshDMCrossDeviceMessaging() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)

        var devicesToCleanup: [ScenarioDevice] = []
        defer { cleanupPersistentState(for: devicesToCleanup) }

        let alicePrimary = try createScenarioDevice(baseURL: baseURL, label: "Alice Primary")
        devicesToCleanup.append(alicePrimary)
        let bob = try createScenarioDevice(baseURL: baseURL, label: "Bob Primary")
        devicesToCleanup.append(bob)
        let aliceLinked = try createApprovedLinkedDevice(
            trustedOwner: alicePrimary,
            label: "Alice Linked Device"
        )
        devicesToCleanup.append(aliceLinked)

        let created = try alicePrimary.createDM(peerAccountId: bob.identity.accountId)
        XCTAssertEqual(created.chatType, .dm)

        let linkedConversation = try await waitForConversation(
            on: aliceLinked,
            chatId: created.chatId
        )
        XCTAssertEqual(linkedConversation.detail.chatType, .dm)
        XCTAssertTrue(
            linkedConversation.detail.participantProfiles.contains {
                $0.accountId == bob.identity.accountId
            }
        )

        let serverConversation = try await waitForServerChatDetail(
            on: alicePrimary,
            chatId: created.chatId,
            minimumDeviceCount: 3
        )
        let linkedDeviceIDs = Set(serverConversation.deviceMembers.map(\.deviceId))
        XCTAssertTrue(linkedDeviceIDs.contains(alicePrimary.identity.deviceId))
        XCTAssertTrue(linkedDeviceIDs.contains(aliceLinked.identity.deviceId))
        XCTAssertTrue(linkedDeviceIDs.contains(bob.identity.deviceId))

        let primaryText = "primary-to-linked-\(uniqueSuffix(length: 6))"
        _ = try alicePrimary.sendText(chatId: created.chatId, text: primaryText)

        let bobSawPrimary = try await waitForTextMessage(
            primaryText,
            on: bob,
            chatId: created.chatId
        )
        XCTAssertEqual(bobSawPrimary.senderDeviceId, alicePrimary.identity.deviceId)

        let linkedSawPrimary = try await waitForTextMessage(
            primaryText,
            on: aliceLinked,
            chatId: created.chatId
        )
        XCTAssertEqual(linkedSawPrimary.senderDeviceId, alicePrimary.identity.deviceId)

        let linkedReplyText = "linked-to-primary-\(uniqueSuffix(length: 6))"
        _ = try aliceLinked.sendText(chatId: created.chatId, text: linkedReplyText)

        let primarySawLinked = try await waitForTextMessage(
            linkedReplyText,
            on: alicePrimary,
            chatId: created.chatId
        )
        XCTAssertEqual(primarySawLinked.senderAccountId, alicePrimary.identity.accountId)
        XCTAssertEqual(primarySawLinked.senderDeviceId, aliceLinked.identity.deviceId)

        let bobSawLinked = try await waitForTextMessage(
            linkedReplyText,
            on: bob,
            chatId: created.chatId
        )
        XCTAssertEqual(bobSawLinked.senderDeviceId, aliceLinked.identity.deviceId)

        let bobReplyText = "bob-to-both-\(uniqueSuffix(length: 6))"
        _ = try bob.sendText(chatId: created.chatId, text: bobReplyText)

        let alicePrimarySawBob = try await waitForTextMessage(
            bobReplyText,
            on: alicePrimary,
            chatId: created.chatId
        )
        XCTAssertEqual(alicePrimarySawBob.senderDeviceId, bob.identity.deviceId)

        let aliceLinkedSawBob = try await waitForTextMessage(
            bobReplyText,
            on: aliceLinked,
            chatId: created.chatId
        )
        XCTAssertEqual(aliceLinkedSawBob.senderDeviceId, bob.identity.deviceId)
    }

    func testThreeUsersCanCreateGroupAndExchangeMessagesAgainstServer() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)

        var devicesToCleanup: [ScenarioDevice] = []
        defer { cleanupPersistentState(for: devicesToCleanup) }

        let alice = try createScenarioDevice(baseURL: baseURL, label: "Alice Group Owner")
        devicesToCleanup.append(alice)
        let bob = try createScenarioDevice(baseURL: baseURL, label: "Bob Group Member")
        devicesToCleanup.append(bob)
        let charlie = try createScenarioDevice(baseURL: baseURL, label: "Charlie Group Member")
        devicesToCleanup.append(charlie)

        let groupTitle = "iOS Group \(uniqueSuffix(length: 6))"
        let created = try alice.createGroup(
            title: groupTitle,
            participantAccountIds: [bob.identity.accountId, charlie.identity.accountId]
        )
        XCTAssertEqual(created.chatType, .group)

        let bobConversation = try await waitForConversation(on: bob, chatId: created.chatId)
        XCTAssertEqual(bobConversation.detail.chatType, .group)
        XCTAssertEqual(bobConversation.detail.title, groupTitle)
        XCTAssertEqual(
            Set(bobConversation.detail.participantProfiles.map(\.accountId)),
            Set([alice.identity.accountId, bob.identity.accountId, charlie.identity.accountId])
        )

        let charlieConversation = try await waitForConversation(
            on: charlie,
            chatId: created.chatId
        )
        XCTAssertEqual(charlieConversation.detail.chatType, .group)
        XCTAssertEqual(charlieConversation.detail.title, groupTitle)

        let serverConversation = try await waitForServerChatDetail(
            on: alice,
            chatId: created.chatId,
            minimumDeviceCount: 3
        )
        XCTAssertEqual(serverConversation.chatType, .group)
        XCTAssertEqual(serverConversation.title, groupTitle)
        XCTAssertEqual(
            Set(serverConversation.members.map(\.accountId)),
            Set([alice.identity.accountId, bob.identity.accountId, charlie.identity.accountId])
        )

        let aliceText = "alice-group-\(uniqueSuffix(length: 6))"
        _ = try alice.sendText(chatId: created.chatId, text: aliceText)

        let bobSawAlice = try await waitForTextMessage(
            aliceText,
            on: bob,
            chatId: created.chatId
        )
        XCTAssertEqual(bobSawAlice.senderDeviceId, alice.identity.deviceId)

        let charlieSawAlice = try await waitForTextMessage(
            aliceText,
            on: charlie,
            chatId: created.chatId
        )
        XCTAssertEqual(charlieSawAlice.senderDeviceId, alice.identity.deviceId)

        let charlieText = "charlie-group-\(uniqueSuffix(length: 6))"
        _ = try charlie.sendText(chatId: created.chatId, text: charlieText)

        let aliceSawCharlie = try await waitForTextMessage(
            charlieText,
            on: alice,
            chatId: created.chatId
        )
        XCTAssertEqual(aliceSawCharlie.senderDeviceId, charlie.identity.deviceId)

        let bobSawCharlie = try await waitForTextMessage(
            charlieText,
            on: bob,
            chatId: created.chatId
        )
        XCTAssertEqual(bobSawCharlie.senderDeviceId, charlie.identity.deviceId)
    }

    func testLoadConversationReturnsLatestMessagesUpToRequestedLimitAgainstServer() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)

        var devicesToCleanup: [ScenarioDevice] = []
        defer { cleanupPersistentState(for: devicesToCleanup) }

        let alice = try createScenarioDevice(baseURL: baseURL, label: "Alice Limit")
        devicesToCleanup.append(alice)
        let bob = try createScenarioDevice(baseURL: baseURL, label: "Bob Limit")
        devicesToCleanup.append(bob)

        let created = try alice.createDM(peerAccountId: bob.identity.accountId)
        let messageTexts = [
            "limit-message-\(uniqueSuffix(length: 6))-1",
            "limit-message-\(uniqueSuffix(length: 6))-2",
            "limit-message-\(uniqueSuffix(length: 6))-3",
        ]

        for text in messageTexts {
            _ = try alice.sendText(chatId: created.chatId, text: text)
        }

        _ = try await waitForTextMessage(
            messageTexts[2],
            on: bob,
            chatId: created.chatId
        )

        let limitedConversation = try bob.loadConversation(
            chatId: created.chatId,
            limit: 2
        )
        let limitedTexts = limitedConversation.messages.compactMap(\.body?.text)

        XCTAssertEqual(limitedTexts, Array(messageTexts.suffix(2)))
        XCTAssertEqual(limitedConversation.messages.count, 2)
    }
}
