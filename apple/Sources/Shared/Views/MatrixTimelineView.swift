import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct MatrixTimelineView: View {
    @ObservedObject var model: MatrixAppModel
    let room: MatrixRoomSummary
    @ObservedObject private var timelineViewModel: TimelineViewModel
    @State private var draft = ""
    @State private var isShowingFileImporter = false
    @State private var fileImportError: String?

    init(model: MatrixAppModel, room: MatrixRoomSummary) {
        self.model = model
        self.room = room
        self._timelineViewModel = ObservedObject(wrappedValue: model.timelineViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if timelineViewModel.isLoading && timelineViewModel.items.isEmpty {
                            ProgressView("Loading timeline")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 54)
                        } else if timelineViewModel.items.isEmpty {
                            MatrixEmptyStateView(
                                title: "No messages",
                                systemImage: "bubble.left.and.text.bubble.right",
                                message: "Messages will appear here after sync."
                            )
                            .padding(.top, 54)
                        }

                        ForEach(timelineViewModel.items) { item in
                            MatrixTimelineRow(
                                item: item,
                                isDownloadingAttachment: timelineViewModel.downloadingAttachmentID == item.id,
                                downloadAttachment: {
                                    Task {
                                        await model.downloadAttachment(for: item)
                                    }
                                }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .matrixScrollDismissesKeyboard()
                .onChange(of: timelineViewModel.items) { _, items in
                    guard let last = items.last else {
                        return
                    }
                    withAnimation(.snappy(duration: 0.24)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let errorMessage = timelineViewModel.errorMessage ?? fileImportError {
                MatrixBannerView(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                Button {
                    fileImportError = nil
                    isShowingFileImporter = true
                } label: {
                    if timelineViewModel.isSendingAttachment {
                        ProgressView()
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MatrixDesign.accent)
                            .frame(width: 38, height: 38)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(timelineViewModel.isSendingAttachment)
                .help("Attach file")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(MatrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MatrixDesign.surfaceStroke, lineWidth: 1)
                    }

                Button {
                    let text = draft
                    draft = ""
                    Task {
                        await model.send(text: text)
                    }
                } label: {
                    if timelineViewModel.isSending {
                        ProgressView()
                    } else {
                        Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "arrow.up.circle" : "arrow.up.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : MatrixDesign.accent)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(timelineViewModel.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .background(MatrixDesign.screenBackground.ignoresSafeArea())
        .navigationTitle(room.name)
        .matrixInlineNavigationTitle()
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            importAttachment(from: result)
        }
        .sheet(
            isPresented: Binding(
                get: { timelineViewModel.downloadedAttachment != nil },
                set: { isPresented in
                    if !isPresented {
                        timelineViewModel.dismissDownloadedAttachment()
                    }
                }
            )
        ) {
            if let attachment = timelineViewModel.downloadedAttachment {
                MatrixAttachmentPreviewView(attachment: attachment)
            }
        }
        .task(id: room.id) {
            await model.selectRoom(room)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            MatrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 44,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MatrixRoomKindMark(kind: room.kind, size: 20)

                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)

                    MatrixRoomSecurityMark(isEncrypted: room.isEncrypted, size: 20)
                }
                Text(room.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task {
                    await model.loadTimeline(roomID: room.id)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh timeline")
        }
    }

    private func importAttachment(from result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }

            let upload = try readAttachmentUpload(from: url)

            Task {
                await model.sendAttachment(upload)
            }
        } catch {
            fileImportError = error.matrixUserFacingMessage
        }
    }

    private func readAttachmentUpload(from url: URL) throws -> MatrixAttachmentUpload {
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        #if os(macOS)
        var coordinatedResult: Result<MatrixAttachmentUpload, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { readableURL in
            coordinatedResult = Result {
                try MatrixAttachmentUpload(
                    fileURL: readableURL,
                    fallbackFilename: url.lastPathComponent
                )
            }
        }

        if let coordinatedResult {
            return try coordinatedResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw MatrixClientError.attachmentTransferFailed
        #else
        return try MatrixAttachmentUpload(fileURL: url)
        #endif
    }
}

private struct MatrixTimelineRow: View {
    let item: MatrixTimelineItem
    let isDownloadingAttachment: Bool
    let downloadAttachment: () -> Void

    var body: some View {
        HStack {
            if item.isLocalEcho {
                Spacer(minLength: 54)
            }

            VStack(alignment: item.isLocalEcho ? .trailing : .leading, spacing: 4) {
                if !item.isLocalEcho {
                    Text(displaySender)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MatrixDesign.accent.opacity(0.88))
                        .padding(.horizontal, 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let attachment = item.attachment {
                        MatrixAttachmentRow(
                            attachment: attachment,
                            isOutgoing: item.isLocalEcho,
                            isDownloading: isDownloadingAttachment,
                            download: downloadAttachment
                        )
                    } else {
                        Text(item.body)
                            .font(.body)
                            .foregroundStyle(item.isLocalEcho ? .white : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            if item.isLocalEcho {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.semibold))
                            }

                            Text(item.timestamp, style: .time)
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(item.isLocalEcho ? .white.opacity(0.82) : .secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: bubbleMaxWidth, alignment: item.isLocalEcho ? .trailing : .leading)
                .background(item.isLocalEcho ? MatrixDesign.accent : MatrixDesign.incomingBubbleSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(item.isLocalEcho ? .clear : MatrixDesign.surfaceStroke, lineWidth: 1)
                }
                .shadow(
                    color: item.isLocalEcho ? MatrixDesign.accent.opacity(0.18) : MatrixDesign.softShadow,
                    radius: item.isLocalEcho ? 12 : 8,
                    y: item.isLocalEcho ? 6 : 4
                )
            }
            .frame(maxWidth: .infinity, alignment: item.isLocalEcho ? .trailing : .leading)

            if !item.isLocalEcho {
                Spacer(minLength: 54)
            }
        }
        .padding(.top, 8)
    }

    private var displaySender: String {
        let localpart = item.sender
            .replacingOccurrences(of: "@", with: "")
            .split(separator: ":")
            .first
            .map(String.init)

        guard let localpart, !localpart.isEmpty else {
            return item.sender
        }

        return localpart.capitalized
    }

    private var bubbleMaxWidth: CGFloat {
        #if os(macOS)
        return 520
        #else
        return 330
        #endif
    }
}

private struct MatrixAttachmentRow: View {
    let attachment: MatrixTimelineAttachment
    let isOutgoing: Bool
    let isDownloading: Bool
    let download: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.18) : MatrixDesign.accent.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    if isDownloading {
                        ProgressView()
                            .tint(isOutgoing ? .white : MatrixDesign.accent)
                    } else {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isOutgoing ? .white : MatrixDesign.accent)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if !attachment.subtitle.isEmpty {
                    Text(attachment.subtitle)
                        .font(.caption)
                        .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
                }
            }

            Spacer()

            Button {
                download()
            } label: {
                Image(systemName: isDownloading ? "hourglass" : "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isOutgoing ? .white : MatrixDesign.accent)
            }
            .buttonStyle(.borderless)
            .disabled(isDownloading || !attachment.isDownloadable)
            .help("Download attachment")
            .accessibilityLabel("Download attachment")
        }
    }
}

private struct MatrixAttachmentPreviewView: View {
    let attachment: MatrixAttachmentDownload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isExporting = false
    @State private var temporaryFileURL: URL?
    @State private var temporaryDirectoryURL: URL?
    @State private var attachmentActionError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if attachment.isImage, let image = platformImage(from: attachment.data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .background(MatrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Label(attachment.filename, systemImage: "doc")
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.filename)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text([attachment.mimeType, attachment.formattedSize].compactMap { $0 }.joined(separator: " - "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        if let temporaryFileURL {
                            openURL(temporaryFileURL)
                        }
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .disabled(temporaryFileURL == nil)

                    if let temporaryFileURL {
                        ShareLink(
                            item: temporaryFileURL,
                            preview: SharePreview(attachment.safeFilename)
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isExporting = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                }
                .labelStyle(.titleAndIcon)

                if let attachmentActionError {
                    Text(attachmentActionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Attachment")
            .matrixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .matrixAttachmentPreviewFrame()
        .task(id: attachment.id) {
            prepareTemporaryFile()
        }
        .onDisappear {
            removeTemporaryFile()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: MatrixAttachmentFileDocument(data: attachment.data),
            contentType: .data,
            defaultFilename: attachment.safeFilename
        ) { result in
            if case .failure(let error) = result {
                attachmentActionError = error.matrixUserFacingMessage
            }
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

    private func prepareTemporaryFile() {
        removeTemporaryFile()
        attachmentActionError = nil

        do {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrixMatrix-\(attachment.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent(attachment.safeFilename, isDirectory: false)
            try attachment.data.write(to: fileURL, options: [.atomic])
            temporaryDirectoryURL = directoryURL
            temporaryFileURL = fileURL
        } catch {
            attachmentActionError = error.matrixUserFacingMessage
        }
    }

    private func removeTemporaryFile() {
        guard let temporaryDirectoryURL else {
            temporaryFileURL = nil
            return
        }

        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        self.temporaryDirectoryURL = nil
        temporaryFileURL = nil
    }
}

private struct MatrixAttachmentFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension MatrixAttachmentDownload {
    var safeFilename: String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        var blockedCharacters = CharacterSet(charactersIn: "/\\:")
        blockedCharacters.formUnion(.controlCharacters)

        let cleaned = trimmed
            .components(separatedBy: blockedCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return isImage ? "attachment-image" : "attachment"
        }

        return cleaned
    }
}

private extension View {
    @ViewBuilder
    func matrixAttachmentPreviewFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 420, minHeight: 320)
        #else
        self
        #endif
    }
}
