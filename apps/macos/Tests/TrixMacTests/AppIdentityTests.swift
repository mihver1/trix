import XCTest
@testable import TrixMac

final class AppIdentityTests: XCTestCase {
    func testScopedIdentifiersUseBundleIdentifierOutsideUITests() {
        XCTAssertEqual(
            AppIdentity.scopedApplicationSupportDirectoryName(arguments: []),
            AppIdentity.bundleIdentifier
        )
        XCTAssertEqual(
            AppIdentity.scopedKeychainService(arguments: []),
            AppIdentity.bundleIdentifier
        )
    }

    func testScopedIdentifiersUseDedicatedNamespaceDuringUITests() {
        let args = [MacUITestLaunchArgument.enableUITesting]

        XCTAssertEqual(
            AppIdentity.scopedApplicationSupportDirectoryName(arguments: args),
            AppIdentity.bundleIdentifier + ".uitest"
        )
        XCTAssertEqual(
            AppIdentity.scopedKeychainService(arguments: args),
            AppIdentity.bundleIdentifier + ".uitest"
        )
    }

    func testScopedIdentifiersOnlySwitchWhenUITestFlagIsPresentAmongOtherArguments() {
        let regularArgs = ["/Applications/TrixMac.app/Contents/MacOS/TrixMac", "-ApplePersistenceIgnoreState", "YES"]
        XCTAssertEqual(
            AppIdentity.scopedApplicationSupportDirectoryName(arguments: regularArgs),
            AppIdentity.bundleIdentifier
        )
        XCTAssertEqual(
            AppIdentity.scopedKeychainService(arguments: regularArgs),
            AppIdentity.bundleIdentifier
        )

        let uiTestArgs = regularArgs + [MacUITestLaunchArgument.enableUITesting]
        XCTAssertEqual(
            AppIdentity.scopedApplicationSupportDirectoryName(arguments: uiTestArgs),
            AppIdentity.bundleIdentifier + ".uitest"
        )
        XCTAssertEqual(
            AppIdentity.scopedKeychainService(arguments: uiTestArgs),
            AppIdentity.bundleIdentifier + ".uitest"
        )
    }
}
