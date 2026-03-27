import XCTest

@MainActor
final class TrixMacSmokeUITests: XCTestCase {
    private func identifiedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testAppLaunches() {
        let app = TrixMacUITestApp.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    func testCreateAccountFlowShowsWorkspace() async throws {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let app = TrixMacUITestApp.launch(
            resetState: true,
            scenarioLabel: "create-account"
        )

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.onboardingScreen, in: app)
                .waitForExistence(timeout: 15)
        )

        let profileNameField = identifiedElement(TrixMacAccessibilityID.Onboarding.profileNameField, in: app)
        XCTAssertTrue(profileNameField.waitForExistence(timeout: 15))
        profileNameField.click()
        try await Task.sleep(nanoseconds: 350_000_000)
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("UI Smoke Mac Account")

        let deviceNameField = identifiedElement(TrixMacAccessibilityID.Onboarding.deviceNameField, in: app)
        XCTAssertTrue(deviceNameField.waitForExistence(timeout: 5))
        deviceNameField.click()
        try await Task.sleep(nanoseconds: 200_000_000)
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("UI Smoke Mac Device")

        let createAccountButton = identifiedElement(TrixMacAccessibilityID.Onboarding.primaryActionButton, in: app)
        XCTAssertTrue(createAccountButton.waitForExistence(timeout: 10))
        createAccountButton.click()

        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.workspaceScreen, in: app)
                .waitForExistence(timeout: 40)
        )
    }

    func testPendingApprovalSeedShowsWaitingPanel() async throws {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let app = TrixMacUITestApp.launch(
            resetState: true,
            seedScenario: .pendingApproval,
            scenarioLabel: "pending-approval"
        )

        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.pendingApprovalScreen, in: app)
                .waitForExistence(timeout: 25)
        )

        XCTAssertTrue(
            app.staticTexts.matching(identifier: TrixMacAccessibilityID.Onboarding.pendingDeviceIDValue)
                .firstMatch
                .waitForExistence(timeout: 10)
        )

        let reconnect = identifiedElement(TrixMacAccessibilityID.Onboarding.reconnectAfterApprovalButton, in: app)
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(reconnect.isHittable)
    }

    func testRestoreSeedLaunchesWorkspace() async throws {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let app = TrixMacUITestApp.launch(
            resetState: true,
            seedScenario: .restoreSession,
            scenarioLabel: "restore-session"
        )

        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.restoreSessionScreen, in: app)
                .waitForExistence(timeout: 25)
        )

        let reconnect = identifiedElement(TrixMacAccessibilityID.Restore.reconnectButton, in: app)
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        XCTAssertTrue(reconnect.isHittable)
        reconnect.click()

        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.workspaceScreen, in: app)
                .waitForExistence(timeout: 25)
        )
    }
}
