import XCTest
@testable import TrixMacAdmin

final class AdminSessionStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var keychain: AdminKeychainStore!
    private var store: AdminSessionStore!
    private var clusterID: UUID!

    override func setUp() {
        super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let isolatedService = "com.softgrid.trixadmin.tests.session.\(UUID().uuidString)"
        keychain = AdminKeychainStore(service: isolatedService)
        store = AdminSessionStore(rootURL: temporaryRoot, keychain: keychain)
        clusterID = UUID()
    }

    override func tearDown() {
        try? keychain.removeAccessToken(for: clusterID)
        try? FileManager.default.removeItem(at: temporaryRoot)
        super.tearDown()
    }

    func testSaveAndLoadActiveSession() throws {
        let response = AdminSessionResponse(
            accessToken: "tok",
            expiresAtUnix: UInt64(Date().timeIntervalSince1970) + 3600,
            username: "admin"
        )
        try store.saveSession(response, clusterID: clusterID)
        let loaded = try store.loadSession(clusterID: clusterID)
        XCTAssertEqual(loaded?.accessToken, "tok")
        XCTAssertEqual(loaded?.username, "admin")
        XCTAssertEqual(loaded?.expiresAtUnix, response.expiresAtUnix)
    }

    func testExpiredSessionIsCleared() throws {
        let response = AdminSessionResponse(
            accessToken: "old",
            expiresAtUnix: 1,
            username: "admin"
        )
        try store.saveSession(response, clusterID: clusterID)
        let loaded = try store.loadSession(clusterID: clusterID)
        XCTAssertNil(loaded)
        XCTAssertNil(try keychain.loadAccessToken(for: clusterID))
    }

    func testClearSessionRemovesKeychainAndMetadata() throws {
        let response = AdminSessionResponse(
            accessToken: "tok",
            expiresAtUnix: UInt64(Date().timeIntervalSince1970) + 3600,
            username: "admin"
        )
        try store.saveSession(response, clusterID: clusterID)
        try store.clearSession(clusterID: clusterID)
        XCTAssertNil(try store.loadSession(clusterID: clusterID))
        XCTAssertNil(try keychain.loadAccessToken(for: clusterID))
    }
}
