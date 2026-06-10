import Foundation
import XCTest
@testable import Trix

final class TrixRoomMediaCollectorTests: XCTestCase {
    private static let roomID = "@alice:trix.selfhost.ru"
    private static let senderID = "@alice:trix.selfhost.ru"

    func testGalleryItemsKeepOnlyPreviewableImagesAndStickers() {
        let items = [
            Self.item(id: "text", timestamp: 10, attachment: nil),
            Self.item(id: "image", timestamp: 20, attachment: Self.imageAttachment()),
            Self.item(id: "sticker", timestamp: 30, attachment: Self.stickerAttachment()),
            Self.item(id: "document", timestamp: 40, attachment: Self.fileAttachment()),
            Self.item(
                id: "locked-image",
                timestamp: 50,
                attachment: Self.imageAttachment(sourceJSON: nil)
            ),
            Self.item(
                id: "oversized-image",
                timestamp: 60,
                attachment: Self.imageAttachment(
                    sizeBytes: TrixInlineMediaPreviewSupport.maxInlinePreviewBytes + 1
                )
            ),
            Self.item(
                id: "unsized-image",
                timestamp: 70,
                attachment: Self.imageAttachment(sizeBytes: nil)
            ),
        ]

        let galleryItems = TrixRoomMediaCollector.galleryItems(in: items)

        XCTAssertEqual(galleryItems.map(\.id), ["image", "sticker"])
    }

    func testGalleryItemsExcludeRetractedMessages() {
        let items = [
            Self.item(id: "kept", timestamp: 10, attachment: Self.imageAttachment()),
            Self.item(
                id: "deleted",
                timestamp: 20,
                attachment: Self.imageAttachment(),
                isRetracted: true
            ),
        ]

        let galleryItems = TrixRoomMediaCollector.galleryItems(in: items)

        XCTAssertEqual(galleryItems.map(\.id), ["kept"])
    }

    func testGalleryItemsAreSortedByTimestampAscendingWithIdentifierTieBreak() {
        let items = [
            Self.item(id: "z-later", timestamp: 30, attachment: Self.imageAttachment()),
            Self.item(id: "b-tied", timestamp: 10, attachment: Self.imageAttachment()),
            Self.item(id: "a-tied", timestamp: 10, attachment: Self.imageAttachment()),
            Self.item(id: "middle", timestamp: 20, attachment: Self.imageAttachment()),
        ]

        let galleryItems = TrixRoomMediaCollector.galleryItems(in: items)

        XCTAssertEqual(galleryItems.map(\.id), ["a-tied", "b-tied", "middle", "z-later"])
    }

    func testAttachmentItemsKeepFilesAndSortAscending() {
        let items = [
            Self.item(id: "document", timestamp: 30, attachment: Self.fileAttachment()),
            Self.item(id: "text", timestamp: 20, attachment: nil),
            Self.item(id: "image", timestamp: 10, attachment: Self.imageAttachment()),
            Self.item(
                id: "deleted-document",
                timestamp: 40,
                attachment: Self.fileAttachment(),
                isRetracted: true
            ),
        ]

        let attachmentItems = TrixRoomMediaCollector.attachmentItems(in: items)

        XCTAssertEqual(attachmentItems.map(\.id), ["image", "document"])
    }

    func testGalleryIndexFindsPositionOfItem() {
        let items = [
            Self.item(id: "first", timestamp: 10, attachment: Self.imageAttachment()),
            Self.item(id: "second", timestamp: 20, attachment: Self.imageAttachment()),
            Self.item(id: "third", timestamp: 30, attachment: Self.imageAttachment()),
        ]

        let galleryItems = TrixRoomMediaCollector.galleryItems(in: items)

        XCTAssertEqual(TrixRoomMediaCollector.galleryIndex(of: "second", in: galleryItems), 1)
        XCTAssertNil(TrixRoomMediaCollector.galleryIndex(of: "missing", in: galleryItems))
    }

    func testIsGalleryItemMatchesGalleryCollectionMembership() {
        let items = [
            Self.item(id: "text", timestamp: 10, attachment: nil),
            Self.item(id: "image", timestamp: 20, attachment: Self.imageAttachment()),
            Self.item(id: "document", timestamp: 30, attachment: Self.fileAttachment()),
            Self.item(
                id: "deleted-image",
                timestamp: 40,
                attachment: Self.imageAttachment(),
                isRetracted: true
            ),
        ]

        let galleryIDs = Set(TrixRoomMediaCollector.galleryItems(in: items).map(\.id))

        for item in items {
            XCTAssertEqual(
                TrixRoomMediaCollector.isGalleryItem(item),
                galleryIDs.contains(item.id),
                "isGalleryItem disagrees with galleryItems membership for \(item.id)"
            )
        }
    }

    // MARK: - Fixtures

    private static func item(
        id: String,
        timestamp: TimeInterval,
        attachment: TrixTimelineAttachment?,
        isRetracted: Bool = false
    ) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: senderID,
            timestamp: Date(timeIntervalSince1970: timestamp),
            body: id,
            isLocalEcho: false,
            attachment: attachment,
            retractionState: isRetracted
                ? TrixTimelineRetractionState(
                    retractedAt: Date(timeIntervalSince1970: timestamp + 1),
                    retractedBy: senderID
                )
                : nil
        )
    }

    private static func imageAttachment(
        filename: String = "photo.jpg",
        mimeType: String? = "image/jpeg",
        sizeBytes: Int? = 2_048,
        sourceJSON: String? = "mock://attachment/photo"
    ) -> TrixTimelineAttachment {
        TrixTimelineAttachment(
            kind: .image,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            sourceJSON: sourceJSON
        )
    }

    private static func stickerAttachment() -> TrixTimelineAttachment {
        TrixTimelineAttachment(
            kind: .sticker,
            filename: "sticker.webp",
            mimeType: "image/webp",
            sizeBytes: 1_024,
            sourceJSON: "mock://attachment/sticker"
        )
    }

    private static func fileAttachment() -> TrixTimelineAttachment {
        TrixTimelineAttachment(
            kind: .file,
            filename: "notes.pdf",
            mimeType: "application/pdf",
            sizeBytes: 4_096,
            sourceJSON: "mock://attachment/file"
        )
    }
}
