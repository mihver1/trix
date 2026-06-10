import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Identifies which room media item the full-screen gallery should open on.
struct TrixMediaGalleryContext: Identifiable, Equatable {
    let roomID: String
    let initialItemID: String

    var id: String {
        "\(roomID)|\(initialItemID)"
    }
}

extension View {
    /// Presents the media gallery full screen on iOS and as a large sheet on macOS.
    @MainActor
    @ViewBuilder
    func trixMediaGalleryPresentation(
        item: Binding<TrixMediaGalleryContext?>,
        model: TrixAppModel
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item) { context in
            TrixMediaGalleryView(model: model, context: context)
        }
        #else
        self.sheet(item: item) { context in
            TrixMediaGalleryView(model: model, context: context)
        }
        #endif
    }
}

/// Full-screen viewer for a room's image attachments.
///
/// Media bytes come exclusively from the existing decrypted in-memory previews
/// (`TimelineViewModel.inlineAttachmentPreviews`); missing neighbors are loaded
/// lazily through `TrixAppModel.loadInlineAttachmentPreview`, which consults the
/// encrypted media cache before downloading. Decrypted bytes only touch disk
/// for the currently shown item's temporary share file and user-invoked exports,
/// mirroring the existing attachment preview flow.
struct TrixMediaGalleryView: View {
    @ObservedObject var model: TrixAppModel
    @ObservedObject private var timelineViewModel: TimelineViewModel
    private let roomID: String
    @State private var currentItemID: String
    @State private var temporaryShareFileURL: URL?
    @State private var temporaryShareDirectoryURL: URL?
    @State private var isExporting = false
    @State private var actionErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @FocusState private var isKeyboardFocused: Bool
    #endif

    init(model: TrixAppModel, context: TrixMediaGalleryContext) {
        self.model = model
        self._timelineViewModel = ObservedObject(wrappedValue: model.timelineViewModel)
        self.roomID = context.roomID
        self._currentItemID = State(initialValue: context.initialItemID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if galleryItems.isEmpty {
                ContentUnavailableView(
                    "No Media",
                    systemImage: "photo.on.rectangle",
                    description: Text("This chat has no viewable images.")
                )
                .foregroundStyle(.white)
            } else {
                galleryContent
            }
        }
        .overlay(alignment: .top) {
            topBar
        }
        .overlay(alignment: .bottom) {
            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 18)
            }
        }
        .task(id: currentItemID) {
            await loadCurrentNeighborhood()
        }
        .task(id: shareMaterializationKey) {
            prepareTemporaryShareFile()
        }
        .onChange(of: galleryItemIDs) { _, itemIDs in
            reconcileSelection(with: itemIDs)
        }
        .onDisappear {
            removeTemporaryShareFile()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TrixMediaGalleryFileDocument(data: currentDownload?.data ?? Data()),
            contentType: .data,
            defaultFilename: currentDownload?.trixGallerySafeFilename ?? "attachment-image"
        ) { result in
            if case .failure(let error) = result {
                actionErrorMessage = error.trixUserFacingMessage
            }
        }
        #if os(macOS)
        .frame(
            minWidth: 840,
            idealWidth: 1020,
            maxWidth: .infinity,
            minHeight: 580,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .focusable()
        .focusEffectDisabled()
        .focused($isKeyboardFocused)
        .onKeyPress(.leftArrow) {
            navigate(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigate(by: 1)
            return .handled
        }
        .onExitCommand {
            dismiss()
        }
        .task {
            isKeyboardFocused = true
        }
        #endif
        .tint(TrixDesign.accent)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Collection state

    private var galleryItems: [TrixTimelineItem] {
        guard timelineViewModel.roomID == roomID else {
            return []
        }

        return TrixRoomMediaCollector.galleryItems(in: timelineViewModel.items)
    }

    private var galleryItemIDs: [String] {
        galleryItems.map(\.id)
    }

    private var currentIndex: Int? {
        TrixRoomMediaCollector.galleryIndex(of: currentItemID, in: galleryItems)
    }

    private var currentItem: TrixTimelineItem? {
        guard let currentIndex else {
            return nil
        }

        return galleryItems[currentIndex]
    }

    private var currentDownload: TrixAttachmentDownload? {
        timelineViewModel.inlineAttachmentPreviews[currentItemID]
    }

    private var shareMaterializationKey: String {
        "\(currentItemID)|\(currentDownload?.id.uuidString ?? "pending")"
    }

    // MARK: - Content

    @ViewBuilder
    private var galleryContent: some View {
        #if os(iOS)
        TabView(selection: $currentItemID) {
            ForEach(galleryItems) { item in
                Group {
                    if let attachment = item.attachment {
                        TrixMediaGalleryZoomablePage(
                            attachment: attachment,
                            download: timelineViewModel.inlineAttachmentPreviews[item.id],
                            isLoading: timelineViewModel.inlineAttachmentPreviewLoadingIDs.contains(item.id),
                            failureMessage: timelineViewModel.inlineAttachmentPreviewFailures[item.id],
                            requestDismiss: { dismiss() }
                        )
                    }
                }
                .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        ZStack {
            if let item = currentItem, let attachment = item.attachment {
                TrixMediaGalleryItemContent(
                    attachment: attachment,
                    download: timelineViewModel.inlineAttachmentPreviews[item.id],
                    isLoading: timelineViewModel.inlineAttachmentPreviewLoadingIDs.contains(item.id),
                    failureMessage: timelineViewModel.inlineAttachmentPreviewFailures[item.id]
                )
                .padding(.vertical, 64)
                .padding(.horizontal, 72)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            navigationChevron(systemImage: "chevron.left", delta: -1, label: "Previous image")
                .padding(.leading, 16)
        }
        .overlay(alignment: .trailing) {
            navigationChevron(systemImage: "chevron.right", delta: 1, label: "Next image")
                .padding(.trailing, 16)
        }
        #endif
    }

    #if os(macOS)
    private func navigationChevron(systemImage: String, delta: Int, label: String) -> some View {
        Button {
            navigate(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.13), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate(by: delta))
        .opacity(canNavigate(by: delta) ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }
    #endif

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.13), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close media gallery")

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                Text(currentTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let currentIndex {
                    Text("\(currentIndex + 1) of \(galleryItems.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            shareControl

            Button {
                actionErrorMessage = nil
                isExporting = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.13), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentDownload == nil)
            .opacity(currentDownload == nil ? 0.4 : 1)
            .help("Save a decrypted copy")
            .accessibilityLabel("Save image to a file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var shareControl: some View {
        if let temporaryShareFileURL, let currentDownload {
            ShareLink(
                item: temporaryShareFileURL,
                preview: SharePreview(currentDownload.trixGallerySafeFilename)
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.13), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Share")
            .accessibilityLabel("Share image")
        } else {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.07), in: Circle())
                .accessibilityLabel("Share is unavailable until the image is downloaded")
        }
    }

    private var currentTitle: String {
        guard let attachment = currentItem?.attachment else {
            return "Media"
        }

        if attachment.isSticker {
            return attachment.stickerMetadata?.packTitle ?? "Sticker"
        }

        return attachment.filename
    }

    // MARK: - Navigation

    private func canNavigate(by delta: Int) -> Bool {
        guard let currentIndex else {
            return false
        }

        return galleryItems.indices.contains(currentIndex + delta)
    }

    private func navigate(by delta: Int) {
        guard let currentIndex, galleryItems.indices.contains(currentIndex + delta) else {
            return
        }

        currentItemID = galleryItems[currentIndex + delta].id
    }

    private func reconcileSelection(with itemIDs: [String]) {
        guard !itemIDs.contains(currentItemID), let fallbackItemID = itemIDs.last else {
            return
        }

        currentItemID = fallbackItemID
    }

    // MARK: - Lazy loading

    private func loadCurrentNeighborhood() async {
        let items = galleryItems
        guard let index = TrixRoomMediaCollector.galleryIndex(of: currentItemID, in: items) else {
            return
        }

        for offset in [0, 1, -1] {
            let neighborIndex = index + offset
            guard items.indices.contains(neighborIndex) else {
                continue
            }

            await model.loadInlineAttachmentPreview(for: items[neighborIndex])
        }
    }

    // MARK: - Share / export

    private func prepareTemporaryShareFile() {
        removeTemporaryShareFile()

        guard let currentDownload else {
            return
        }

        do {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Trix-Gallery-\(currentDownload.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent(
                currentDownload.trixGallerySafeFilename,
                isDirectory: false
            )
            try currentDownload.data.write(to: fileURL, options: [.atomic])
            temporaryShareDirectoryURL = directoryURL
            temporaryShareFileURL = fileURL
        } catch {
            actionErrorMessage = error.trixUserFacingMessage
        }
    }

    private func removeTemporaryShareFile() {
        guard let temporaryShareDirectoryURL else {
            temporaryShareFileURL = nil
            return
        }

        try? FileManager.default.removeItem(at: temporaryShareDirectoryURL)
        self.temporaryShareDirectoryURL = nil
        temporaryShareFileURL = nil
    }
}

// MARK: - Item content

/// Renders one gallery item: the decrypted image when available, otherwise the
/// matching loading / failure / queued placeholder.
private struct TrixMediaGalleryItemContent: View {
    let attachment: TrixTimelineAttachment
    let download: TrixAttachmentDownload?
    let isLoading: Bool
    let failureMessage: String?

    var body: some View {
        if let download, let image = TrixMediaGalleryImageLoader.image(from: download.data) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Image \(attachment.filename)")
        } else {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text("Loading encrypted media")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                } else if let failureMessage {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.orange)

                    Text(failureMessage)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("Waiting to download")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if os(iOS)
/// iOS gallery page with pinch-to-zoom, double-tap zoom, pan while zoomed,
/// and drag-down to dismiss while not zoomed.
private struct TrixMediaGalleryZoomablePage: View {
    let attachment: TrixTimelineAttachment
    let download: TrixAttachmentDownload?
    let isLoading: Bool
    let failureMessage: String?
    let requestDismiss: () -> Void

    @State private var steadyZoom: CGFloat = 1
    @GestureState private var pinchMagnification: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var steadyPanOffset: CGSize = .zero
    @State private var dismissDragOffset: CGFloat = 0

    private static let maxZoom: CGFloat = 5
    private static let doubleTapZoom: CGFloat = 2.5
    private static let dismissThreshold: CGFloat = 130

    private var zoomScale: CGFloat {
        min(max(steadyZoom * pinchMagnification, 1), Self.maxZoom)
    }

    var body: some View {
        TrixMediaGalleryItemContent(
            attachment: attachment,
            download: download,
            isLoading: isLoading,
            failureMessage: failureMessage
        )
        .scaleEffect(zoomScale)
        .offset(
            x: panOffset.width,
            y: panOffset.height + dismissDragOffset
        )
        .contentShape(Rectangle())
        .gesture(magnifyGesture)
        .simultaneousGesture(panOrDismissGesture)
        .onTapGesture(count: 2) {
            toggleDoubleTapZoom()
        }
        .onDisappear {
            resetTransientState()
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchMagnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                steadyZoom = min(max(steadyZoom * value.magnification, 1), Self.maxZoom)
                if steadyZoom <= 1.01 {
                    resetZoom()
                }
            }
    }

    private var panOrDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if zoomScale > 1.01 {
                    panOffset = CGSize(
                        width: steadyPanOffset.width + value.translation.width,
                        height: steadyPanOffset.height + value.translation.height
                    )
                } else if abs(value.translation.height) > abs(value.translation.width) {
                    dismissDragOffset = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if zoomScale > 1.01 {
                    steadyPanOffset = panOffset
                } else if dismissDragOffset > Self.dismissThreshold {
                    dismissDragOffset = 0
                    requestDismiss()
                } else {
                    withAnimation(.spring(duration: 0.25)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    private func toggleDoubleTapZoom() {
        withAnimation(.spring(duration: 0.28)) {
            if steadyZoom > 1.01 {
                resetZoom()
            } else {
                steadyZoom = Self.doubleTapZoom
            }
        }
    }

    private func resetZoom() {
        steadyZoom = 1
        panOffset = .zero
        steadyPanOffset = .zero
    }

    private func resetTransientState() {
        resetZoom()
        dismissDragOffset = 0
    }
}
#endif

// MARK: - Helpers

private enum TrixMediaGalleryImageLoader {
    static func image(from data: Data) -> Image? {
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

private struct TrixMediaGalleryFileDocument: FileDocument {
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

private extension TrixAttachmentDownload {
    var trixGallerySafeFilename: String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        var blockedCharacters = CharacterSet(charactersIn: "/\\:")
        blockedCharacters.formUnion(.controlCharacters)

        let cleaned = trimmed
            .components(separatedBy: blockedCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "attachment-image"
        }

        return cleaned
    }
}
