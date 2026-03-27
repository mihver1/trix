import XCTest
@testable import Trix

@MainActor
final class UITestConversationSeedStateTests: XCTestCase {
    func testUITestBootstrapConversationScenarioSeedsDMAndGroupChats() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)
        resetLocalAppState()
        defer { resetLocalAppState() }

        let configuration = UITestLaunchConfiguration.make(
            arguments: [
                TrixUITestLaunchArgument.enableUITesting,
                TrixUITestLaunchArgument.resetState,
            ],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: baseURL,
                TrixUITestLaunchEnvironment.seedScenario: TrixUITestSeedScenario.approvedAccount.rawValue,
                "TRIX_UI_TEST_CONVERSATION_SCENARIO": "dm-and-group",
                TrixUITestLaunchEnvironment.scenarioLabel: "conversation-bundle",
            ]
        )

        let resolvedBaseURL = try await UITestAppBootstrap.prepareForLaunch(
            fallbackBaseURLString: "http://127.0.0.1:8080",
            configuration: configuration
        )
        XCTAssertEqual(resolvedBaseURL, baseURL)

        let model = AppModel()
        await model.start(baseURLString: resolvedBaseURL)

        let dashboard = try XCTUnwrap(model.dashboard)
        XCTAssertEqual(dashboard.chats.count, 2)
        XCTAssertEqual(
            Set(dashboard.chats.map(\.chatType)),
            Set([.dm, .group])
        )
    }

    func testSeededDMPostDebugMessageAppearsInConversationSnapshot() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)
        resetLocalAppState()
        defer { resetLocalAppState() }

        let seededState = try await UITestFixtureSeeder.seedLaunchState(
            seedScenario: .approvedAccount,
            conversationScenario: .dmAndGroup,
            baseURLString: baseURL,
            scenarioLabel: "conversation-send-debug"
        )
        let fixtureManifest = try XCTUnwrap(seededState.fixtureManifest)
        let dmChat = try XCTUnwrap(fixtureManifest.chatRecord(for: .dm))
        let seededDMMessage = try XCTUnwrap(fixtureManifest.messageRecord(for: .dmSeed))

        try LocalDeviceIdentityStore().save(seededState.identity)

        let model = AppModel()
        await model.start(baseURLString: baseURL)

        let initialSnapshot = try await model.fetchConversationSnapshot(
            baseURLString: baseURL,
            chatId: dmChat.chatId
        )
        XCTAssertTrue(
            initialSnapshot.messages.contains { $0.body?.text == seededDMMessage.text }
        )

        let outgoingText = "unit-send-\(UUID().uuidString.prefix(6).lowercased())"
        let response = await model.postDebugMessage(
            baseURLString: baseURL,
            chatId: dmChat.chatId,
            draft: DebugMessageDraft(kind: .text, text: outgoingText)
        )
        XCTAssertNotNil(response)

        let updatedSnapshot = try await model.fetchConversationSnapshot(
            baseURLString: baseURL,
            chatId: dmChat.chatId
        )
        XCTAssertTrue(
            updatedSnapshot.messages.contains { $0.body?.text == outgoingText }
        )
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
                    "Conversation seed state test skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "Conversation seed state test skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
    }

    private func resetLocalAppState() {
        if let identity = try? LocalDeviceIdentityStore().load() {
            try? TrixCorePersistentBridge.deletePersistentState(identity: identity)
        }
        try? LocalDeviceIdentityStore().delete()

        guard let appSupportRoot = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        let trixDirectory = appSupportRoot.appendingPathComponent("TrixiOS", isDirectory: true)
        try? FileManager.default.removeItem(
            at: trixDirectory.appendingPathComponent("CoreState", isDirectory: true)
        )
        try? FileManager.default.removeItem(
            at: trixDirectory.appendingPathComponent("SimulatorKeychainFallback", isDirectory: true)
        )
    }
}
