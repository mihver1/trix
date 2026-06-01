import Foundation
import XCTest
@testable import Trix

final class TrixUserIdentityTests: XCTestCase {
    func testHandleHidesConfiguredServerForUserIDs() {
        XCTAssertEqual(TrixUserIdentity.handle(from: "alice@trix.selfhost.ru"), "alice")
        XCTAssertEqual(TrixUserIdentity.handle(from: "alice@trix.selfhost.ru/Trix-iOS"), "alice")
        XCTAssertEqual(TrixUserIdentity.handle(from: "@alice:trix.selfhost.ru"), "alice")
        XCTAssertEqual(TrixUserIdentity.handle(from: "alice"), "alice")
    }

    func testDisplayNameUsesLocalHandleFallback() {
        XCTAssertEqual(TrixUserIdentity.displayName(from: "alice@trix.selfhost.ru"), "Alice")
        XCTAssertEqual(TrixUserIdentity.displayName(from: "@alice:trix.selfhost.ru"), "Alice")

        let profile = TrixUserProfile(
            userID: "alice@trix.selfhost.ru",
            displayName: nil,
            avatarURL: nil
        )
        XCTAssertEqual(profile.title, "Alice")
        XCTAssertEqual(profile.subtitle, "alice")

        let member = TrixRoomMember(
            userID: "@alice:trix.selfhost.ru",
            displayName: nil,
            membership: .joined
        )
        XCTAssertEqual(member.title, "Alice")
    }

    func testShortHandleNormalizesToLocalXMPPUserID() throws {
        XCTAssertEqual(
            try TrixUserIdentity.normalizedXMPPUserID("Alice"),
            "alice@trix.selfhost.ru"
        )
        XCTAssertEqual(
            try TrixUserIdentity.normalizedXMPPUserID("@alice:trix.selfhost.ru"),
            "alice@trix.selfhost.ru"
        )
    }

    func testRejectsForeignUserIDs() {
        XCTAssertThrowsError(try TrixUserIdentity.normalizedXMPPUserID("alice@example.org"))
        XCTAssertThrowsError(try TrixUserIdentity.normalizedXMPPUserID("@alice:example.org"))
    }

    func testMockLoginAcceptsShortHandle() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "me",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )

        XCTAssertEqual(session.userID, "@me:trix.selfhost.ru")
    }
}
