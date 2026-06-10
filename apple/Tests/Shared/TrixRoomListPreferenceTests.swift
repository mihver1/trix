import Foundation
import XCTest
@testable import Trix

final class TrixRoomListPreferenceStoreTests: XCTestCase {
    func testStorePersistsPinsAndMarkedUnreadPerAccountWithoutPlaintextAtRest() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrixRoomListPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = TrixRoomListPreferenceStore(
            keychainService: "com.softgrid.trix.tests.room-list-preferences.\(UUID().uuidString)",
            keychainAccount: "room-list-preference-test-key",
            directoryName: "Preferences",
            applicationSupportDirectoryURL: rootURL
        )
        let roomID = "alice@trix.selfhost.ru"
        let accountA = "me@trix.selfhost.ru"
        let accountB = "other@trix.selfhost.ru"

        try store.save(
            TrixRoomListPreferenceSnapshot(
                pinnedRoomIDs: ["Alice@Trix.selfhost.ru"],
                markedUnreadRoomIDs: [],
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            accountID: accountA
        )
        try store.save(
            TrixRoomListPreferenceSnapshot(
                pinnedRoomIDs: [],
                markedUnreadRoomIDs: [roomID],
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            accountID: accountB
        )

        let snapshotA = try store.load(accountID: accountA)
        let snapshotB = try store.load(accountID: accountB)
        XCTAssertTrue(snapshotA.isPinned(roomID))
        XCTAssertFalse(snapshotA.isMarkedUnread(roomID))
        XCTAssertTrue(snapshotB.isMarkedUnread("ALICE@trix.selfhost.ru"))
        XCTAssertFalse(snapshotB.isPinned(roomID))
        XCTAssertFalse(snapshotA.isPinned("bob@trix.selfhost.ru"))

        let raw = try Data(contentsOf: store.encryptedFileURL(accountID: accountA))
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(roomID))
        XCTAssertFalse(rawString.contains("pinned"))
    }

    func testSnapshotTogglesAreNoOpsWhenNothingChanges() {
        let snapshot = TrixRoomListPreferenceSnapshot(
            pinnedRoomIDs: [],
            markedUnreadRoomIDs: [],
            updatedAt: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(snapshot.settingMarkedUnread(false, for: "alice@trix.selfhost.ru"), snapshot)
        XCTAssertEqual(snapshot.togglingPin(for: "   "), snapshot)

        let pinned = snapshot.togglingPin(for: "Alice@Trix.selfhost.ru")
        XCTAssertTrue(pinned.isPinned("alice@trix.selfhost.ru"))
        XCTAssertFalse(pinned.togglingPin(for: "alice@trix.selfhost.ru").isPinned("alice@trix.selfhost.ru"))
    }
}

@MainActor
final class RoomListViewModelPreferenceTests: XCTestCase {
    func testSortedRoomsPutPinnedFirstByActivityThenServiceOrder() async {
        let roomA = Self.room(id: "a@trix.selfhost.ru", timestamp: 50)
        let roomB = Self.room(id: "b@trix.selfhost.ru", timestamp: 40)
        let roomC = Self.room(id: "c@trix.selfhost.ru", timestamp: 30)
        let roomD = Self.room(id: "d@trix.selfhost.ru", timestamp: 20)
        let service = RoomListPreferenceStubService(rooms: [roomA, roomB, roomC, roomD])
        let viewModel = RoomListViewModel()

        await viewModel.reload(session: Self.session, service: service)
        XCTAssertEqual(viewModel.sortedRooms.map(\.id), [roomA.id, roomB.id, roomC.id, roomD.id])

        viewModel.togglePin(roomID: "D@Trix.selfhost.ru")
        viewModel.togglePin(roomID: roomC.id)

        XCTAssertTrue(viewModel.isPinned(roomID: roomC.id))
        XCTAssertTrue(viewModel.isPinned(roomID: roomD.id))
        XCTAssertEqual(
            viewModel.sortedRooms.map(\.id),
            [roomC.id, roomD.id, roomA.id, roomB.id]
        )
        XCTAssertEqual(
            viewModel.rooms.map(\.id),
            [roomA.id, roomB.id, roomC.id, roomD.id],
            "Service ordering must stay untouched underneath the pinned overlay"
        )

        viewModel.togglePin(roomID: "C@TRIX.SELFHOST.RU")
        XCTAssertEqual(
            viewModel.sortedRooms.map(\.id),
            [roomD.id, roomA.id, roomB.id, roomC.id]
        )
    }

    func testMarkedUnreadSurvivesReloadMerge() async {
        let room = Self.room(id: "alice@trix.selfhost.ru", timestamp: 10)
        let service = RoomListPreferenceStubService(rooms: [room])
        let viewModel = RoomListViewModel()

        await viewModel.reload(session: Self.session, service: service)
        viewModel.markAsUnread(roomID: room.id)
        XCTAssertTrue(viewModel.isMarkedUnread(roomID: room.id))

        await viewModel.reload(session: Self.session, service: service)

        XCTAssertTrue(
            viewModel.isMarkedUnread(roomID: room.id),
            "Manual unread flag must survive mergedRoomsAfterReload"
        )
        XCTAssertEqual(
            viewModel.rooms.first?.unreadCount,
            0,
            "Manual unread flag must not corrupt server unread counts"
        )
    }

    func testOpeningRoomClearsMarkedUnreadAndPersistsThroughStore() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrixRoomListPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = TrixRoomListPreferenceStore(
            keychainService: "com.softgrid.trix.tests.room-list-preferences.\(UUID().uuidString)",
            keychainAccount: "room-list-preference-test-key",
            directoryName: "Preferences",
            applicationSupportDirectoryURL: rootURL
        )
        let room = Self.room(id: "alice@trix.selfhost.ru", timestamp: 10)
        let service = RoomListPreferenceStubService(rooms: [room])
        let viewModel = RoomListViewModel()
        viewModel.attachListPreferences(store: store, accountID: Self.session.userID)

        await viewModel.reload(session: Self.session, service: service)
        viewModel.markAsUnread(roomID: room.id)
        XCTAssertTrue(try store.load(accountID: Self.session.userID).isMarkedUnread(room.id))

        // Opening a room runs through the existing markRead path.
        viewModel.markRead(roomID: room.id)

        XCTAssertFalse(viewModel.isMarkedUnread(roomID: room.id))
        XCTAssertFalse(try store.load(accountID: Self.session.userID).isMarkedUnread(room.id))
    }

    func testTogglePinPersistsAcrossViewModelInstances() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrixRoomListPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = TrixRoomListPreferenceStore(
            keychainService: "com.softgrid.trix.tests.room-list-preferences.\(UUID().uuidString)",
            keychainAccount: "room-list-preference-test-key",
            directoryName: "Preferences",
            applicationSupportDirectoryURL: rootURL
        )
        let roomID = "alice@trix.selfhost.ru"

        let firstViewModel = RoomListViewModel()
        firstViewModel.attachListPreferences(store: store, accountID: Self.session.userID)
        firstViewModel.togglePin(roomID: roomID)
        XCTAssertNil(firstViewModel.errorMessage)

        let secondViewModel = RoomListViewModel()
        secondViewModel.attachListPreferences(store: store, accountID: Self.session.userID)
        XCTAssertTrue(secondViewModel.isPinned(roomID: roomID))

        secondViewModel.clear()
        XCTAssertFalse(secondViewModel.isPinned(roomID: roomID))
        XCTAssertTrue(
            try store.load(accountID: Self.session.userID).isPinned(roomID),
            "clear() resets in-memory state only; the per-account file stays for the next sign-in"
        )
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

    private static func room(id: String, timestamp: TimeInterval, unreadCount: Int = 0) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: id,
            kind: .direct,
            isEncrypted: true,
            unreadCount: unreadCount,
            lastMessagePreview: "Encrypted preview",
            lastActivityAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}

private actor RoomListPreferenceStubService: TrixSyncService, TrixRoomBootstrapService {
    private let roomSummaries: [TrixRoomSummary]

    init(rooms: [TrixRoomSummary]) {
        self.roomSummaries = rooms
    }

    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        roomSummaries
    }

    func rooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        roomSummaries
    }

    func invitations(session: TrixSession) async throws -> [TrixRoomInvite] {
        []
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
