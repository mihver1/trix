import XCTest

final class UserAdminSmokeTests: XCTestCase {
    @MainActor
    func testLaunchesClusterSidebar() async {
        let app = XCUIApplication()
        app.launchArguments = [MacAdminUITestLaunchArgument.enableUITesting]
        app.launch()

        XCTAssertTrue(app.staticTexts["Clusters"].waitForExistence(timeout: 2))
    }
}
