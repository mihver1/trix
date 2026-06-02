import Foundation
import CoreGraphics
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

    func testAvatarRendererKeepsVCardPayloadSmall() throws {
        let image = try XCTUnwrap(Self.testAvatarSourceImage(width: 900, height: 700))
        let avatar = try XCTUnwrap(TrixAvatarImageRenderer.avatarImage(
            from: image,
            cropRect: CGRect(x: 80, y: 20, width: 640, height: 640)
        ))

        XCTAssertEqual(avatar.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(avatar.data.count, TrixAvatarImageRenderer.maxEncodedAvatarBytes)
        XCTAssertLessThan(avatar.dataURL.utf8.count, 72 * 1024)
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

    @MainActor
    func testAppModelMembersIncludeUpdatedOwnAvatar() async throws {
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: IdentityTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            trixService: service
        )
        await model.login(userID: "me", password: "test-password")
        let groupRoom = try XCTUnwrap(model.roomListViewModel.rooms.first(where: { $0.kind == .group }))
        let avatarData = Data("avatar-png".utf8)

        _ = try await model.updateProfile(
            TrixUserProfileUpdate(
                displayName: "Me",
                bio: "",
                statusMessage: "",
                website: "",
                avatar: .image(TrixUserAvatarImage(data: avatarData))
            )
        )
        let members = try await model.members(roomID: groupRoom.id)
        let currentMember = try XCTUnwrap(members.first { member in
            member.userID.caseInsensitiveCompare(model.session?.userID ?? "") == .orderedSame
        })

        XCTAssertEqual(TrixUserAvatarImage.imageData(fromDataURL: currentMember.avatarURL), avatarData)
    }
}

private struct IdentityTestSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        nil
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}

private extension TrixUserIdentityTests {
    static func testAvatarSourceImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        for y in stride(from: 0, to: height, by: 20) {
            for x in stride(from: 0, to: width, by: 20) {
                let red = CGFloat((x * 37 + y * 11) % 255) / 255
                let green = CGFloat((x * 7 + y * 29) % 255) / 255
                let blue = CGFloat((x * 19 + y * 13) % 255) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }

        context.setFillColor(CGColor(red: 0.95, green: 0.1, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 190, y: 110, width: 360, height: 360))
        return context.makeImage()
    }
}
