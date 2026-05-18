import Foundation
import XCTest
@testable import Trix

@MainActor
final class RoomListViewModelTests: XCTestCase {
    func testCachedRoomsStayVisibleWhileLiveReloadIsPending() async {
        let cachedRoom = Self.room(
            id: "alice@trix.selfhost.ru",
            name: "Alice",
            preview: "Cached preview",
            timestamp: 1
        )
        let liveRoom = Self.room(
            id: "alice@trix.selfhost.ru",
            name: "Alice",
            preview: "Live preview",
            timestamp: 2
        )
        let service = RoomListGateService(
            cachedRooms: [cachedRoom],
            rooms: [liveRoom],
            delayRooms: true
        )
        let viewModel = RoomListViewModel()

        await viewModel.loadCached(session: Self.session, service: service)
        XCTAssertEqual(viewModel.rooms.map(\.lastMessagePreview), ["Cached preview"])

        let reloadTask = Task {
            await viewModel.reload(session: Self.session, service: service)
        }
        await service.waitForRoomsRequest()

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(viewModel.rooms.map(\.lastMessagePreview), ["Cached preview"])

        await service.releaseRooms()
        await reloadTask.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.rooms.map(\.lastMessagePreview), ["Live preview"])
    }

    private static let session = TrixSession(
        userID: "@me:trix.selfhost.ru",
        deviceID: "TEST",
        homeserverURL: XMPPClientConfiguration.connectionURL,
        accessToken: "test-password",
        refreshToken: nil,
        oidcData: nil,
        sdkStoreID: "test",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    private static func room(id: String, name: String, preview: String, timestamp: TimeInterval) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: name,
            kind: .direct,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: preview,
            lastActivityAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}

private actor RoomListGateService: TrixSyncService, TrixRoomBootstrapService {
    private let cachedRoomSummaries: [TrixRoomSummary]
    private let roomSummaries: [TrixRoomSummary]
    private var delayRooms: Bool
    private var didRequestRooms = false
    private var roomsRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var roomsReleaseWaiter: CheckedContinuation<Void, Never>?

    init(cachedRooms: [TrixRoomSummary], rooms: [TrixRoomSummary], delayRooms: Bool) {
        self.cachedRoomSummaries = cachedRooms
        self.roomSummaries = rooms
        self.delayRooms = delayRooms
    }

    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        cachedRoomSummaries
    }

    func rooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        didRequestRooms = true
        let waiters = roomsRequestWaiters
        roomsRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }

        if delayRooms {
            await withCheckedContinuation { continuation in
                roomsReleaseWaiter = continuation
            }
        }

        return roomSummaries
    }

    func waitForRoomsRequest() async {
        if didRequestRooms {
            return
        }

        await withCheckedContinuation { continuation in
            roomsRequestWaiters.append(continuation)
        }
    }

    func releaseRooms() {
        delayRooms = false
        roomsReleaseWaiter?.resume()
        roomsReleaseWaiter = nil
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        throw TrixClientError.roomUnavailable
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        throw TrixClientError.roomUnavailable
    }

    func invitations(session: TrixSession) async throws -> [TrixRoomInvite] {
        []
    }

    func acceptInvitation(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        throw TrixClientError.inviteUnavailable
    }

    func declineInvitation(roomID: String, session: TrixSession) async throws {
        throw TrixClientError.inviteUnavailable
    }

    func joinRoom(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        throw TrixClientError.roomUnavailable
    }

    func joinInvitedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        []
    }
}
