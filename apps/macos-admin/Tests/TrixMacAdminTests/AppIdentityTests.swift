import XCTest
@testable import TrixMacAdmin

final class AppIdentityTests: XCTestCase {
    func testAdminBundleIdentityDoesNotCollideWithConsumerApp() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.softgrid.trixadmin")
        XCTAssertNotEqual(AppIdentity.bundleIdentifier, "com.softgrid.trixapp")
        XCTAssertEqual(AppIdentity.keychainService, "com.softgrid.trixadmin")
    }
}
