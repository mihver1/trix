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

    func testApprovedAccountSeedLaunchesWorkspace() async throws {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let app = TrixMacUITestApp.launch(
            resetState: true,
            seedScenario: .approvedAccount,
            scenarioLabel: "approved-account"
        )

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.workspaceScreen, in: app)
                .waitForExistence(timeout: 25)
        )
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

    func testDmAndGroupConversationSeedShowsFixtureChatRowsAndTimelineMessages() async throws {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let app = TrixMacUITestApp.launch(
            resetState: true,
            seedScenario: .approvedAccount,
            conversationScenario: .dmAndGroup,
            scenarioLabel: "dm-group-proof"
        )

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(
            identifiedElement(TrixMacAccessibilityID.Root.workspaceScreen, in: app)
                .waitForExistence(timeout: 60)
        )

        let chatList = identifiedElement(TrixMacAccessibilityID.Workspace.chatList, in: app)
        XCTAssertTrue(chatList.waitForExistence(timeout: 15))

        let dmRow = identifiedElement(TrixMacAccessibilityID.Fixture.chatRow(.dm), in: app)
        let groupRow = identifiedElement(TrixMacAccessibilityID.Fixture.chatRow(.group), in: app)
        XCTAssertTrue(dmRow.waitForExistence(timeout: 45), "Expected seeded DM chat row")
        XCTAssertTrue(groupRow.waitForExistence(timeout: 10), "Expected seeded group chat row")

        dmRow.click()
        try await Task.sleep(nanoseconds: 400_000_000)

        let dmSeedMessage = identifiedElement(TrixMacAccessibilityID.Fixture.timelineMessage(.dmSeed), in: app)
        XCTAssertTrue(dmSeedMessage.waitForExistence(timeout: 30), "Expected DM seed message in timeline")

        let dmSeedText = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "UI DM Seed")).firstMatch
        XCTAssertTrue(dmSeedText.waitForExistence(timeout: 5))

        groupRow.click()
        try await Task.sleep(nanoseconds: 400_000_000)

        let groupSeedMessage = identifiedElement(TrixMacAccessibilityID.Fixture.timelineMessage(.groupSeed), in: app)
        XCTAssertTrue(groupSeedMessage.waitForExistence(timeout: 30), "Expected group seed message in timeline")

        let groupSeedText = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "UI Group Seed")).firstMatch
        XCTAssertTrue(groupSeedText.waitForExistence(timeout: 5))
    }
}
