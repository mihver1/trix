import CoreGraphics
import AppKit
import Testing
@testable import TrixMac

@MainActor
@Test
func inlineAttachmentPreviewClampsWideImagesToConfiguredBounds() {
    let size = WorkspaceInlineAttachmentPreview.fittedPreviewSize(
        widthPx: 2_400,
        heightPx: 1_200
    )

    #expect(size.width == 280)
    #expect(abs(size.height - (280 / 1.8)) < 0.001)
}

@MainActor
@Test
func inlineAttachmentPreviewClampsTallImagesToConfiguredBounds() {
    let size = WorkspaceInlineAttachmentPreview.fittedPreviewSize(
        widthPx: 800,
        heightPx: 3_200
    )

    #expect(size.height == 240)
    #expect(abs(size.width - (240 * 0.5)) < 0.001)
}

@MainActor
@Test
func inlineAttachmentPreviewFallsBackToDefaultAspectRatioWhenMetadataIsMissing() {
    let size = WorkspaceInlineAttachmentPreview.fittedPreviewSize(
        widthPx: nil,
        heightPx: nil
    )

    #expect(size.width == 280)
    #expect(size.height == 210)
}

@MainActor
@Test
func inlineAttachmentPreviewImageViewDoesNotExposeImageIntrinsicSize() {
    let imageView = WorkspacePreviewImageView()
    let image = NSImage(size: NSSize(width: 1_200, height: 900))

    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()

    imageView.image = image

    #expect(imageView.intrinsicContentSize == .zero)
    #expect(imageView.contentHuggingPriority(for: .horizontal) == .defaultLow)
    #expect(imageView.contentHuggingPriority(for: .vertical) == .defaultLow)
    #expect(imageView.contentCompressionResistancePriority(for: .horizontal) == .defaultLow)
    #expect(imageView.contentCompressionResistancePriority(for: .vertical) == .defaultLow)
}
