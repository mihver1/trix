import CoreGraphics
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
