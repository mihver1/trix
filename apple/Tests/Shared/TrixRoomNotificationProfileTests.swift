import Foundation
import XCTest
@testable import Trix

final class TrixRoomNotificationProfileStoreTests: XCTestCase {
    func testProfileStorePersistsByAccountAndRoomWithoutPlaintextAtRest() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrixRoomNotificationProfileTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = TrixRoomNotificationProfileStore(
            keychainService: "com.softgrid.trix.tests.room-notifications.\(UUID().uuidString)",
            keychainAccount: "room-notification-test-key",
            directoryName: "Profiles",
            applicationSupportDirectoryURL: rootURL
        )
        let roomID = "alice@trix.selfhost.ru"
        let accountA = "me@trix.selfhost.ru"
        let accountB = "other@trix.selfhost.ru"

        try store.save(
            TrixRoomNotificationProfileSnapshot(
                profilesByRoomID: [roomID: .muted],
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            accountID: accountA
        )
        try store.save(
            TrixRoomNotificationProfileSnapshot(
                profilesByRoomID: [roomID: .mentionsOnly],
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            accountID: accountB
        )

        XCTAssertEqual(try store.load(accountID: accountA).profile(for: roomID), .muted)
        XCTAssertEqual(try store.load(accountID: accountB).profile(for: roomID), .mentionsOnly)
        XCTAssertEqual(try store.load(accountID: accountA).profile(for: "bob@trix.selfhost.ru"), .defaultProfile)

        let raw = try Data(contentsOf: store.encryptedFileURL(accountID: accountA))
        let rawString = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(rawString.contains(roomID))
        XCTAssertFalse(rawString.contains("muted"))
    }
}

final class TrixRoomNotificationPlannerTests: XCTestCase {
    func testMutedRoomSuppressesLocalNotificationButKeepsUnreadCandidate() {
        let previous = Self.room(id: "alice@trix.selfhost.ru", unreadCount: 0, timestamp: 1)
        let current = Self.room(id: "alice@trix.selfhost.ru", unreadCount: 1, timestamp: 2)
        let payload = Self.silentPayload()
        let candidateRooms = TrixRoomNotificationPlanner.candidateRooms(
            previousRooms: [previous],
            currentRooms: [current],
            payload: payload
        )

        let request = TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: [
                TrixRoomNotificationCandidate(
                    room: current,
                    profile: .muted,
                    hasMention: false
                ),
            ],
            payload: payload,
            badgeCount: 1
        )

        XCTAssertEqual(candidateRooms.map(\.unreadCount), [1])
        XCTAssertNil(request)
    }

    func testMentionsOnlyRequiresLocalMentionAndUsesGenericMentionCopy() {
        let room = Self.room(id: "friends@conference.trix.selfhost.ru", unreadCount: 1, timestamp: 2)
        let payload = Self.silentPayload(roomID: room.id)
        let mentionRequest = TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: [
                TrixRoomNotificationCandidate(
                    room: room,
                    profile: .mentionsOnly,
                    hasMention: true
                ),
            ],
            payload: payload,
            badgeCount: 1
        )
        let nonMentionRequest = TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: [
                TrixRoomNotificationCandidate(
                    room: room,
                    profile: .mentionsOnly,
                    hasMention: false
                ),
            ],
            payload: payload,
            badgeCount: 1
        )

        XCTAssertEqual(mentionRequest?.body, "You were mentioned in an encrypted message")
        XCTAssertEqual(mentionRequest?.threadIdentifier, room.id)
        XCTAssertNil(nonMentionRequest)
    }

    func testForegroundNotificationExcludesOpenRoomButKeepsOtherUnreadRooms() {
        let openRoom = Self.room(id: "alice@trix.selfhost.ru", unreadCount: 1, timestamp: 2)
        let otherRoom = Self.room(id: "bob@trix.selfhost.ru", unreadCount: 1, timestamp: 2)
        let payload = Self.silentPayload()

        let mixedRequest = TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: [
                TrixRoomNotificationCandidate(
                    room: openRoom,
                    profile: .defaultProfile,
                    hasMention: false
                ),
                TrixRoomNotificationCandidate(
                    room: otherRoom,
                    profile: .defaultProfile,
                    hasMention: false
                ),
            ],
            payload: payload,
            badgeCount: 2,
            excludingRoomID: openRoom.id
        )
        let openOnlyRequest = TrixRoomNotificationPlanner.localNotificationRequest(
            candidates: [
                TrixRoomNotificationCandidate(
                    room: openRoom,
                    profile: .defaultProfile,
                    hasMention: false
                ),
            ],
            payload: payload,
            badgeCount: 1,
            excludingRoomID: openRoom.id
        )

        XCTAssertEqual(mixedRequest?.body, "New encrypted message")
        XCTAssertEqual(mixedRequest?.threadIdentifier, otherRoom.id)
        XCTAssertNil(openOnlyRequest)
    }

    func testTimelineMentionDetectionUsesIncomingDecryptedContentOnly() {
        let previousActivityAt = Date(timeIntervalSince1970: 5)
        let items = [
            Self.item(
                body: "@me please look",
                timestamp: 4,
                isLocalEcho: false
            ),
            Self.item(
                body: "@me local echo",
                timestamp: 6,
                isLocalEcho: true
            ),
            Self.item(
                body: "ping @me",
                timestamp: 7,
                isLocalEcho: false
            ),
        ]

        XCTAssertTrue(
            TrixRoomNotificationPlanner.timelineContainsMention(
                items,
                accountID: "me@trix.selfhost.ru",
                newerThan: previousActivityAt
            )
        )
    }

    func testTimelineMentionDetectionPrefersParsedMentionMetadata() {
        let itemWithNonMatchingMetadata = Self.item(
            body: "ping @me",
            timestamp: 7,
            isLocalEcho: false,
            mentions: [
                TrixMentionReference(
                    targetUserID: "alice@trix.selfhost.ru",
                    displayText: "@me",
                    range: TrixTextReferenceRange(begin: 5, end: 8)
                ),
            ]
        )
        let itemWithoutMetadata = Self.item(
            body: "ping @me",
            timestamp: 8,
            isLocalEcho: false
        )

        XCTAssertFalse(
            TrixRoomNotificationPlanner.timelineContainsMention(
                [itemWithNonMatchingMetadata],
                accountID: "me@trix.selfhost.ru",
                newerThan: nil
            )
        )
        XCTAssertTrue(
            TrixRoomNotificationPlanner.timelineContainsMention(
                [itemWithoutMetadata],
                accountID: "me@trix.selfhost.ru",
                newerThan: nil
            )
        )
    }

    private static func room(id: String, unreadCount: Int, timestamp: TimeInterval) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: id,
            kind: .direct,
            isEncrypted: true,
            unreadCount: unreadCount,
            lastMessagePreview: "Encrypted update",
            lastActivityAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private static func item(
        body: String,
        timestamp: TimeInterval,
        isLocalEcho: Bool,
        mentions: [TrixMentionReference] = []
    ) -> TrixTimelineItem {
        TrixTimelineItem(
            id: UUID().uuidString,
            roomID: "friends@conference.trix.selfhost.ru",
            sender: isLocalEcho ? "me@trix.selfhost.ru" : "alice@trix.selfhost.ru",
            timestamp: Date(timeIntervalSince1970: timestamp),
            body: body,
            isLocalEcho: isLocalEcho,
            attachment: nil,
            mentions: mentions
        )
    }

    private static func silentPayload(roomID: String? = nil) -> TrixRemoteNotificationPayload {
        var trix: [String: Any] = ["type": "sync"]
        if let roomID {
            trix["room"] = roomID
        }
        return TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "content-available": 1,
            ],
            "trix": trix,
        ])
    }
}
