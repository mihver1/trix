import AppKit
import SwiftUI

struct WorkspaceInlineAttachmentPreview: View {
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
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            .frame(maxWidth: 280, maxHeight: 240)
    }

    private var previewAspectRatio: CGFloat {
        guard
            let widthPx = attachmentBody.widthPx,
            let heightPx = attachmentBody.heightPx,
            widthPx > 0,
            heightPx > 0
        else {
            return 4 / 3
        }

        let ratio = CGFloat(widthPx) / CGFloat(heightPx)
        return min(max(ratio, 0.5), 1.8)
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

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(contentsOf: fileURL)
        nsView.animates = true
    }
}
