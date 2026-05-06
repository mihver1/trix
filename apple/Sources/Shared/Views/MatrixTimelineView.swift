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
                .padding(16)
                .background(.regularMaterial)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if timelineViewModel.isLoading {
                            ProgressView("Loading timeline")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 32)
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
                    .padding(16)
                }
                .onChange(of: timelineViewModel.items) { _, items in
                    guard let last = items.last else {
                        return
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }

            if let errorMessage = timelineViewModel.errorMessage ?? fileImportError {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    fileImportError = nil
                    isShowingFileImporter = true
                } label: {
                    if timelineViewModel.isSendingAttachment {
                        ProgressView()
                    } else {
                        Image(systemName: "paperclip")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(timelineViewModel.isSendingAttachment)
                .help("Attach file")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

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
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(timelineViewModel.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send message")
            }
            .padding(16)
        }
        .navigationTitle(room.name)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.data],
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
            await model.loadTimeline(roomID: room.id)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.title2.weight(.semibold))
                    if room.isEncrypted {
                        Label("Encrypted", systemImage: "lock.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Text(room.subtitle)
                    .foregroundStyle(.secondary)
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

            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
            let data = try Data(contentsOf: url)
            let mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
            let upload = MatrixAttachmentUpload(
                filename: url.lastPathComponent,
                mimeType: mimeType,
                data: data
            )

            Task {
                await model.sendAttachment(upload)
            }
        } catch {
            fileImportError = error.matrixUserFacingMessage
        }
    }
}

private struct MatrixTimelineRow: View {
    let item: MatrixTimelineItem
    let isDownloadingAttachment: Bool
    let downloadAttachment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.sender)
                    .font(.caption.weight(.semibold))
                Text(item.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.isLocalEcho {
                    Text("sent")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let attachment = item.attachment {
                MatrixAttachmentRow(
                    attachment: attachment,
                    isDownloading: isDownloadingAttachment,
                    download: downloadAttachment
                )
            } else {
                Text(item.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(item.isLocalEcho ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 680, alignment: .leading)
    }
}

private struct MatrixAttachmentRow: View {
    let attachment: MatrixTimelineAttachment
    let isDownloading: Bool
    let download: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)

                if !attachment.subtitle.isEmpty {
                    Text(attachment.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                download()
            } label: {
                if isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isDownloading || !attachment.isDownloadable)
            .help("Download attachment")
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
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
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
