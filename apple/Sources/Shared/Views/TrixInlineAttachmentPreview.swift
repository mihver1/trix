import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct TrixInlineAttachmentPreview: View {
    let itemID: String
    let attachment: TrixTimelineAttachment
    let preview: TrixAttachmentDownload?
    let isLoading: Bool
    let failureMessage: String?
    let isOutgoing: Bool
    let open: () -> Void
    let loadPreview: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)

                if let preview {
                    TrixResolvedInlineAttachmentPreview(
                        attachment: attachment,
                        download: preview,
                        isOutgoing: isOutgoing
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(isOutgoing ? .white : TrixDesign.accent)
                } else {
                    Image(systemName: failureMessage == nil ? "photo" : "photo.badge.exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(isOutgoing ? .white.opacity(0.88) : TrixDesign.accent)
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isOutgoing ? Color.white.opacity(0.14) : TrixDesign.surfaceStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!attachment.isDownloadable)
        .accessibilityLabel("Download and preview \(attachment.filename)")
        .task(id: itemID) {
            guard preview == nil,
                  !isLoading,
                  failureMessage == nil else {
                return
            }

            loadPreview()
        }
    }

    private var backgroundColor: Color {
        isOutgoing ? Color.white.opacity(0.14) : TrixDesign.secondarySurface
    }

    private var previewSize: CGSize {
        let maxSize = Self.previewMaxSize
        let aspectRatio = TrixInlineMediaPreviewSupport.aspectRatio(for: attachment)
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

    private static var previewMaxSize: CGSize {
        #if os(macOS)
        CGSize(width: 280, height: 240)
        #else
        CGSize(width: 248, height: 280)
        #endif
    }
}

private struct TrixResolvedInlineAttachmentPreview: View {
    let attachment: TrixTimelineAttachment
    let download: TrixAttachmentDownload
    let isOutgoing: Bool

    var body: some View {
        if TrixInlineMediaPreviewSupport.isAnimatedGIF(
            mimeType: attachment.mimeType,
            filename: attachment.filename
        ) {
            TrixAnimatedInlineImageView(data: download.data)
        } else if let image = platformImage(from: download.data) {
            image
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(isOutgoing ? .white.opacity(0.88) : TrixDesign.accent)
        }
    }

    private func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else {
            return nil
        }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else {
            return nil
        }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}

#if os(iOS)
private struct TrixAnimatedInlineImageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.image = TrixAnimatedInlineImageLoader.animatedImage(from: data)
        imageView.startAnimating()
    }
}
#elseif os(macOS)
private struct TrixAnimatedInlineImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> TrixInlinePreviewImageView {
        TrixInlinePreviewImageView()
    }

    func updateNSView(_ nsView: TrixInlinePreviewImageView, context: Context) {
        nsView.image = NSImage(data: data)
        nsView.animates = true
    }
}

private final class TrixInlinePreviewImageView: NSImageView {
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
#endif

#if os(iOS)
private enum TrixAnimatedInlineImageLoader {
    static func animatedImage(from data: Data) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1 else {
            return UIImage(data: data)
        }

        var images: [UIImage] = []
        images.reserveCapacity(frameCount)
        var totalDuration: TimeInterval = 0

        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
                continue
            }

            images.append(UIImage(cgImage: cgImage))
            totalDuration += frameDuration(for: index, imageSource: imageSource)
        }

        guard !images.isEmpty else {
            return UIImage(data: data)
        }

        return UIImage.animatedImage(
            with: images,
            duration: max(totalDuration, 0.1)
        ) ?? UIImage(data: data)
    }

    private static func frameDuration(
        for index: Int,
        imageSource: CGImageSource
    ) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }

        let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        let resolvedDelay = unclampedDelay ?? delay ?? 0.1
        return resolvedDelay >= 0.011 ? resolvedDelay : 0.1
    }
}
#endif
