import Foundation
import XCTest
@testable import Trix

final class MockTrixServiceGroupLeaveTests: XCTestCase {
    @MainActor
    func testLeaveGroupClearsSelectedGroupAfterServerSuccess() async throws {
        let service = MockTrixService()
        let model = TrixAppModel(
            sessionStore: GroupLeaveTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            trixService: service
        )

        await model.login(
            userID: "@me:trix.selfhost.ru",
            password: "test-password"
        )

        let groupRoom = try XCTUnwrap(
            model.roomListViewModel.rooms.first(where: { $0.kind == .group })
        )
        await model.selectRoom(groupRoom)
        XCTAssertEqual(model.selectedRoomID, groupRoom.id)

        await model.leaveGroup(groupRoom)

        XCTAssertFalse(model.roomListViewModel.rooms.contains(where: { $0.id == groupRoom.id }))
        XCTAssertNotEqual(model.selectedRoomID, groupRoom.id)
        XCTAssertNotEqual(model.selectedRoom?.id, groupRoom.id)
    }

    func testLeaveGroupRemovesGroupFromRoomListAndBlocksSend() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "@me:trix.selfhost.ru",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )

        let rooms = try await service.rooms(session: session)
        let groupRoom = try XCTUnwrap(rooms.first(where: { $0.kind == .group }))

        try await service.leaveGroup(roomID: groupRoom.id, session: session)

        let roomsAfterLeave = try await service.rooms(session: session)
        XCTAssertFalse(roomsAfterLeave.contains(where: { $0.id == groupRoom.id }))

        do {
            _ = try await service.sendText("after-leave", roomID: groupRoom.id, session: session)
            XCTFail("Expected sendText to fail after leaving the group")
        } catch TrixClientError.roomUnavailable {
            // Expected.
        }
    }

    func testLeaveGroupRejectsDirectRoom() async throws {
        let service = MockTrixService()
        let session = try await service.login(
            userID: "@me:trix.selfhost.ru",
            password: "test-password",
            serverURL: XMPPClientConfiguration.connectionURL
        )
        let rooms = try await service.rooms(session: session)
        let directRoom = try XCTUnwrap(rooms.first(where: { $0.kind == .direct }))

        do {
            try await service.leaveGroup(roomID: directRoom.id, session: session)
            XCTFail("Expected leaveGroup to reject direct rooms")
        } catch TrixClientError.roomUnavailable {
            // Expected.
        }
    }
}

private struct GroupLeaveTestSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        nil
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}
