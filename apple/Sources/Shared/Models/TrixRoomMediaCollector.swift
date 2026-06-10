import Foundation

/// Pure helper that derives a room's shared-media collections from timeline items.
///
/// Used by the macOS inspector "Shared Media" section and by the full-screen
/// media gallery on both platforms so that both surfaces agree on membership,
/// ordering, and positioning.
enum TrixRoomMediaCollector {
    /// Every non-retracted attachment item (images, stickers, and files),
    /// ordered by timestamp ascending with a stable identifier tie-break.
    static func attachmentItems(in items: [TrixTimelineItem]) -> [TrixTimelineItem] {
        collect(items) { _ in true }
    }

    /// Image-kind attachment items that the full-screen gallery can display,
    /// ordered by timestamp ascending with a stable identifier tie-break.
    ///
    /// Membership intentionally matches the timeline's inline image preview
    /// gate (`TrixInlineMediaPreviewSupport.canAttemptInlinePreview`) so that
    /// every tappable inline image opens inside the gallery and the gallery
    /// never contains an item the existing preview pipeline cannot decrypt.
    static func galleryItems(in items: [TrixTimelineItem]) -> [TrixTimelineItem] {
        collect(items, isIncluded: isGalleryAttachment)
    }

    /// Whether a single timeline item belongs to the gallery collection.
    static func isGalleryItem(_ item: TrixTimelineItem) -> Bool {
        guard !item.isRetracted, let attachment = item.attachment else {
            return false
        }

        return isGalleryAttachment(attachment)
    }

    /// Position of an item inside an already-collected gallery collection.
    static func galleryIndex(of itemID: String, in galleryItems: [TrixTimelineItem]) -> Int? {
        galleryItems.firstIndex { $0.id == itemID }
    }

    private static func isGalleryAttachment(_ attachment: TrixTimelineAttachment) -> Bool {
        TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment)
    }

    private static func collect(
        _ items: [TrixTimelineItem],
        isIncluded: (TrixTimelineAttachment) -> Bool
    ) -> [TrixTimelineItem] {
        items
            .filter { item in
                guard !item.isRetracted, let attachment = item.attachment else {
                    return false
                }

                return isIncluded(attachment)
            }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }

                return lhs.id < rhs.id
            }
    }
}
