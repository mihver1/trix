import Foundation
import XCTest
@testable import Trix

final class TrixTimelineBackfillTests: XCTestCase {
    func testEncryptionRecipientsAlwaysIncludeOwnAccount() throws {
        let recipients = try XMPPMartinService.omemoEncryptionRecipientJIDs(
            [
                " peer@trix.selfhost.ru ",
                "PEER@trix.selfhost.ru",
                "friend@trix.selfhost.ru",
            ],
            accountJID: "ME@trix.selfhost.ru"
        )

        XCTAssertEqual(
            recipients,
            [
                "peer@trix.selfhost.ru",
                "friend@trix.selfhost.ru",
                "me@trix.selfhost.ru",
            ]
        )
    }

    func testGroupBackfillRecipientsUseMembersAndOwnAccountFanout() throws {
        let groupRecipients = try XMPPMartinService.timelineBackfillRepairRecipientJIDs(
            roomID: "friends@conference.trix.selfhost.ru",
            accountJID: "ME@trix.selfhost.ru",
            knownMemberUserIDs: [
                "me@trix.selfhost.ru",
                " PEER@trix.selfhost.ru ",
                "peer@trix.selfhost.ru",
                "friend@trix.selfhost.ru",
                "friends@conference.trix.selfhost.ru",
            ]
        )

        XCTAssertEqual(groupRecipients, ["friend@trix.selfhost.ru", "peer@trix.selfhost.ru"])

        let encryptedRecipients = try XMPPMartinService.omemoEncryptionRecipientJIDs(
            groupRecipients,
            accountJID: "me@trix.selfhost.ru"
        )
        XCTAssertEqual(
            encryptedRecipients,
            ["friend@trix.selfhost.ru", "peer@trix.selfhost.ru", "me@trix.selfhost.ru"]
        )
    }

    func testBackfillResponseRoundTripsTimelineItemWithoutShowingControlPayload() throws {
        let item = TrixTimelineItem(
            id: "trix-original-1",
            roomID: "peer@trix.selfhost.ru",
            sender: "me@trix.selfhost.ru",
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            body: "lost message",
            isLocalEcho: true,
            attachment: nil,
            deliveryState: .sent,
            mentions: [
                TrixMentionReference(
                    targetUserID: "peer@trix.selfhost.ru",
                    displayText: "Peer",
                    range: TrixTextReferenceRange(begin: 0, end: 4)
                )
            ],
            replyTo: TrixReplyReference(
                targetMessageID: "trix-parent",
                targetSenderID: "peer@trix.selfhost.ru",
                preview: TrixReplyPreview(senderID: "peer@trix.selfhost.ru", body: "parent")
            ),
            thread: TrixThreadReference(threadID: "thread-1", rootMessageID: "trix-parent")
        )

        let response = TrixTimelineBackfillResponseDescriptor(item: item)
        let body = try response.encodedBody()
        XCTAssertNil(TrixTimelineBackfillRequestDescriptor.decoded(from: body))

        let decoded = try XCTUnwrap(TrixTimelineBackfillResponseDescriptor.decoded(from: body))
        let repaired = decoded.timelineItem(accountJID: "me@trix.selfhost.ru")

        XCTAssertEqual(repaired.id, item.id)
        XCTAssertEqual(repaired.roomID, item.roomID)
        XCTAssertEqual(repaired.sender, item.sender)
        XCTAssertEqual(repaired.timestamp, item.timestamp)
        XCTAssertEqual(repaired.body, item.body)
        XCTAssertEqual(repaired.isLocalEcho, true)
        XCTAssertEqual(repaired.deliveryState, TrixDeliveryState.sent)
        XCTAssertEqual(repaired.mentions, item.mentions)
        XCTAssertEqual(repaired.replyTo, item.replyTo)
        XCTAssertEqual(repaired.thread, item.thread)

        let mirroredRoomItem = decoded.timelineItem(
            accountJID: "peer@trix.selfhost.ru",
            roomID: "me@trix.selfhost.ru"
        )
        XCTAssertEqual(mirroredRoomItem.roomID, "me@trix.selfhost.ru")
        XCTAssertEqual(mirroredRoomItem.sender, item.sender)
    }

    func testBackfillRequestFiltersEmptyAndDuplicateMessageIDs() throws {
        let request = TrixTimelineBackfillRequestDescriptor(
            roomID: "peer@trix.selfhost.ru",
            messageIDs: [" original-1 ", "", "ORIGINAL-1", "original-2"],
            requestedByDeviceID: "NEW-DEVICE"
        )

        XCTAssertEqual(request.messageIDs, ["original-1", "original-2"])

        let decoded = try XCTUnwrap(
            TrixTimelineBackfillRequestDescriptor.decoded(from: try request.encodedBody())
        )
        XCTAssertEqual(decoded, request)
    }
}
