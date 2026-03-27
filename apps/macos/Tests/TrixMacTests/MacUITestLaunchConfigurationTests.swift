import XCTest
@testable import TrixMac

final class MacUITestLaunchConfigurationTests: XCTestCase {
    func testMakeParsesArgumentsAndEnvironment() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [
                MacUITestLaunchArgument.enableUITesting,
                MacUITestLaunchArgument.resetState,
            ],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://localhost:9191",
                MacUITestLaunchEnvironment.seedScenario: MacUITestSeedScenario.pendingApproval.rawValue,
                MacUITestLaunchEnvironment.scenarioLabel: "pending-approval-smoke",
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertTrue(configuration.resetLocalState)
        XCTAssertEqual(configuration.baseURLOverride, "http://localhost:9191")
        XCTAssertEqual(configuration.seedScenario, .pendingApproval)
        XCTAssertEqual(configuration.scenarioLabel, "pending-approval-smoke")
    }

    func testMakeParsesConversationScenarioDmAndGroup() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://localhost:9191",
                MacUITestLaunchEnvironment.conversationScenario: MacUITestConversationScenario.dmAndGroup.rawValue,
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.conversationScenario, .dmAndGroup)
    }

    func testMakeIgnoresEnvironmentWhenUITestingDisabled() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://localhost:9191",
                MacUITestLaunchEnvironment.seedScenario: MacUITestSeedScenario.approvedAccount.rawValue,
                MacUITestLaunchEnvironment.conversationScenario: MacUITestConversationScenario.dmAndGroup.rawValue,
                MacUITestLaunchEnvironment.scenarioLabel: "should-not-apply",
            ]
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.resetLocalState)
        XCTAssertNil(configuration.baseURLOverride)
        XCTAssertNil(configuration.seedScenario)
        XCTAssertNil(configuration.conversationScenario)
        XCTAssertNil(configuration.scenarioLabel)
    }

    func testMakeDoesNotSetResetWhenOnlyResetArgumentWithoutUITesting() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.resetState],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://localhost:9191",
            ]
        )

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.resetLocalState)
        XCTAssertNil(configuration.baseURLOverride)
    }

    func testMakeTrimsBaseURLWhitespace() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "  \nhttp://localhost:9191\t  ",
            ]
        )

        XCTAssertEqual(configuration.baseURLOverride, "http://localhost:9191")
    }

    func testMakeWhitespaceOnlyEnvironmentValuesNormalizeToNil() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "   ",
                MacUITestLaunchEnvironment.seedScenario: "\t\n",
                MacUITestLaunchEnvironment.conversationScenario: "",
                MacUITestLaunchEnvironment.scenarioLabel: "  ",
            ]
        )

        XCTAssertNil(configuration.baseURLOverride)
        XCTAssertNil(configuration.seedScenario)
        XCTAssertNil(configuration.conversationScenario)
        XCTAssertNil(configuration.scenarioLabel)
    }

    func testMakeInvalidSeedScenarioRawValueYieldsNil() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.seedScenario: "not-a-valid-seed-scenario",
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertNil(configuration.seedScenario)
    }

    func testMakeInvalidConversationScenarioRawValueYieldsNil() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.conversationScenario: "unknown-conversation",
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertNil(configuration.conversationScenario)
    }
}
