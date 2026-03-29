import XCTest
@testable import TrixMacAdmin

final class ClusterProfileStoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() {
        super.setUp()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryRoot)
        super.tearDown()
    }

    func testRoundTripsClusterProfilesAndLastSelection() throws {
        let store = ClusterProfileStore(rootURL: temporaryRoot)
        let eu = ClusterProfile(
            id: UUID(),
            displayName: "prod-eu",
            baseURL: URL(string: "https://eu.example")!,
            environmentLabel: "prod",
            authMode: .localCredentials
        )
        let us = ClusterProfile(
            id: UUID(),
            displayName: "staging",
            baseURL: URL(string: "https://staging.example")!,
            environmentLabel: "staging",
            authMode: .localCredentials
        )

        try store.save([eu, us], lastSelectedClusterID: us.id)
        let snapshot = try store.load()

        XCTAssertEqual(snapshot.profiles.count, 2)
        XCTAssertEqual(snapshot.lastSelectedClusterID, us.id)
    }
}
