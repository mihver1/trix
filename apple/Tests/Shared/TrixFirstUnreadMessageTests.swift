import Foundation
import XCTest
@testable import Trix

@MainActor
final class TrixFirstUnreadMessageTests: XCTestCase {
    private static let currentUserID = "@me:trix.selfhost.ru"
    private static let peerUserID = "@alice:trix.selfhost.ru"

    func testReadMarkerSelectsFirstIncomingMessageAfterMarker() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
            Self.outgoing(id: "mine", timestamp: 25),
            Self.incoming(id: "c", timestamp: 30),
            Self.incoming(id: "d", timestamp: 40),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: Self.marker(displayedMessageID: "b"),
            unreadCount: 99,
            currentUserID: Self.currentUserID
        )

        XCTAssertEqual(firstUnreadID, "c")
    }

    func testReadMarkerSkipsOwnMessagesAfterMarker() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.outgoing(id: "mine-1", timestamp: 20),
            Self.outgoing(id: "mine-2", timestamp: 30),
            Self.incoming(id: "b", timestamp: 40),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: Self.marker(displayedMessageID: "a"),
            unreadCount: 3,
            currentUserID: Self.currentUserID
        )

        XCTAssertEqual(firstUnreadID, "b")
    }

    func testReadMarkerAtLatestMessageMeansNoUnreadDivider() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: Self.marker(displayedMessageID: "b"),
            unreadCount: 2,
            currentUserID: Self.currentUserID
        )

        XCTAssertNil(firstUnreadID)
    }

    func testUnknownMarkerFallsBackToUnreadCount() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
            Self.incoming(id: "c", timestamp: 30),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: Self.marker(displayedMessageID: "$missing"),
            unreadCount: 2,
            currentUserID: Self.currentUserID
        )

        XCTAssertEqual(firstUnreadID, "b")
    }

    func testUnreadCountFallbackCountsOnlyIncomingMessages() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
            Self.outgoing(id: "mine", timestamp: 30),
            Self.incoming(id: "c", timestamp: 40),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: nil,
            unreadCount: 2,
            currentUserID: Self.currentUserID
        )

        XCTAssertEqual(firstUnreadID, "b")
    }

    func testZeroUnreadWithoutMarkerMeansNoDivider() {
        let items = [
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: nil,
            unreadCount: 0,
            currentUserID: Self.currentUserID
        )

        XCTAssertNil(firstUnreadID)
    }

    func testTimelineWithOnlyOwnMessagesHasNoDivider() {
        let items = [
            Self.outgoing(id: "mine-1", timestamp: 10),
            Self.outgoing(id: "mine-2", timestamp: 20),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: nil,
            unreadCount: 2,
            currentUserID: Self.currentUserID
        )

        XCTAssertNil(firstUnreadID)
    }

    func testUnsortedInputIsSortedBeforeComputingAnchor() {
        let items = [
            Self.incoming(id: "c", timestamp: 30),
            Self.incoming(id: "a", timestamp: 10),
            Self.incoming(id: "b", timestamp: 20),
        ]

        let firstUnreadID = TimelineViewModel.firstUnreadMessageID(
            in: items,
            readMarker: Self.marker(displayedMessageID: "a"),
            unreadCount: 0,
            currentUserID: Self.currentUserID
        )

        XCTAssertEqual(firstUnreadID, "b")
    }

    private static func marker(displayedMessageID: String) -> TrixRoomReadMarkerState {
        TrixRoomReadMarkerState(
            roomID: "@alice:trix.selfhost.ru",
            displayedMessageID: displayedMessageID,
            senderID: currentUserID,
            displayedAt: Date(timeIntervalSince1970: 50)
        )
    }

    private static func incoming(id: String, timestamp: TimeInterval) -> TrixTimelineItem {
        item(id: id, sender: peerUserID, isLocalEcho: false, timestamp: timestamp)
    }

    private static func outgoing(id: String, timestamp: TimeInterval) -> TrixTimelineItem {
        item(id: id, sender: currentUserID, isLocalEcho: true, timestamp: timestamp)
    }

    private static func item(
        id: String,
        sender: String,
        isLocalEcho: Bool,
        timestamp: TimeInterval
    ) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: "@alice:trix.selfhost.ru",
            sender: sender,
            timestamp: Date(timeIntervalSince1970: timestamp),
            body: id,
            isLocalEcho: isLocalEcho,
            attachment: nil,
            deliveryState: isLocalEcho ? .sent : nil
        )
    }
}
