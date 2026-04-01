import ImageIO
import SwiftUI
import UIKit

private let consumerInlineAttachmentPreviewAccent = TrixTheme.accent

enum ConsumerInlineAttachmentPreviewSupport {
    private static let previewableExtensions: Set<String> = [
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "webp",
    ]

    static func supports(_ attachment: SafeMessengerAttachment?) -> Bool {
        guard let attachment else {
            return false
        }

        let normalizedMimeType = attachment.mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedMimeType.hasPrefix("image/") {
            return true
        }

        return fileExtension(for: attachment).map(previewableExtensions.contains) ?? false
    }

    static func isAnimated(_ attachment: SafeMessengerAttachment) -> Bool {
        if attachment.mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "image/gif" {
            return true
        }

        return fileExtension(for: attachment) == "gif"
    }

    static func aspectRatio(for attachment: SafeMessengerAttachment) -> CGFloat {
        guard
            let widthPx = attachment.widthPx,
            let heightPx = attachment.heightPx,
            widthPx > 0,
            heightPx > 0
        else {
            return 4 / 3
        }

        let ratio = CGFloat(widthPx) / CGFloat(heightPx)
        return min(max(ratio, 0.5), 1.8)
    }

    private static func fileExtension(for attachment: SafeMessengerAttachment) -> String? {
        attachment.fileName?
            .split(separator: ".")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ConsumerInlineAttachmentPreview: View {
    let model: AppModel
    let serverBaseURLString: String
    let attachment: SafeMessengerAttachment
    let isOutgoing: Bool

    @State private var previewFile: DownloadedAttachmentFile?
    @State private var didAttemptLoad = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.14) : TrixTheme.secondarySurface)

            if let previewFile {
                ConsumerResolvedInlineAttachmentPreview(
                    fileURL: previewFile.fileURL,
                    attachment: attachment
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didAttemptLoad {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isOutgoing ? .white.opacity(0.88) : consumerInlineAttachmentPreviewAccent)
            } else {
                ProgressView()
                    .tint(isOutgoing ? .white : consumerInlineAttachmentPreviewAccent)
            }
        }
        .aspectRatio(ConsumerInlineAttachmentPreviewSupport.aspectRatio(for: attachment), contentMode: .fit)
        .frame(maxWidth: 248, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isOutgoing ? Color.white.opacity(0.12) : TrixTheme.surfaceStroke, lineWidth: 1)
        }
        .task(id: attachment.attachmentRef) {
            guard ConsumerInlineAttachmentPreviewSupport.supports(attachment) else {
                didAttemptLoad = true
                return
            }
            guard previewFile == nil else {
                return
            }

            previewFile = await model.inlinePreviewAttachmentFile(
                baseURLString: serverBaseURLString,
                attachment: attachment
            )
            didAttemptLoad = true
        }
    }
}

private struct ConsumerResolvedInlineAttachmentPreview: View {
    let fileURL: URL
    let attachment: SafeMessengerAttachment

    var body: some View {
        if ConsumerInlineAttachmentPreviewSupport.isAnimated(attachment) {
            ConsumerAnimatedGIFImageView(fileURL: fileURL)
        } else if let image = UIImage(contentsOfFile: fileURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(consumerInlineAttachmentPreviewAccent)
        }
    }
}

private struct ConsumerAnimatedGIFImageView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.image = ConsumerAnimatedImageLoader.animatedImage(at: fileURL)
        imageView.startAnimating()
    }
}

private enum ConsumerAnimatedImageLoader {
    static func animatedImage(at fileURL: URL) -> UIImage? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return UIImage(contentsOfFile: fileURL.path)
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
