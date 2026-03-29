import Foundation

/// Launch arguments read by the app when running UI tests. Keep values stable; UI test targets compile this file via XcodeGen.
enum MacAdminUITestLaunchArgument {
    static let enableUITesting = "-TrixMacAdminUITesting"
}

/// Accessibility identifiers for UI tests and assistive tech.
enum MacAdminAccessibilityIdentifier {
    static let sidebar = "admin.sidebar"
    static let usersSearchField = "admin.users.search"
    static let usersProvisionButton = "admin.users.provision"
    static let usersRefreshButton = "admin.users.refresh"
    static let usersLoadMoreButton = "admin.users.loadMore"
}

extension UserDefaults {
    private static let uiTestingKey = "TrixMacAdminUITesting"

    static var trixMacAdminIsUITesting: Bool {
        get { UserDefaults.standard.bool(forKey: uiTestingKey) }
        set { UserDefaults.standard.set(newValue, forKey: uiTestingKey) }
    }
}
