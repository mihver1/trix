import XCTest
@testable import Trix

final class UITestLaunchConfigurationTests: XCTestCase {
    func testMakeParsesArgumentsAndEnvironment() {
        let configuration = UITestLaunchConfiguration.make(
            arguments: [
                TrixUITestLaunchArgument.enableUITesting,
                TrixUITestLaunchArgument.resetState,
                TrixUITestLaunchArgument.disableAnimations,
            ],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: "http://localhost:9191",
                TrixUITestLaunchEnvironment.seedScenario: TrixUITestSeedScenario.pendingApproval.rawValue,
                TrixUITestLaunchEnvironment.scenarioLabel: "pending-approval-smoke",
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertTrue(configuration.resetLocalState)
        XCTAssertTrue(configuration.disableAnimations)
        XCTAssertEqual(configuration.baseURLOverride, "http://localhost:9191")
        XCTAssertEqual(configuration.seedScenario, .pendingApproval)
        XCTAssertEqual(configuration.scenarioLabel, "pending-approval-smoke")
    }

    func testMakeParsesConversationScenarioEnvironment() {
        let configuration = UITestLaunchConfiguration.make(
            arguments: [TrixUITestLaunchArgument.enableUITesting],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: "http://localhost:9191",
                "TRIX_UI_TEST_CONVERSATION_SCENARIO": "dm-and-group",
            ]
        )

        let conversationScenario = Mirror(reflecting: configuration)
            .children
            .first { $0.label == "conversationScenario" }?
            .value

        guard let conversationScenario else {
            return XCTFail("Expected conversationScenario to be parsed from environment.")
        }

        XCTAssertTrue(String(describing: conversationScenario).contains("dmAndGroup"))
    }

    func testMakeParsesRequestedInterfaceStyle() {
        let configuration = UITestLaunchConfiguration.make(
            arguments: [TrixUITestLaunchArgument.enableUITesting],
            environment: [
                TrixUITestLaunchEnvironment.interfaceStyle: "dark",
            ]
        )

        XCTAssertEqual(configuration.interfaceStyle, .dark)
    }

    func testMakeDefaultsToDisabledWithoutFlag() {
        let configuration = UITestLaunchConfiguration.make(arguments: [], environment: [:])

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.resetLocalState)
        XCTAssertFalse(configuration.disableAnimations)
        XCTAssertNil(configuration.baseURLOverride)
        XCTAssertNil(configuration.seedScenario)
        XCTAssertNil(configuration.scenarioLabel)
        XCTAssertNil(configuration.interfaceStyle)
    }
}

@MainActor
final class AuthSessionResolutionGateTests: XCTestCase {
    func testConcurrentResolveCallsShareSingleAuthenticationTask() async throws {
        let gate = AuthSessionResolutionGate()
        let counter = AuthCallCounter()
        let identity = LocalDeviceIdentity(
            accountId: "account-1",
            deviceId: "device-1",
            accountSyncChatId: nil,
            deviceDisplayName: "iPhone",
            platform: "ios",
            credentialIdentity: Data([0x01, 0x02, 0x03]),
            accountRootPrivateKeyRaw: Data([0x04]),
            transportPrivateKeyRaw: Data([0x05]),
            trustState: .active,
            capabilityState: .fullAccountAccess
        )
        let session = AuthSessionResponse(
            accessToken: "access-token",
            expiresAtUnix: UInt64(Date().timeIntervalSince1970) + 3_600,
            accountId: identity.accountId,
            deviceStatus: .active
        )

        async let first = gate.resolve(
            identity: identity,
            baseURLString: "http://127.0.0.1:8080",
            existingSession: nil,
            leewaySeconds: 60
        ) {
            counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return session
        }

        async let second = gate.resolve(
            identity: identity,
            baseURLString: "http://127.0.0.1:8080",
            existingSession: nil,
            leewaySeconds: 60
        ) {
            counter.increment()
            return session
        }

        let firstSession = try await first
        let secondSession = try await second

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(
            [firstSession.accessToken, secondSession.accessToken],
            ["access-token", "access-token"]
        )
    }
}

@MainActor
private final class AuthCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
