import AppKit
import SwiftUI

struct WorkspaceInlineAttachmentPreview: View {
    static let previewMaxSize = CGSize(width: 280, height: 240)
    static let fallbackPreviewAspectRatio: CGFloat = 4 / 3
    static let minPreviewAspectRatio: CGFloat = 0.5
    static let maxPreviewAspectRatio: CGFloat = 1.8

    @Environment(\.trixColors) private var colors
    @ObservedObject var model: AppModel
    let message: LocalTimelineItem
    let attachmentBody: TypedMessageBody
    let openAttachment: (() -> Void)?

    @State private var previewURL: URL?
    @State private var didAttemptLoad = false

    var bodyView: some View {
        Group {
            if let previewURL {
                previewContainer {
                    WorkspaceAnimatedImageView(fileURL: previewURL)
                }
            } else {
                previewContainer {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(colors.tileFill)

                        if didAttemptLoad {
                            Image(systemName: "photo")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(colors.accent)
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
        }
        .task(id: message.messageId) {
            guard LocalImageAttachmentSupport.supports(
                mimeType: attachmentBody.mimeType,
                fileName: attachmentBody.fileName
            ) else {
                didAttemptLoad = true
                return
            }
            guard previewURL == nil else {
                return
            }

            if let cachedURL = model.cachedAttachmentURL(for: message.messageId) {
                previewURL = cachedURL
                didAttemptLoad = true
                return
            }

            previewURL = await model.ensureCachedAttachmentURL(for: message)
            didAttemptLoad = true
        }
    }

    var body: some View {
        bodyView
            .frame(width: previewDisplaySize.width, height: previewDisplaySize.height)
    }

    private var previewDisplaySize: CGSize {
        Self.fittedPreviewSize(
            widthPx: attachmentBody.widthPx,
            heightPx: attachmentBody.heightPx
        )
    }

    static func previewAspectRatio(widthPx: UInt32?, heightPx: UInt32?) -> CGFloat {
        guard
            let widthPx,
            let heightPx,
            widthPx > 0,
            heightPx > 0
        else {
            return fallbackPreviewAspectRatio
        }

        let ratio = CGFloat(widthPx) / CGFloat(heightPx)
        return min(max(ratio, minPreviewAspectRatio), maxPreviewAspectRatio)
    }

    static func fittedPreviewSize(
        widthPx: UInt32?,
        heightPx: UInt32?,
        maxSize: CGSize = previewMaxSize
    ) -> CGSize {
        let aspectRatio = previewAspectRatio(widthPx: widthPx, heightPx: heightPx)
        var fittedSize = CGSize(
            width: maxSize.width,
            height: maxSize.width / aspectRatio
        )

        if fittedSize.height > maxSize.height {
            fittedSize = CGSize(
                width: maxSize.height * aspectRatio,
                height: maxSize.height
            )
        }

        return fittedSize
    }

    @ViewBuilder
    private func previewContainer<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let openAttachment {
            Button(action: openAttachment) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(colors.outline, lineWidth: 1)
            }
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(colors.outline, lineWidth: 1)
                }
        }
    }
}

private struct WorkspaceAnimatedImageView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WorkspacePreviewImageView {
        let imageView = WorkspacePreviewImageView()
        return imageView
    }

    func updateNSView(_ nsView: WorkspacePreviewImageView, context: Context) {
        nsView.image = NSImage(contentsOf: fileURL)
        nsView.animates = true
    }
}

final class WorkspacePreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize { .zero }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        animates = true
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
