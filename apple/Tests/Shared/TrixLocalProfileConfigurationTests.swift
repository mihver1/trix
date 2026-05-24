import XCTest
@testable import Trix

final class TrixLocalProfileConfigurationTests: XCTestCase {
    func testLocalProfileSanitizesStoreSuffixes() throws {
        let profile = try XCTUnwrap(TrixLocalProfileConfiguration(rawName: " Alice Dev! "))

        XCTAssertEqual(profile.name, "alice-dev")
        XCTAssertEqual(
            profile.keychainService("com.softgrid.trix.session"),
            "com.softgrid.trix.session.local.alice-dev"
        )
        XCTAssertEqual(profile.directoryName("TimelineCache"), "TimelineCache-Local-alice-dev")
        XCTAssertEqual(
            profile.userDefaultsSuiteName("com.softgrid.trix.media-cache-settings"),
            "com.softgrid.trix.media-cache-settings.local.alice-dev"
        )
    }

    func testLocalProfileRejectsEmptyNames() {
        XCTAssertNil(TrixLocalProfileConfiguration(rawName: nil))
        XCTAssertNil(TrixLocalProfileConfiguration(rawName: "   "))
        XCTAssertNil(TrixLocalProfileConfiguration(rawName: "!!!"))
    }

    func testLocalProfileCanComeFromLocalBundleIdentifier() throws {
        let profile = try XCTUnwrap(TrixLocalProfileConfiguration.current(
            environment: [:],
            bundleIdentifier: "com.softgrid.trixapp.local.Bob",
            infoDictionaryProfile: nil
        ))

        XCTAssertEqual(profile.name, "bob")
    }

    func testCallControlBaseURLCanUseLocalOverride() {
        let url = TrixClientConfiguration.callControlAPIBaseURL(environment: [
            "TRIX_CALL_CONTROL_BASE_URL": "http://127.0.0.1:8092",
        ])

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8092")
    }

    func testCallControlBaseURLFallsBackWhenOverrideIsInvalid() {
        let url = TrixClientConfiguration.callControlAPIBaseURL(environment: [
            "TRIX_CALL_CONTROL_BASE_URL": "not a url",
        ])

        XCTAssertEqual(url.absoluteString, "https://trix.selfhost.ru")
    }

    func testLiveSmokeStorageAvoidsKeychainUnlessExplicitlyOptedIn() {
        XCTAssertFalse(TrixLiveSmokeStorageConfiguration.usesVolatileStorage(environment: [:]))
        XCTAssertTrue(TrixLiveSmokeStorageConfiguration.usesVolatileStorage(environment: [
            "TRIX_XMPP_LIVE_SMOKE_MODE": "timeline-restart",
        ]))
        XCTAssertFalse(TrixLiveSmokeStorageConfiguration.usesVolatileStorage(environment: [
            "TRIX_XMPP_LIVE_SMOKE_MODE": "timeline-restart",
            "TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN": "1",
        ]))
    }
}
