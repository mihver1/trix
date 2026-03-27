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

    func testMakeDefaultsToDisabledWithoutFlag() {
        let configuration = UITestLaunchConfiguration.make(arguments: [], environment: [:])

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(configuration.resetLocalState)
        XCTAssertFalse(configuration.disableAnimations)
        XCTAssertNil(configuration.baseURLOverride)
        XCTAssertNil(configuration.seedScenario)
        XCTAssertNil(configuration.scenarioLabel)
    }
}
