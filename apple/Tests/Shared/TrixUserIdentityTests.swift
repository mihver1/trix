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

    func testMockProfileUpdateStoresAvatarDataURL() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "me",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )
        let avatarData = Data("avatar-png".utf8)

        let profile = try await service.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Me",
                bio: "",
                statusMessage: "",
                website: "",
                avatar: .image(TrixUserAvatarImage(data: avatarData))
            ),
            session: session
        )

        XCTAssertEqual(TrixUserAvatarImage.imageData(fromDataURL: profile.avatarURL), avatarData)
        XCTAssertTrue(profile.avatarURL?.hasPrefix("data:image/png;base64,") == true)
    }

    func testMockProfileUpdatePreservesAvatarUnlessChanged() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "me",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )
        let avatarData = Data("avatar-png".utf8)

        _ = try await service.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Me",
                bio: "",
                statusMessage: "",
                website: "",
                avatar: .image(TrixUserAvatarImage(data: avatarData))
            ),
            session: session
        )
        let updatedProfile = try await service.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Updated Me",
                bio: "bio",
                statusMessage: "",
                website: ""
            ),
            session: session
        )

        XCTAssertEqual(updatedProfile.displayName, "Updated Me")
        XCTAssertEqual(updatedProfile.metadata.bio, "bio")
        XCTAssertEqual(TrixUserAvatarImage.imageData(fromDataURL: updatedProfile.avatarURL), avatarData)
    }

    func testMockProfileUpdateCanRemoveAvatar() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "me",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )

        _ = try await service.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Me",
                bio: "",
                statusMessage: "",
                website: "",
                avatar: .image(TrixUserAvatarImage(data: Data("avatar-png".utf8)))
            ),
            session: session
        )
        let profile = try await service.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Me",
                bio: "",
                statusMessage: "",
                website: "",
                avatar: .remove
            ),
            session: session
        )

        XCTAssertNil(profile.avatarURL)
    }
}
