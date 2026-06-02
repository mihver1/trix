import Foundation
import XCTest
@testable import Trix

@MainActor
final class TrixRoomSelectionTests: XCTestCase {
    func testSelectingGroupRoomShowsCachedTimelineBeforeMemberRefreshCompletes() async throws {
        let groupRoomID = "!friends:trix.selfhost.ru"
        let service = MockTrixService(
            now: Date(timeIntervalSince1970: 100),
            delayedMemberRoomIDs: [groupRoomID]
        )
        let model = TrixAppModel(
            sessionStore: RoomSelectionTestSessionStore(),
            registrationService: MockInviteRegistrationService(),
            trixService: service
        )

        let session = TrixSession(
            userID: "@me:trix.selfhost.ru",
            deviceID: "MOCK-TEST",
            homeserverURL: URL(string: "https://trix.selfhost.ru")!,
            accessToken: "test-token",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "mock-test",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        await model.installTestSession(
            session,
            account: TrixAccount(
                userID: session.userID,
                displayName: "Me",
                deviceID: session.deviceID
            )
        )
        let groupRoom = try XCTUnwrap(model.roomListViewModel.rooms.first(where: { $0.id == groupRoomID }))
        let releaseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            await service.releaseMembers(roomID: groupRoom.id)
        }
        defer {
            releaseTask.cancel()
        }

        let selectTask = Task {
            await model.selectRoom(groupRoom)
        }
        await waitUntilSelectedRoom(groupRoom.id, model: model)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.selectedRoomID, groupRoom.id)
        XCTAssertFalse(model.timelineViewModel.items.isEmpty)
        XCTAssertTrue(model.timelineViewModel.items.allSatisfy { $0.roomID == groupRoom.id })

        await service.releaseMembers(roomID: groupRoom.id)
        await selectTask.value
    }

    private func waitUntilSelectedRoom(_ roomID: String, model: TrixAppModel) async {
        for _ in 0..<20 {
            if model.selectedRoomID == roomID {
                return
            }

            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct RoomSelectionTestSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        nil
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}
