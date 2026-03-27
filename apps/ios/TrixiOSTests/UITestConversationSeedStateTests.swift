import XCTest
@testable import Trix

@MainActor
final class UITestConversationSeedStateTests: XCTestCase {
    func testUITestBootstrapConversationScenarioSeedsDMAndGroupChats() async throws {
        let baseURL = UITestServerHarness.configuredBaseURL()
        try await UITestServerHarness.skipUnlessServerReachable(at: baseURL)
        UITestServerHarness.resetLocalAppState()
        defer { UITestServerHarness.resetLocalAppState() }

        let configuration = UITestLaunchConfiguration.make(
            arguments: [
                TrixUITestLaunchArgument.enableUITesting,
                TrixUITestLaunchArgument.resetState,
                TrixUITestLaunchArgument.disableAnimations,
            ],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: baseURL,
                TrixUITestLaunchEnvironment.seedScenario: TrixUITestSeedScenario.approvedAccount.rawValue,
                TrixUITestLaunchEnvironment.conversationScenario: TrixUITestConversationScenario.dmAndGroup.rawValue,
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

    func testUITestBootstrapPreservesConversationManifestAcrossNonResetRelaunch() async throws {
        let baseURL = UITestServerHarness.configuredBaseURL()
        try await UITestServerHarness.skipUnlessServerReachable(at: baseURL)
        UITestServerHarness.resetLocalAppState()
        defer { UITestServerHarness.resetLocalAppState() }

        let seededState = try await UITestFixtureSeeder.seedLaunchState(
            seedScenario: .approvedAccount,
            conversationScenario: .dmAndGroup,
            baseURLString: baseURL,
            scenarioLabel: "conversation-restore-relaunch"
        )
        let manifest = try XCTUnwrap(seededState.fixtureManifest)
        try LocalDeviceIdentityStore().save(seededState.identity)
        try UITestFixtureManifestStore.save(manifest)

        let configuration = UITestLaunchConfiguration.make(
            arguments: [TrixUITestLaunchArgument.enableUITesting],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: baseURL,
                TrixUITestLaunchEnvironment.scenarioLabel: "conversation-restore-relaunch",
            ]
        )

        let resolvedBaseURL = try await UITestAppBootstrap.prepareForLaunch(
            fallbackBaseURLString: "http://127.0.0.1:8080",
            configuration: configuration
        )
        XCTAssertEqual(resolvedBaseURL, baseURL)

        let restoredManifest = try XCTUnwrap(UITestFixtureManifestStore.load())
        XCTAssertEqual(restoredManifest, manifest)
    }

    func testSeededDMPostDebugMessageAppearsInConversationSnapshot() async throws {
        let baseURL = UITestServerHarness.configuredBaseURL()
        try await UITestServerHarness.skipUnlessServerReachable(at: baseURL)
        UITestServerHarness.resetLocalAppState()
        defer { UITestServerHarness.resetLocalAppState() }

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
}
