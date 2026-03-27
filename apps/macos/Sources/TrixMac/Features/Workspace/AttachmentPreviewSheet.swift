import QuickLookUI
import SwiftUI

enum LocalImageAttachmentSupport {
    private static let mimeTypes: Set<String> = [
        "image/jpeg",
        "image/jpg",
        "image/png",
        "image/gif",
        "image/webp",
        "image/heif",
        "image/heic",
        "image/heif-sequence",
        "image/heic-sequence",
    ]

    private static let fileExtensions: Set<String> = [
        "jpg",
        "jpeg",
        "png",
        "gif",
        "webp",
        "heif",
        "heic",
    ]

    static func supports(mimeType: String?, fileName: String?) -> Bool {
        if let normalizedMimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           mimeTypes.contains(normalizedMimeType) {
            return true
        }

        if let fileName {
            let fileExtension = URL(fileURLWithPath: fileName)
                .pathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if fileExtensions.contains(fileExtension) {
                return true
            }
        }

        if let fileName,
           fileExtensions.contains(fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }

        return false
    }
}

struct AttachmentPreviewSheet: View {
    let attachment: PreviewedAttachmentFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.fileName)
                        .font(.headline)
                        .lineLimit(1)

                    if let mimeType = attachment.mimeType, !mimeType.isEmpty {
                        Text(mimeType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            AttachmentQuickLookView(attachment: attachment)
                .frame(minWidth: 720, minHeight: 540)
        }
    }
}

private struct AttachmentQuickLookView: NSViewRepresentable {
    let attachment: PreviewedAttachmentFile

    func makeNSView(context: Context) -> QLPreviewView {
        let previewView = QLPreviewView(frame: .zero, style: .normal)!
        previewView.autostarts = true
        previewView.previewItem = attachment.fileURL as NSURL
        return previewView
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = attachment.fileURL as NSURL
    }
}
