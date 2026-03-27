import XCTest

@MainActor
final class TrixiOSSmokeUITests: XCTestCase {
    private func identifiedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tapTab(
        identifier: String,
        fallbackIndex: Int,
        in app: XCUIApplication
    ) {
        let identifiedTab = identifiedElement(identifier, in: app)
        if identifiedTab.waitForExistence(timeout: 1) {
            identifiedTab.tap()
            return
        }

        // SwiftUI tab bars on iPhone do not always expose tab item identifiers.
        let fallbackTab = app.tabBars.buttons.element(boundBy: fallbackIndex)
        XCTAssertTrue(fallbackTab.waitForExistence(timeout: 5))
        fallbackTab.tap()
    }

    private func launchSeededConversationBundle(
        scenarioLabel: String
    ) -> XCUIApplication {
        TrixUITestApp.launch(
            resetState: true,
            seedScenario: .approvedAccount,
            conversationScenario: .dmAndGroup,
            scenarioLabel: scenarioLabel
        )
    }

    private func assertDashboardVisible(in app: XCUIApplication) {
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Root.dashboardScreen, in: app)
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.chatsList, in: app)
                .waitForExistence(timeout: 20)
        )
    }

    private func tapSeededChatRow(
        _ kind: UITestFixtureChatKind,
        in app: XCUIApplication
    ) {
        let row = identifiedElement(TrixAccessibilityID.Dashboard.chatRow(kind), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
    }

    private func composerInput(in app: XCUIApplication) -> XCUIElement {
        let identifiedComposer = identifiedElement(TrixAccessibilityID.ChatDetail.messageBodyField, in: app)
        if identifiedComposer.waitForExistence(timeout: 1) {
            return identifiedComposer
        }

        // SwiftUI multiline text input does not always surface the explicit identifier.
        let textViewFallback = app.textViews.firstMatch
        if textViewFallback.waitForExistence(timeout: 1) {
            return textViewFallback
        }

        return app.textFields.firstMatch
    }

    private func tapSendButton(in app: XCUIApplication) {
        let identifiedSendButton = identifiedElement(TrixAccessibilityID.ChatDetail.sendButton, in: app)
        if identifiedSendButton.waitForExistence(timeout: 1) {
            identifiedSendButton.tap()
            return
        }

        let composer = composerInput(in: app)
        let composerExists = composer.waitForExistence(timeout: 1)
        let screen = identifiedElement(TrixAccessibilityID.ChatDetail.screen, in: app)
        if composerExists, screen.waitForExistence(timeout: 1) {
            let targetX = min(composer.frame.maxX + 28, screen.frame.maxX - 24)
            let targetY = composer.frame.midY
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: targetX, dy: targetY))
                .tap()
            return
        }

        let fallbackSendButton = app.buttons["arrow.up.circle.fill"]
        XCTAssertTrue(fallbackSendButton.waitForExistence(timeout: 5))
        fallbackSendButton.tap()
    }

    func testCreateAccountFlowShowsDashboard() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = TrixUITestApp.launch(
            resetState: true,
            scenarioLabel: "create-account"
        )

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Root.onboardingScreen, in: app)
                .waitForExistence(timeout: 10)
        )

        let profileNameField = app.textFields[TrixAccessibilityID.Onboarding.profileNameField]
        XCTAssertTrue(profileNameField.waitForExistence(timeout: 5))
        profileNameField.tap()
        profileNameField.typeText("UI Smoke Account")

        let createAccountButton = app.buttons[TrixAccessibilityID.Onboarding.primaryActionButton]
        XCTAssertTrue(createAccountButton.isHittable)
        createAccountButton.tap()

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Root.dashboardScreen, in: app)
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.chatsList, in: app)
                .waitForExistence(timeout: 20)
        )
    }

    func testPendingApprovalSeedShowsApprovalScreen() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = TrixUITestApp.launch(
            resetState: true,
            seedScenario: .pendingApproval,
            scenarioLabel: "pending-approval"
        )

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Root.pendingApprovalScreen, in: app)
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.PendingApproval.checkApprovalButton, in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.PendingApproval.deviceCard, in: app)
                .waitForExistence(timeout: 5)
        )
    }

    func testSeededApprovedAccountSupportsDashboardNavigation() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = TrixUITestApp.launch(
            resetState: true,
            seedScenario: .approvedAccount,
            scenarioLabel: "approved-account"
        )

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Root.dashboardScreen, in: app)
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.chatsList, in: app)
                .waitForExistence(timeout: 20)
        )

        tapTab(
            identifier: TrixAccessibilityID.Dashboard.settingsTab,
            fallbackIndex: 1,
            in: app
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.settingsList, in: app)
                .waitForExistence(timeout: 10)
        )

        tapTab(
            identifier: TrixAccessibilityID.Dashboard.chatsTab,
            fallbackIndex: 0,
            in: app
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.composeButton, in: app)
                .waitForExistence(timeout: 10)
        )
        identifiedElement(TrixAccessibilityID.Dashboard.composeButton, in: app).tap()

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.createChatSheet, in: app)
                .waitForExistence(timeout: 10)
        )
        identifiedElement(TrixAccessibilityID.Dashboard.createChatCancelButton, in: app).tap()
    }

    func testSeededConversationBundleShowsDMAndGroupRows() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = launchSeededConversationBundle(scenarioLabel: "seeded-chat-bundle-list")
        assertDashboardVisible(in: app)

        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.chatRow(.dm), in: app)
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.Dashboard.chatRow(.group), in: app)
                .waitForExistence(timeout: 20)
        )
    }

    func testSeededDMDetailShowsTimelineAndSupportsSendFlow() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = launchSeededConversationBundle(scenarioLabel: "seeded-chat-bundle-dm")
        assertDashboardVisible(in: app)

        tapSeededChatRow(.dm, in: app)

        guard identifiedElement(TrixAccessibilityID.ChatDetail.screen, in: app)
            .waitForExistence(timeout: 20) else {
            return XCTFail("Expected consumer chat detail screen for seeded DM.")
        }
        guard identifiedElement(TrixAccessibilityID.ChatDetail.message(.dmSeed), in: app)
            .waitForExistence(timeout: 10) else {
            return XCTFail("Expected seeded DM message row in consumer timeline.")
        }

        let composer = composerInput(in: app)
        guard composer.waitForExistence(timeout: 10) else {
            return XCTFail("Expected consumer composer text field.")
        }
        composer.tap()

        let outgoingText = "ui-send-\(String(UUID().uuidString.prefix(6)).lowercased())"
        app.typeText(outgoingText)

        tapSendButton(in: app)

        let latestSentMessageAppeared = identifiedElement(
            TrixAccessibilityID.ChatDetail.latestSentMessage,
            in: app
        ).waitForExistence(timeout: 5)
        let outgoingTextAppeared = app.staticTexts[outgoingText].waitForExistence(timeout: 15)
        let sendSuccessBannerAppeared = identifiedElement(
            TrixAccessibilityID.ChatDetail.successBanner,
            in: app
        ).waitForExistence(timeout: 5)
        let errorBanner = identifiedElement(TrixAccessibilityID.ChatDetail.errorBanner, in: app)
        XCTAssertFalse(errorBanner.waitForExistence(timeout: 1))
        XCTAssertTrue(
            latestSentMessageAppeared || outgoingTextAppeared || sendSuccessBannerAppeared
        )
    }

    func testSeededGroupDetailShowsTimeline() async throws {
        try await TrixUITestApp.skipUnlessServerReachable()

        let app = launchSeededConversationBundle(scenarioLabel: "seeded-chat-bundle-group")
        assertDashboardVisible(in: app)

        tapSeededChatRow(.group, in: app)

        guard identifiedElement(TrixAccessibilityID.ChatDetail.screen, in: app)
            .waitForExistence(timeout: 20) else {
            return XCTFail("Expected consumer chat detail screen for seeded group.")
        }
        XCTAssertTrue(
            identifiedElement(TrixAccessibilityID.ChatDetail.message(.groupSeed), in: app)
                .waitForExistence(timeout: 10)
        )
    }
}
