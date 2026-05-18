import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
private typealias TrixPlatformPasteImage = UIImage
#elseif os(macOS)
import AppKit
private typealias TrixPlatformPasteImage = NSImage
#endif

private enum TrixAttachmentImportError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let message):
            return message
        }
    }
}

struct TrixTimelineView: View {
    @ObservedObject var model: TrixAppModel
    let room: TrixRoomSummary
    @ObservedObject private var timelineViewModel: TimelineViewModel
    @State private var draft = ""
    @State private var isShowingFileImporter = false
    @State private var isShowingDeviceTrust = false
    @State private var isShowingGroupMembers = false
    @State private var isLoadingPeerDevices = false
    @State private var peerDevices: [TrixPeerDeviceIdentity] = []
    @State private var peerDeviceError: String?
    @State private var isLoadingGroupDevices = false
    @State private var groupDeviceEntries: [TrixGroupDeviceTrustEntry] = []
    @State private var groupDeviceError: String?
    @State private var fileImportError: String?
    @State private var typingPauseTask: Task<Void, Never>?
    @State private var lastSentTypingState: TrixTypingState = .idle
    @State private var isShowingLocalForgetConfirmation = false
    @State private var isShowingGroupLeaveConfirmation = false
    @State private var isShowingStickerPicker = false
    @State private var isAttachmentDropTargeted = false

    init(model: TrixAppModel, room: TrixRoomSummary) {
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

            if let progress = visibleLoadProgress, !visibleTimelineItems.isEmpty {
                timelineLoadProgressBar(progress)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if visibleTimelineItems.isEmpty {
                            timelineEmptyState
                                .padding(.top, 54)
                        }

                        ForEach(timelineEntries) { entry in
                            switch entry {
                            case .daySeparator(let id, let date):
                                TrixTimelineDaySeparator(date: date)
                                    .id(id)
                            case .message(let presentation):
                                TrixTimelineRow(
                                    presentation: presentation,
                                    isDownloadingAttachment: timelineViewModel.downloadingAttachmentID == presentation.item.id,
                                    attachmentFailure: timelineViewModel.attachmentDownloadFailures[presentation.item.id],
                                    inlineAttachmentPreview: timelineViewModel.inlineAttachmentPreviews[presentation.item.id],
                                    isLoadingInlineAttachmentPreview: timelineViewModel.inlineAttachmentPreviewLoadingIDs.contains(presentation.item.id),
                                    inlineAttachmentPreviewFailure: timelineViewModel.inlineAttachmentPreviewFailures[presentation.item.id],
                                    isReacting: timelineViewModel.reactionActionMessageID == presentation.item.id,
                                    downloadAttachment: {
                                        Task {
                                            await model.downloadAttachment(for: presentation.item)
                                        }
                                    },
                                    loadInlineAttachmentPreview: {
                                        Task {
                                            await model.loadInlineAttachmentPreview(for: presentation.item)
                                        }
                                    },
                                    react: { emoji in
                                        Task {
                                            await model.setReaction(emoji, for: presentation.item)
                                        }
                                    },
                                    addStickerPack: { metadata in
                                        Task {
                                            await model.importStickerPack(from: metadata)
                                        }
                                    }
                                )
                                .id(presentation.item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .trixScrollDismissesKeyboard()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    timelineBottomControls
                }
                .onChange(of: timelineViewModel.items) { _, items in
                    guard timelineViewModel.roomID == room.id else {
                        return
                    }
                    guard let last = items.last else {
                        return
                    }
                    withAnimation(.snappy(duration: 0.24)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(TrixDesign.screenBackground.ignoresSafeArea())
        .overlay {
            if isAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(TrixDesign.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .trixAttachmentPasteCommand { providers in
            _ = importAttachment(from: providers)
        }
        .onDrop(
            of: Self.attachmentImportTypeIdentifiers,
            isTargeted: $isAttachmentDropTargeted
        ) { providers in
            importAttachment(from: providers)
        }
        .navigationTitle(room.name)
        .trixInlineNavigationTitle()
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
                TrixAttachmentPreviewView(attachment: attachment)
            }
        }
        .sheet(isPresented: $isShowingDeviceTrust) {
            if room.kind == .group {
                TrixGroupDeviceTrustView(
                    roomName: room.name,
                    entries: groupDeviceEntries,
                    isLoading: isLoadingGroupDevices,
                    errorMessage: groupDeviceError,
                    refresh: {
                        Task {
                            await loadGroupDevices(refresh: true)
                        }
                    },
                    trust: { device in
                        Task {
                            await trustGroupDevice(device)
                        }
                    }
                )
            } else {
                TrixPeerDeviceTrustView(
                    roomName: room.name,
                    devices: peerDevices,
                    isLoading: isLoadingPeerDevices,
                    errorMessage: peerDeviceError,
                    refresh: {
                        Task {
                            await loadPeerDevices(refresh: true)
                        }
                    },
                    trust: { device in
                        Task {
                            await trustPeerDevice(device)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingGroupMembers) {
            TrixGroupMembersView(model: model, room: room)
        }
        .sheet(isPresented: $isShowingStickerPicker) {
            TrixStickerPickerView(
                model: model,
                canSendStickers: canSendEncryptedAttachments,
                sendSticker: { sticker in
                    Task {
                        await model.sendSticker(sticker)
                    }
                },
                importTelegramPack: { reference in
                    Task {
                        await model.importTelegramStickerPack(reference)
                    }
                }
            )
        }
        .confirmationDialog(
            "Forget this DM locally?",
            isPresented: $isShowingLocalForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Locally", role: .destructive) {
                model.forgetRoomLocally(room)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the room from local navigation state only. It does not delete the conversation for the other account.")
        }
        .confirmationDialog(
            "Leave this group locally?",
            isPresented: $isShowingGroupLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Locally", role: .destructive) {
                model.forgetRoomLocally(room)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A server-backed MUC leave is still blocked in this client slice. This only hides local room state and does not destroy the group.")
        }
        .task(id: room.id) {
            resetDeviceTrustState()
            if timelineViewModel.roomID != room.id {
                await model.selectRoom(room)
            }
            await loadPeerDevices(refresh: false)
            await model.loadAttachmentSendAvailability(roomID: room.id)
        }
        .task(id: "typing-\(room.id)") {
            while !Task.isCancelled {
                await model.loadTypingState(roomID: room.id)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: draft) { _, newValue in
            handleDraftChange(newValue)
        }
        .onDisappear {
            typingPauseTask?.cancel()
            sendTypingStateIfNeeded(.paused)
        }
    }

    private var canSendEncrypted: Bool {
        if room.kind == .group,
           let availability = currentAttachmentSendAvailability {
            return availability.canSend
        }

        return room.isEncrypted || peerDevices.contains(where: \.canSendEncrypted)
    }

    private var currentAttachmentSendAvailability: TrixAttachmentSendAvailability? {
        guard let availability = timelineViewModel.attachmentSendAvailability,
              availability.roomID == room.id else {
            return nil
        }

        return availability
    }

    private var timelineBottomControls: some View {
        VStack(spacing: 0) {
            if !timelineViewModel.typingUserIDs.isEmpty {
                typingIndicator
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let errorMessage = timelineViewModel.errorMessage ?? fileImportError {
                TrixBannerView(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let stickerImportMessage = model.stickerImportMessage {
                TrixBannerView(
                    text: stickerImportMessage,
                    systemImage: "face.smiling",
                    tint: TrixDesign.accent
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !canSendEncrypted {
                encryptionRequiredBanner
            }

            if let attachmentBlockMessage {
                TrixBannerView(
                    text: attachmentBlockMessage,
                    systemImage: "paperclip.badge.ellipsis",
                    tint: .orange
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            composer
        }
        .frame(maxWidth: .infinity)
    }

    private func timelineLoadProgressBar(_ progress: TrixTimelineLoadProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)
            Text(progress.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private var encryptionRequiredBanner: some View {
        HStack(spacing: 10) {
            TrixBannerView(
                text: encryptionRequiredMessage,
                systemImage: "lock.slash.fill",
                tint: .orange
            )
            .layoutPriority(1)

            Button {
                showDeviceTrust()
            } label: {
                Image(systemName: "checkmark.shield")
            }
            .buttonStyle(.bordered)
            .help("Review OMEMO devices")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var encryptionRequiredMessage: String {
        if room.kind == .group,
           let reason = currentAttachmentSendAvailability?.blockReason {
            switch reason {
            case .groupRecipientSetUnavailable:
                return "Trix needs a validated member recipient set before sending encrypted group messages."
            case .groupOmemoDeviceTrustRequired:
                return "Trust an active OMEMO device for every group member before sending."
            case .omemoDeviceTrustRequired:
                return "Trust an active OMEMO device for every group member before sending."
            case .unavailable:
                return "Encrypted group messages are not available for this room yet."
            }
        }

        return "OMEMO is required for Trix chats. Trust a contact device before sending."
    }

    private var composer: some View {
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
                        .foregroundStyle(TrixDesign.accent)
                        .frame(width: 38, height: 38)
                }
            }
            .buttonStyle(.borderless)
            .disabled(timelineViewModel.isSendingAttachment || !canSendEncryptedAttachments)
            .help(attachmentHelpText)

            Button {
                isShowingStickerPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TrixDesign.accent)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .help("Stickers")

            TextField(canSendEncrypted ? "Message" : "OMEMO required", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                }
                .layoutPriority(1)
                .trixMacComposerReturn(text: $draft, send: sendDraft)

            Button {
                sendDraft()
            } label: {
                if timelineViewModel.isSending {
                    ProgressView()
                } else {
                    Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "arrow.up.circle" : "arrow.up.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : TrixDesign.accent)
                }
            }
            .buttonStyle(.borderless)
            .disabled(timelineViewModel.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSendEncrypted)
            .help("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var timelineEmptyState: some View {
        if isTimelineLoading {
            timelineLoadingState
        } else if timelineViewModel.errorMessage != nil {
            TrixEmptyStateView(
                title: "Timeline unavailable",
                systemImage: "exclamationmark.bubble",
                message: "Refresh this chat to try loading messages again."
            )
        } else if canSendEncrypted {
            TrixEmptyStateView(
                title: "No messages yet",
                systemImage: "bubble.left.and.text.bubble.right",
                message: "Encrypted messages will appear here after sync."
            )
        } else {
            TrixEmptyStateView(
                title: "OMEMO required",
                systemImage: "lock.shield",
                message: "Trust a contact device before sending encrypted messages."
            )
        }
    }

    private var timelineLoadingState: some View {
        VStack(spacing: 10) {
            if let progress = visibleLoadProgress {
                ProgressView(value: progress.fractionCompleted, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text(progress.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ProgressView("Loading timeline")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 36)
    }

    private var timelineEntries: [TrixTimelineEntry] {
        Self.timelineEntries(for: visibleTimelineItems)
    }

    private var visibleTimelineItems: [TrixTimelineItem] {
        guard timelineViewModel.roomID == room.id else {
            return []
        }

        return timelineViewModel.items
    }

    private var isTimelineLoading: Bool {
        timelineViewModel.roomID != room.id || timelineViewModel.isLoading
    }

    private var visibleLoadProgress: TrixTimelineLoadProgress? {
        guard let progress = timelineViewModel.loadProgress,
              progress.roomID == room.id else {
            return nil
        }

        return progress
    }

    fileprivate static var attachmentImportContentTypes: [UTType] {
        var types: [UTType] = [
            .fileURL,
            .png,
            .jpeg,
            .gif,
            .tiff,
            .image,
            .item,
        ]
        for identifier in ["public.heic", "public.heif", "org.webmproject.webp"] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        return types
    }

    private static var attachmentImageDataContentTypes: [UTType] {
        attachmentImportContentTypes.filter { contentType in
            contentType.conforms(to: .image) &&
                contentType != .image &&
                contentType != .item
        }
    }

    private static var attachmentImportTypeIdentifiers: [String] {
        attachmentImportContentTypes.map(\.identifier)
    }

    private var canSendEncryptedAttachments: Bool {
        guard let availability = timelineViewModel.attachmentSendAvailability,
              availability.roomID == room.id else {
            return false
        }

        return availability.canSend
    }

    private var attachmentBlockMessage: String? {
        guard room.kind == .group,
              canSendEncrypted,
              !timelineViewModel.isLoadingAttachmentAvailability,
              let availability = timelineViewModel.attachmentSendAvailability,
              availability.roomID == room.id,
              !availability.canSend else {
            return nil
        }

        return availability.blockReason?.message
    }

    private var attachmentHelpText: String {
        if canSendEncryptedAttachments {
            return "Encrypted attachments"
        }

        if timelineViewModel.isLoadingAttachmentAvailability {
            return "Checking OMEMO attachment readiness"
        }

        return timelineViewModel.attachmentSendAvailability?.blockReason?.message ?? "Encrypted attachments are not available yet"
    }

    private func sendDraft() {
        let text = draft
        guard canSendEncrypted,
              !timelineViewModel.isSending,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        draft = ""
        sendTypingStateIfNeeded(.paused)
        Task {
            await model.send(text: text)
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrixDesign.accent)

            Text(typingIndicatorText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var typingIndicatorText: String {
        if room.kind == .direct {
            return "\(room.name) is typing"
        }

        if timelineViewModel.typingUserIDs.count == 1,
           let userID = timelineViewModel.typingUserIDs.first {
            return "\(Self.displayName(from: userID)) is typing"
        }

        return "\(timelineViewModel.typingUserIDs.count) people are typing"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TrixAvatarView(
                title: room.name,
                systemImage: room.kind.systemImage,
                size: 44,
                tint: room.kind.tint
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TrixRoomKindMark(kind: room.kind, size: 20)

                    Text(room.name)
                        .font(.headline)
                        .lineLimit(1)

                    TrixRoomSecurityMark(isEncrypted: canSendEncrypted, size: 20)
                }
                Text(room.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if room.kind == .direct {
                Button {
                    showDeviceTrust()
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .help("OMEMO devices")
            } else {
                Button {
                    showDeviceTrust()
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .help("Group OMEMO devices")

                Button {
                    isShowingGroupMembers = true
                } label: {
                    Image(systemName: "person.2.badge.gearshape")
                }
                .help("Group members")
            }

            Button {
                Task {
                    await model.loadTimeline(roomID: room.id)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh timeline")

            Menu {
                if room.kind == .direct {
                    Button(role: .destructive) {
                        isShowingLocalForgetConfirmation = true
                    } label: {
                        Label("Forget DM Locally", systemImage: "eye.slash")
                    }
                } else {
                    Button(role: .destructive) {
                        isShowingGroupLeaveConfirmation = true
                    } label: {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Conversation actions")
        }
    }

    private func handleDraftChange(_ value: String) {
        typingPauseTask?.cancel()
        guard canSendEncrypted else {
            sendTypingStateIfNeeded(.paused)
            return
        }

        let isTyping = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isTyping else {
            sendTypingStateIfNeeded(.paused)
            return
        }

        sendTypingStateIfNeeded(.composing)
        typingPauseTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }

            await model.sendTypingState(.paused, roomID: room.id)
            await MainActor.run {
                lastSentTypingState = .paused
            }
        }
    }

    private func sendTypingStateIfNeeded(_ state: TrixTypingState) {
        guard lastSentTypingState != state else {
            return
        }

        lastSentTypingState = state
        Task {
            await model.sendTypingState(state, roomID: room.id)
        }
    }

    private func showDeviceTrust() {
        if room.kind == .group {
            showGroupDevices()
        } else {
            showPeerDevices()
        }
    }

    private func showPeerDevices() {
        isShowingDeviceTrust = true
        Task {
            await loadPeerDevices(refresh: true)
        }
    }

    private func showGroupDevices() {
        isShowingDeviceTrust = true
        Task {
            await loadGroupDevices(refresh: true)
        }
    }

    private func resetDeviceTrustState() {
        peerDevices = []
        peerDeviceError = nil
        isLoadingPeerDevices = false
        groupDeviceEntries = []
        groupDeviceError = nil
        isLoadingGroupDevices = false
    }

    private func importAttachment(from result: Result<[URL], Error>) {
        do {
            try ensureCanImportAttachment()

            guard let url = try result.get().first else {
                return
            }

            let upload = try readAttachmentUpload(from: url)

            Task {
                await model.sendAttachment(upload)
            }
        } catch {
            fileImportError = error.trixUserFacingMessage
        }
    }

    @discardableResult
    private func importAttachment(from providers: [NSItemProvider]) -> Bool {
        do {
            try ensureCanImportAttachment()
        } catch {
            fileImportError = error.trixUserFacingMessage
            return false
        }

        fileImportError = nil

        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            loadFileAttachment(from: fileProvider)
            return true
        }

        if let imageProvider = providers.first(where: Self.canLoadPlatformImage(from:)) {
            loadPlatformImageAttachment(from: imageProvider)
            return true
        }

        for provider in providers {
            if let contentType = Self.attachmentImageDataContentTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                loadImageDataAttachment(from: provider, contentType: contentType)
                return true
            }
        }

        fileImportError = TrixClientError.attachmentTransferFailed.trixUserFacingMessage
        return false
    }

    private func ensureCanImportAttachment() throws {
        guard canSendEncryptedAttachments else {
            throw timelineViewModel.attachmentSendAvailability?.blockReason.map { TrixAttachmentImportError.blocked($0.message) }
                ?? TrixAttachmentImportError.blocked("Encrypted attachments are not available yet.")
        }
    }

    private func readAttachmentUpload(from url: URL) throws -> TrixAttachmentUpload {
        try Self.readAttachmentUpload(from: url)
    }

    nonisolated private static func readAttachmentUpload(from url: URL) throws -> TrixAttachmentUpload {
        let canAccess = url.startAccessingSecurityScopedResource()
        defer {
            if canAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        #if os(macOS)
        var coordinatedResult: Result<TrixAttachmentUpload, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { readableURL in
            coordinatedResult = Result {
                try TrixAttachmentUpload(
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
        throw TrixClientError.attachmentTransferFailed
        #else
        return try TrixAttachmentUpload(fileURL: url)
        #endif
    }

    nonisolated private func loadFileAttachment(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            if let error {
                failAttachmentImport(error)
                return
            }

            do {
                let url = try Self.fileURL(from: item)
                let upload = try Self.readAttachmentUpload(from: url)
                completeAttachmentImport(upload)
            } catch {
                failAttachmentImport(error)
            }
        }
    }

    nonisolated private func loadImageDataAttachment(from provider: NSItemProvider, contentType: UTType) {
        provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, error in
            if let error {
                failAttachmentImport(error)
                return
            }

            guard let data, !data.isEmpty else {
                failAttachmentImport(TrixClientError.emptyAttachment)
                return
            }

            do {
                let upload = try Self.imageAttachmentUpload(data: data, contentType: contentType)
                completeAttachmentImport(upload)
            } catch {
                failAttachmentImport(error)
            }
        }
    }

    nonisolated private func loadPlatformImageAttachment(from provider: NSItemProvider) {
        provider.loadObject(ofClass: TrixPlatformPasteImage.self) { object, error in
            if let error {
                failAttachmentImport(error)
                return
            }

            guard let image = object as? TrixPlatformPasteImage,
                  let data = Self.pngData(from: image),
                  !data.isEmpty else {
                failAttachmentImport(TrixClientError.attachmentTransferFailed)
                return
            }

            completeAttachmentImport(
                TrixAttachmentUpload(
                    filename: Self.pastedImageFilename(fileExtension: "png"),
                    mimeType: "image/png",
                    data: data
                )
            )
        }
    }

    nonisolated private func completeAttachmentImport(_ upload: TrixAttachmentUpload) {
        Task { @MainActor in
            fileImportError = nil
            await model.sendAttachment(upload)
        }
    }

    nonisolated private func failAttachmentImport(_ error: Error) {
        let message = error.trixUserFacingMessage
        Task { @MainActor in
            fileImportError = message
        }
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) throws -> URL {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = item as? String,
           let url = URL(string: string) {
            return url
        }

        throw TrixClientError.attachmentTransferFailed
    }

    nonisolated private static func imageAttachmentUpload(data: Data, contentType: UTType) throws -> TrixAttachmentUpload {
        if contentType == .tiff,
           let image = TrixPlatformPasteImage(data: data),
           let pngData = pngData(from: image) {
            return TrixAttachmentUpload(
                filename: pastedImageFilename(fileExtension: "png"),
                mimeType: "image/png",
                data: pngData
            )
        }

        let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
        let fileExtension = contentType.preferredFilenameExtension ?? "bin"
        return TrixAttachmentUpload(
            filename: pastedImageFilename(fileExtension: fileExtension),
            mimeType: mimeType,
            data: data
        )
    }

    nonisolated private static func pastedImageFilename(fileExtension: String) -> String {
        "pasted-image-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
    }

    nonisolated private static func canLoadPlatformImage(from provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: TrixPlatformPasteImage.self)
    }

    nonisolated private static func pngData(from image: TrixPlatformPasteImage) -> Data? {
        #if os(iOS)
        return image.pngData()
        #elseif os(macOS)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
        #endif
    }

    private func loadPeerDevices(refresh: Bool) async {
        guard room.kind == .direct else {
            return
        }

        isLoadingPeerDevices = true
        peerDeviceError = nil
        defer { isLoadingPeerDevices = false }

        do {
            peerDevices = try await model.peerDeviceIdentities(for: room.id, refresh: refresh)
        } catch {
            peerDeviceError = error.trixUserFacingMessage
        }
    }

    private func trustPeerDevice(_ device: TrixPeerDeviceIdentity) async {
        isLoadingPeerDevices = true
        peerDeviceError = nil
        defer { isLoadingPeerDevices = false }

        do {
            peerDevices = try await model.trustPeerDevice(userID: device.userID, deviceID: device.deviceID)
            await model.loadAttachmentSendAvailability(roomID: room.id)
        } catch {
            peerDeviceError = error.trixUserFacingMessage
        }
    }

    private func loadGroupDevices(refresh: Bool) async {
        guard room.kind == .group else {
            return
        }

        isLoadingGroupDevices = true
        groupDeviceError = nil
        defer { isLoadingGroupDevices = false }

        do {
            let members = try await model.members(roomID: room.id)
            var loadedEntries: [TrixGroupDeviceTrustEntry] = []
            for member in Self.sortedActiveMembers(members) {
                do {
                    let devices = try await model.peerDeviceIdentities(for: member.userID, refresh: refresh)
                    loadedEntries.append(
                        TrixGroupDeviceTrustEntry(
                            member: member,
                            devices: devices,
                            isCurrentUser: isCurrentUser(member.userID),
                            errorMessage: nil
                        )
                    )
                } catch {
                    loadedEntries.append(
                        TrixGroupDeviceTrustEntry(
                            member: member,
                            devices: [],
                            isCurrentUser: isCurrentUser(member.userID),
                            errorMessage: error.trixUserFacingMessage
                        )
                    )
                }
            }
            groupDeviceEntries = loadedEntries
        } catch {
            groupDeviceError = error.trixUserFacingMessage
        }
    }

    private func trustGroupDevice(_ device: TrixPeerDeviceIdentity) async {
        isLoadingGroupDevices = true
        groupDeviceError = nil
        defer { isLoadingGroupDevices = false }

        do {
            let trustedDevices = try await model.trustPeerDevice(userID: device.userID, deviceID: device.deviceID)
            groupDeviceEntries = groupDeviceEntries.map { entry in
                guard entry.matches(userID: device.userID) else {
                    return entry
                }

                return TrixGroupDeviceTrustEntry(
                    member: entry.member,
                    devices: trustedDevices,
                    isCurrentUser: entry.isCurrentUser,
                    errorMessage: nil
                )
            }
            await model.loadAttachmentSendAvailability(roomID: room.id)
        } catch {
            groupDeviceError = error.trixUserFacingMessage
        }
    }

    private func isCurrentUser(_ userID: String) -> Bool {
        let currentUserID = model.account?.userID ?? model.session?.userID ?? ""
        return trixNormalizedUserKey(userID) == trixNormalizedUserKey(currentUserID)
    }

    private static func displayName(from userID: String) -> String {
        let localpart = userID
            .split(separator: "@")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
    }

    private static func sortedActiveMembers(_ members: [TrixRoomMember]) -> [TrixRoomMember] {
        members
            .filter(\.membership.isActive)
            .sorted { lhs, rhs in
                if lhs.membership.sortOrder != rhs.membership.sortOrder {
                    return lhs.membership.sortOrder < rhs.membership.sortOrder
                }

                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func timelineEntries(for items: [TrixTimelineItem]) -> [TrixTimelineEntry] {
        let sortedItems = items.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }

        var entries: [TrixTimelineEntry] = []
        let calendar = Calendar.current

        for index in sortedItems.indices {
            let item = sortedItems[index]
            let previous = index > sortedItems.startIndex ? sortedItems[sortedItems.index(before: index)] : nil
            let next = index < sortedItems.index(before: sortedItems.endIndex) ? sortedItems[sortedItems.index(after: index)] : nil

            if previous.map({ !calendar.isDate($0.timestamp, inSameDayAs: item.timestamp) }) ?? true {
                let dayID = "day-\(calendar.startOfDay(for: item.timestamp).timeIntervalSince1970)"
                entries.append(.daySeparator(id: dayID, date: item.timestamp))
            }

            let startsCluster = previous.map { previousItem in
                !Self.canCluster(previousItem, with: item, calendar: calendar)
            } ?? true
            let endsCluster = next.map { nextItem in
                !Self.canCluster(item, with: nextItem, calendar: calendar)
            } ?? true

            entries.append(
                .message(
                    TrixTimelineMessagePresentation(
                        item: item,
                        startsCluster: startsCluster,
                        endsCluster: endsCluster,
                        showsSender: !item.isLocalEcho && startsCluster
                    )
                )
            )
        }

        return entries
    }

    private static func canCluster(
        _ first: TrixTimelineItem,
        with second: TrixTimelineItem,
        calendar: Calendar
    ) -> Bool {
        first.sender == second.sender &&
        first.isLocalEcho == second.isLocalEcho &&
        calendar.isDate(first.timestamp, inSameDayAs: second.timestamp) &&
        second.timestamp.timeIntervalSince(first.timestamp) <= 5 * 60
    }
}

private extension View {
    @ViewBuilder
    func trixAttachmentPasteCommand(_ action: @escaping ([NSItemProvider]) -> Void) -> some View {
        #if os(macOS)
        onPasteCommand(of: TrixTimelineView.attachmentImportContentTypes, perform: action)
        #else
        self
        #endif
    }
}

private enum TrixTimelineEntry: Identifiable {
    case daySeparator(id: String, date: Date)
    case message(TrixTimelineMessagePresentation)

    var id: String {
        switch self {
        case .daySeparator(let id, _):
            return id
        case .message(let presentation):
            return presentation.item.id
        }
    }
}

private struct TrixTimelineMessagePresentation: Identifiable {
    let item: TrixTimelineItem
    let startsCluster: Bool
    let endsCluster: Bool
    let showsSender: Bool

    var id: String {
        item.id
    }
}

private struct TrixTimelineDaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(TrixDesign.surfaceStroke)
                .frame(height: 1)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Rectangle()
                .fill(TrixDesign.surfaceStroke)
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        return Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private func trixNormalizedUserKey(_ userID: String) -> String {
    let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.hasPrefix("@"),
          let separator = trimmed.firstIndex(of: ":") else {
        return trimmed
    }

    let localpart = trimmed[trimmed.index(after: trimmed.startIndex)..<separator]
    let server = trimmed[trimmed.index(after: separator)...]
    guard !localpart.isEmpty, !server.isEmpty else {
        return trimmed
    }

    return "\(localpart)@\(server)"
}

private struct TrixGroupDeviceTrustEntry: Identifiable {
    let member: TrixRoomMember
    let devices: [TrixPeerDeviceIdentity]
    let isCurrentUser: Bool
    let errorMessage: String?

    var id: String {
        trixNormalizedUserKey(member.userID)
    }

    var trustedActiveDeviceCount: Int {
        devices.filter(\.canSendEncrypted).count
    }

    var needsTrust: Bool {
        !isCurrentUser && trustedActiveDeviceCount == 0
    }

    var statusLabel: String {
        if isCurrentUser {
            return "You"
        }

        if errorMessage != nil {
            return "Refresh Failed"
        }

        if devices.isEmpty {
            return "No Devices"
        }

        return needsTrust ? "Needs Trust" : "Ready"
    }

    var statusIcon: String {
        if isCurrentUser || !needsTrust {
            return "checkmark.shield.fill"
        }

        return "exclamationmark.shield"
    }

    var statusTint: Color {
        if errorMessage != nil || needsTrust {
            return .orange
        }

        return .green
    }

    func matches(userID: String) -> Bool {
        let needle = trixNormalizedUserKey(userID)
        return trixNormalizedUserKey(member.userID) == needle
            || devices.contains { trixNormalizedUserKey($0.userID) == needle }
    }
}

private struct TrixGroupDeviceTrustView: View {
    let roomName: String
    let entries: [TrixGroupDeviceTrustEntry]
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () -> Void
    let trust: (TrixPeerDeviceIdentity) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                summary

                if isLoading && entries.isEmpty {
                    ProgressView("Loading group OMEMO devices")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    TrixEmptyStateView(
                        title: "No Members",
                        systemImage: "person.2",
                        message: "Group members appear after the room is joined."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Button {
                        refresh()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(entries) { entry in
                                TrixGroupDeviceTrustMemberView(
                                    entry: entry,
                                    isLoading: isLoading,
                                    trust: trust
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let errorMessage {
                    TrixBannerView(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .red
                    )
                }

                Text("Trust only after comparing fingerprints with each contact over an independent channel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .navigationTitle("Trust \(roomName)")
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                    .help("Refresh devices")
                }
            }
        }
        .trixDialogSurface(minWidth: 560, minHeight: 420)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Label(summaryLabel, systemImage: needsTrustCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(needsTrustCount == 0 ? .green : .orange)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(entries.count) members")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    private var needsTrustCount: Int {
        entries.filter(\.needsTrust).count
    }

    private var summaryLabel: String {
        if entries.isEmpty {
            return "Group OMEMO devices"
        }

        if needsTrustCount == 0 {
            return "All required devices are trusted"
        }

        return "\(needsTrustCount) member\(needsTrustCount == 1 ? "" : "s") need trust"
    }
}

private struct TrixGroupDeviceTrustMemberView: View {
    let entry: TrixGroupDeviceTrustEntry
    let isLoading: Bool
    let trust: (TrixPeerDeviceIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TrixAvatarView(
                    title: entry.member.title,
                    systemImage: "person.fill",
                    size: 34,
                    tint: entry.isCurrentUser ? .secondary : TrixDesign.accent
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.member.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(entry.isCurrentUser ? "You" : entry.member.userID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Label(entry.statusLabel, systemImage: entry.statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.statusTint)
                    .lineLimit(1)
            }

            if let errorMessage = entry.errorMessage {
                TrixBannerView(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
            } else if entry.devices.isEmpty {
                Text(entry.isCurrentUser ? "Account devices are managed in Settings." : "No published OMEMO devices were found for this member.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(entry.devices) { device in
                        TrixGroupDeviceTrustDeviceRow(
                            device: device,
                            isLoading: isLoading,
                            trust: trust
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct TrixGroupDeviceTrustDeviceRow: View {
    let device: TrixPeerDeviceIdentity
    let isLoading: Bool
    let trust: (TrixPeerDeviceIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(device.trustState.label, systemImage: device.canSendEncrypted ? "checkmark.shield.fill" : "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(device.canSendEncrypted ? .green : .orange)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(device.deviceID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(device.shortFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if !device.canSendEncrypted && device.isActive {
                    Button {
                        trust(device)
                    } label: {
                        Label("Trust Device", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }
        }
        .padding(10)
        .background(TrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TrixPeerDeviceTrustView: View {
    let roomName: String
    let devices: [TrixPeerDeviceIdentity]
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () -> Void
    let trust: (TrixPeerDeviceIdentity) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading && devices.isEmpty {
                    ProgressView("Loading OMEMO devices")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if devices.isEmpty {
                    TrixEmptyStateView(
                        title: "No OMEMO Devices",
                        systemImage: "checkmark.shield",
                        message: "No published OMEMO devices were found for this contact yet."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Button {
                        refresh()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(devices) { device in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(device.trustState.label, systemImage: device.canSendEncrypted ? "checkmark.shield.fill" : "exclamationmark.shield")
                                            .font(.headline)
                                            .foregroundStyle(device.canSendEncrypted ? .green : .orange)
                                            .lineLimit(1)

                                        Spacer()

                                        Text(device.deviceID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Text(device.shortFingerprint)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if !device.canSendEncrypted && device.isActive {
                                        Button {
                                            trust(device)
                                        } label: {
                                            Label("Trust Device", systemImage: "checkmark.shield")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isLoading)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let errorMessage {
                    TrixBannerView(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .red
                    )
                }

                Text("Trust only after comparing this fingerprint with the contact over an independent channel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .navigationTitle("Trust \(roomName)")
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                    .help("Refresh devices")
                }
            }
        }
        .trixDialogSurface(minWidth: 520, minHeight: 360)
    }
}

private struct TrixTimelineRow: View {
    let presentation: TrixTimelineMessagePresentation
    let isDownloadingAttachment: Bool
    let attachmentFailure: String?
    let inlineAttachmentPreview: TrixAttachmentDownload?
    let isLoadingInlineAttachmentPreview: Bool
    let inlineAttachmentPreviewFailure: String?
    let isReacting: Bool
    let downloadAttachment: () -> Void
    let loadInlineAttachmentPreview: () -> Void
    let react: (String) -> Void
    let addStickerPack: (TrixStickerAttachmentMetadata) -> Void

    private var item: TrixTimelineItem {
        presentation.item
    }

    var body: some View {
        HStack {
            if item.isLocalEcho {
                Spacer(minLength: 54)
            }

            VStack(alignment: item.isLocalEcho ? .trailing : .leading, spacing: 4) {
                if presentation.showsSender {
                    Text(displaySender)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrixDesign.accent.opacity(0.88))
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }

                if let attachment = item.attachment, attachment.isSticker {
                    TrixStickerMessageContent(
                        attachment: attachment,
                        itemID: item.id,
                        isOutgoing: item.isLocalEcho,
                        timestamp: item.timestamp,
                        deliveryState: deliveryState,
                        isDownloading: isDownloadingAttachment,
                        failureMessage: attachmentFailure,
                        inlinePreview: inlineAttachmentPreview,
                        isLoadingInlinePreview: isLoadingInlineAttachmentPreview,
                        inlinePreviewFailure: inlineAttachmentPreviewFailure,
                        isReacting: isReacting,
                        reactionAggregates: item.reactionAggregates,
                        download: downloadAttachment,
                        loadInlinePreview: loadInlineAttachmentPreview,
                        react: react,
                        addStickerPack: addStickerPack
                    )
                    .frame(maxWidth: bubbleMaxWidth, alignment: item.isLocalEcho ? .trailing : .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if let attachment = item.attachment {
                            TrixAttachmentRow(
                                attachment: attachment,
                                itemID: item.id,
                                isOutgoing: item.isLocalEcho,
                                isDownloading: isDownloadingAttachment,
                                failureMessage: attachmentFailure,
                                inlinePreview: inlineAttachmentPreview,
                                isLoadingInlinePreview: isLoadingInlineAttachmentPreview,
                                inlinePreviewFailure: inlineAttachmentPreviewFailure,
                                download: downloadAttachment,
                                loadInlinePreview: loadInlineAttachmentPreview,
                                addStickerPack: addStickerPack
                            )
                        } else {
                            TrixCollapsibleMessageText(
                                text: item.body,
                                isOutgoing: item.isLocalEcho
                            )
                        }

                        TrixReactionChips(
                            aggregates: item.reactionAggregates,
                            isOutgoing: item.isLocalEcho,
                            react: react
                        )

                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                TrixReactionMenu(
                                    isOutgoing: item.isLocalEcho,
                                    isWorking: isReacting,
                                    react: react
                                )

                                if item.isLocalEcho {
                                    Image(systemName: deliveryState.systemImage)
                                        .font(.caption2.weight(.semibold))
                                        .accessibilityLabel(deliveryState.label)
                                        .help(deliveryState.label)
                                }

                                Text(item.timestamp, style: .time)
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(item.isLocalEcho ? .white.opacity(0.82) : .secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, presentation.startsCluster ? 11 : 9)
                    .padding(.bottom, presentation.endsCluster ? 11 : 9)
                    .frame(maxWidth: bubbleMaxWidth, alignment: item.isLocalEcho ? .trailing : .leading)
                    .background(item.isLocalEcho ? TrixDesign.accent : TrixDesign.incomingBubbleSurface)
                    .clipShape(bubbleShape)
                    .overlay {
                        bubbleShape
                            .stroke(item.isLocalEcho ? .clear : TrixDesign.surfaceStroke, lineWidth: 1)
                    }
                    .shadow(
                        color: item.isLocalEcho ? TrixDesign.accent.opacity(0.18) : TrixDesign.softShadow,
                        radius: item.isLocalEcho ? 12 : 8,
                        y: item.isLocalEcho ? 6 : 4
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: item.isLocalEcho ? .trailing : .leading)

            if !item.isLocalEcho {
                Spacer(minLength: 54)
            }
        }
        .padding(.top, presentation.startsCluster ? 8 : 2)
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

    private var deliveryState: TrixDeliveryState {
        item.deliveryState ?? .sent
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private var bubbleMaxWidth: CGFloat {
        #if os(macOS)
        return 520
        #else
        return 330
        #endif
    }
}

private struct TrixCollapsibleMessageText: View {
    let text: String
    let isOutgoing: Bool
    @State private var isExpanded = false

    private let previewLineCount = 20
    private let collapseThreshold = 30

    var body: some View {
        if shouldCollapse {
            VStack(alignment: .leading, spacing: 8) {
                if isExpanded {
                    messageText(text)

                    unfoldButton(
                        title: "Fold",
                        systemImage: "chevron.up",
                        accessibilityLabel: "Collapse message"
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        messageText(previewText, lineLimit: previewLineCount)
                            .padding(.bottom, 24)

                        LinearGradient(
                            colors: [
                                bubbleSurface.opacity(0),
                                bubbleSurface.opacity(0.92),
                                bubbleSurface,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 58)
                        .allowsHitTesting(false)

                        unfoldButton(
                            title: "Unfold",
                            systemImage: "chevron.down",
                            accessibilityLabel: "Unfold message"
                        )
                    }
                }
            }
            .onChange(of: text) { _, _ in
                isExpanded = false
            }
        } else {
            messageText(text)
        }
    }

    private var shouldCollapse: Bool {
        logicalLines.count > collapseThreshold
    }

    private var previewText: String {
        logicalLines.prefix(previewLineCount).joined(separator: "\n")
    }

    private var logicalLines: [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private var bubbleSurface: Color {
        isOutgoing ? TrixDesign.accent : TrixDesign.incomingBubbleSurface
    }

    private var textColor: Color {
        isOutgoing ? .white : .primary
    }

    private var buttonForeground: Color {
        isOutgoing ? .white : TrixDesign.accent
    }

    private var buttonSurface: Color {
        isOutgoing ? Color.white.opacity(0.18) : TrixDesign.accent.opacity(0.12)
    }

    private func messageText(_ value: String, lineLimit: Int? = nil) -> some View {
        Text(value)
            .font(.body)
            .foregroundStyle(textColor)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func unfoldButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(buttonForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(buttonSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

private struct TrixStickerMessageContent: View {
    let attachment: TrixTimelineAttachment
    let itemID: String
    let isOutgoing: Bool
    let timestamp: Date
    let deliveryState: TrixDeliveryState
    let isDownloading: Bool
    let failureMessage: String?
    let inlinePreview: TrixAttachmentDownload?
    let isLoadingInlinePreview: Bool
    let inlinePreviewFailure: String?
    let isReacting: Bool
    let reactionAggregates: [TrixReactionAggregate]
    let download: () -> Void
    let loadInlinePreview: () -> Void
    let react: (String) -> Void
    let addStickerPack: (TrixStickerAttachmentMetadata) -> Void

    var body: some View {
        let size = stickerSize

        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    guard attachment.isDownloadable else {
                        return
                    }

                    if inlinePreview == nil {
                        loadInlinePreview()
                    } else {
                        download()
                    }
                } label: {
                    stickerSurface(size: size)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(stickerHelpText)
                .accessibilityLabel(stickerAccessibilityLabel)

                metadataPill
                    .padding(6)
            }
            .frame(width: size.width, height: size.height)
            .contextMenu {
                Button {
                    download()
                } label: {
                    Label("Open Sticker", systemImage: "eye")
                }
                .disabled(!attachment.isDownloadable)

                if let stickerMetadata = attachment.stickerMetadata,
                   stickerMetadata.source.kind == .telegram {
                    Button {
                        addStickerPack(stickerMetadata)
                    } label: {
                        Label("Add Sticker Pack", systemImage: "plus.circle")
                    }
                }
            }
            .task(id: itemID) {
                guard inlinePreview == nil,
                      !isLoadingInlinePreview,
                      inlinePreviewFailure == nil,
                      attachment.isDownloadable else {
                    return
                }

                loadInlinePreview()
            }

            TrixReactionChips(
                aggregates: reactionAggregates,
                isOutgoing: false,
                react: react
            )
            .frame(width: size.width, alignment: isOutgoing ? .trailing : .leading)
        }
    }

    @ViewBuilder
    private func stickerSurface(size: CGSize) -> some View {
        if let inlinePreview, let image = platformImage(from: inlinePreview.data) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        } else if isLoadingInlinePreview || isDownloading {
            ProgressView()
                .controlSize(.regular)
                .frame(width: size.width, height: size.height)
                .background(placeholderBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(spacing: 8) {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: 30, weight: .semibold))
                Text(placeholderText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(placeholderForeground)
            .frame(width: size.width, height: size.height)
            .background(placeholderBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var metadataPill: some View {
        HStack(spacing: 5) {
            TrixReactionMenu(
                isOutgoing: true,
                isWorking: isReacting,
                react: react
            )

            if isOutgoing {
                Image(systemName: deliveryState.systemImage)
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(deliveryState.label)
                    .help(deliveryState.label)
            }

            Text(timestamp, style: .time)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.34), in: Capsule())
    }

    private var stickerSize: CGSize {
        let maxSize = Self.maxStickerSize
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

    private static var maxStickerSize: CGSize {
        #if os(macOS)
        CGSize(width: 220, height: 220)
        #else
        CGSize(width: 190, height: 190)
        #endif
    }

    private var placeholderBackground: Color {
        TrixDesign.secondarySurface.opacity(0.72)
    }

    private var placeholderForeground: Color {
        inlinePreviewFailure == nil && failureMessage == nil ? TrixDesign.accent : .orange
    }

    private var placeholderSystemImage: String {
        inlinePreviewFailure == nil && failureMessage == nil ? "face.smiling" : "exclamationmark.triangle.fill"
    }

    private var placeholderText: String {
        if inlinePreviewFailure != nil || failureMessage != nil {
            return "Tap to retry"
        }

        return "Sticker"
    }

    private var stickerHelpText: String {
        if inlinePreview == nil {
            return "Load encrypted sticker"
        }

        return "Open encrypted sticker"
    }

    private var stickerAccessibilityLabel: String {
        if let emoji = attachment.stickerMetadata?.emoji {
            return "Sticker \(emoji)"
        }

        return "Sticker"
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

private struct TrixAttachmentRow: View {
    let attachment: TrixTimelineAttachment
    let itemID: String
    let isOutgoing: Bool
    let isDownloading: Bool
    let failureMessage: String?
    let inlinePreview: TrixAttachmentDownload?
    let isLoadingInlinePreview: Bool
    let inlinePreviewFailure: String?
    let download: () -> Void
    let loadInlinePreview: () -> Void
    let addStickerPack: (TrixStickerAttachmentMetadata) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment) {
                TrixInlineAttachmentPreview(
                    itemID: itemID,
                    attachment: attachment,
                    preview: inlinePreview,
                    isLoading: isLoadingInlinePreview,
                    failureMessage: inlinePreviewFailure,
                    isOutgoing: isOutgoing,
                    open: download,
                    loadPreview: loadInlinePreview
                )
            }

            HStack(alignment: .center, spacing: 10) {
                if !TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOutgoing ? Color.white.opacity(0.18) : TrixDesign.accent.opacity(0.12))
                        .frame(width: 42, height: 42)
                        .overlay {
                            if isDownloading {
                                ProgressView()
                                    .tint(isOutgoing ? .white : TrixDesign.accent)
                            } else {
                                Image(systemName: attachment.isImage ? "photo.on.rectangle.angled" : "doc.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(isOutgoing ? .white : TrixDesign.accent)
                            }
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(attachmentTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isOutgoing ? .white : .primary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if !attachment.subtitle.isEmpty {
                        Text(attachment.subtitle)
                            .font(.caption)
                            .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
                    }

                    Label(attachment.isSticker ? "Encrypted sticker" : "Encrypted attachment", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
                        .lineLimit(1)

                    if !attachment.isDownloadable {
                        Label("Download unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .orange)
                            .lineLimit(1)
                    }

                    if failureMessage != nil {
                        Label("Download failed. Try again.", systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isOutgoing ? .white.opacity(0.86) : .orange)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    download()
                } label: {
                    Image(systemName: attachmentButtonImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isOutgoing ? .white : TrixDesign.accent)
                }
                .buttonStyle(.borderless)
                .disabled(isDownloading || !attachment.isDownloadable)
                .help(attachmentButtonHelp)
                .accessibilityLabel(attachmentButtonHelp)
            }

            if let stickerMetadata = attachment.stickerMetadata,
               stickerMetadata.source.kind == .telegram {
                Button {
                    addStickerPack(stickerMetadata)
                } label: {
                    Label("Add Sticker Pack", systemImage: "plus.circle.fill")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(isOutgoing ? .white : TrixDesign.accent)
            }
        }
    }

    private var attachmentButtonImage: String {
        if isDownloading {
            return "hourglass"
        }

        return attachment.isImage || attachment.isSticker ? "eye.circle.fill" : "arrow.down.circle.fill"
    }

    private var attachmentTitle: String {
        guard let stickerMetadata = attachment.stickerMetadata else {
            return attachment.filename
        }

        if let emoji = stickerMetadata.emoji {
            return "Sticker \(emoji)"
        }

        return "Sticker"
    }

    private var attachmentButtonHelp: String {
        if failureMessage != nil {
            return "Retry encrypted attachment download"
        }

        if attachment.isSticker {
            return "Download and preview encrypted sticker"
        }

        if attachment.isImage {
            return "Download and preview encrypted image"
        }

        return "Download encrypted attachment"
    }
}

private struct TrixStickerPickerView: View {
    @ObservedObject var model: TrixAppModel
    let canSendStickers: Bool
    let sendSticker: (TrixSticker) -> Void
    let importTelegramPack: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var telegramReference = ""
    @State private var selectedStickerPackID: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Telegram pack link", text: $telegramReference)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isImportingStickerPack)

                    Button {
                        importTelegramPack(telegramReference)
                        telegramReference = ""
                    } label: {
                        if model.isImportingStickerPack {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isImportingStickerPack || telegramReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Import Telegram sticker pack")
                }

                if let stickerImportMessage = model.stickerImportMessage {
                    TrixBannerView(
                        text: stickerImportMessage,
                        systemImage: "face.smiling",
                        tint: TrixDesign.accent
                    )
                }

                if !canSendStickers {
                    TrixBannerView(
                        text: "OMEMO attachment readiness is required before sending stickers.",
                        systemImage: "lock.slash.fill",
                        tint: .orange
                    )
                }

                if model.stickerPacks.isEmpty {
                    TrixEmptyStateView(
                        title: "No stickers",
                        systemImage: "face.smiling",
                        message: "Imported Telegram sticker packs will appear here."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stickerPackSelector

                    Divider()

                    selectedStickerGrid
                }
            }
            .padding(20)
            .navigationTitle("Stickers")
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .trixStickerPickerFrame()
        .onAppear(perform: ensureSelectedStickerPack)
        .onChange(of: model.stickerPacks.map(\.id)) { oldIDs, newIDs in
            if let insertedID = newIDs.first(where: { !oldIDs.contains($0) }) {
                selectedStickerPackID = insertedID
            } else {
                ensureSelectedStickerPack()
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 72, maximum: 92), spacing: 10)]
    }

    private var selectedStickerPack: TrixStickerPack? {
        if let selectedStickerPackID,
           let pack = model.stickerPacks.first(where: { $0.id == selectedStickerPackID }) {
            return pack
        }

        return model.stickerPacks.first
    }

    private var stickerPackSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.stickerPacks) { pack in
                    TrixStickerPackTab(
                        pack: pack,
                        previewData: pack.stickers.first.flatMap { model.stickerData(for: $0) },
                        isSelected: selectedStickerPack?.id == pack.id,
                        select: {
                            selectedStickerPackID = pack.id
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var selectedStickerGrid: some View {
        Group {
            if let pack = selectedStickerPack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(pack.title)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        Text("\(pack.stickers.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(pack.stickers) { sticker in
                                TrixStickerTile(
                                    sticker: sticker,
                                    data: model.stickerData(for: sticker),
                                    canSend: canSendStickers,
                                    send: {
                                        sendSticker(sticker)
                                        dismiss()
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func ensureSelectedStickerPack() {
        guard !model.stickerPacks.isEmpty else {
            selectedStickerPackID = nil
            return
        }

        if let selectedStickerPackID,
           model.stickerPacks.contains(where: { $0.id == selectedStickerPackID }) {
            return
        }

        selectedStickerPackID = model.stickerPacks.first?.id
    }
}

private struct TrixStickerPackTab: View {
    let pack: TrixStickerPack
    let previewData: Data?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? TrixDesign.accent.opacity(0.16) : TrixDesign.secondarySurface)

                    if let previewData, let image = platformImage(from: previewData) {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(TrixDesign.accent)
                    }
                }
                .frame(width: 58, height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? TrixDesign.accent : TrixDesign.surfaceStroke, lineWidth: isSelected ? 2 : 1)
                }

                Text(pack.title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? TrixDesign.accent : .secondary)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.plain)
        .help(pack.title)
        .accessibilityLabel("Sticker pack \(pack.title)")
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

private struct TrixStickerTile: View {
    let sticker: TrixSticker
    let data: Data?
    let canSend: Bool
    let send: () -> Void

    var body: some View {
        Button(action: send) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TrixDesign.secondarySurface)

                if let data, let image = platformImage(from: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(TrixDesign.accent)
                }
            }
            .frame(width: 72, height: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSend || data == nil)
        .help(sticker.emoji.map { "Send sticker \($0)" } ?? "Send sticker")
        .accessibilityLabel(sticker.emoji.map { "Send sticker \($0)" } ?? "Send sticker")
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

private struct TrixReactionMenu: View {
    let isOutgoing: Bool
    let isWorking: Bool
    let react: (String) -> Void

    var body: some View {
        Menu {
            ForEach(Self.palette, id: \.self) { emoji in
                Button(emoji) {
                    react(emoji)
                }
            }
        } label: {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "face.smiling")
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
        .help("React")
        .accessibilityLabel("React")
    }

    private static let palette = ["👍", "❤️", "😂", "✅", "👀"]
}

private struct TrixReactionChips: View {
    let aggregates: [TrixReactionAggregate]
    let isOutgoing: Bool
    let react: (String) -> Void

    var body: some View {
        if !aggregates.isEmpty {
            HStack(spacing: 6) {
                ForEach(aggregates) { aggregate in
                    Button {
                        react(aggregate.emoji)
                    } label: {
                        Text("\(aggregate.emoji) \(aggregate.count)")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(chipBackground(for: aggregate), in: Capsule())
                            .foregroundStyle(chipForeground(for: aggregate))
                    }
                    .buttonStyle(.plain)
                    .help(aggregate.isOwnReaction ? "Remove your reaction" : "React")
                }
            }
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        }
    }

    private func chipBackground(for aggregate: TrixReactionAggregate) -> Color {
        if aggregate.isOwnReaction {
            return isOutgoing ? Color.white.opacity(0.30) : TrixDesign.accent.opacity(0.16)
        }

        return isOutgoing ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12)
    }

    private func chipForeground(for aggregate: TrixReactionAggregate) -> Color {
        if aggregate.isOwnReaction {
            return isOutgoing ? .white : TrixDesign.accent
        }

        return isOutgoing ? .white.opacity(0.86) : .primary
    }
}

private struct TrixAttachmentPreviewView: View {
    let attachment: TrixAttachmentDownload
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
                        .background(TrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .trixAttachmentPreviewFrame()
        .task(id: attachment.id) {
            prepareTemporaryFile()
        }
        .onDisappear {
            removeTemporaryFile()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TrixAttachmentFileDocument(data: attachment.data),
            contentType: .data,
            defaultFilename: attachment.safeFilename
        ) { result in
            if case .failure(let error) = result {
                attachmentActionError = error.trixUserFacingMessage
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
                .appendingPathComponent("Trix-\(attachment.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent(attachment.safeFilename, isDirectory: false)
            try attachment.data.write(to: fileURL, options: [.atomic])
            temporaryDirectoryURL = directoryURL
            temporaryFileURL = fileURL
        } catch {
            attachmentActionError = error.trixUserFacingMessage
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

private struct TrixAttachmentFileDocument: FileDocument {
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
    func trixAttachmentPreviewFrame() -> some View {
        #if os(macOS)
        self.trixDialogSurface(minWidth: 420, minHeight: 320)
        #else
        self.trixDialogSurface()
        #endif
    }

    @ViewBuilder
    func trixStickerPickerFrame() -> some View {
        #if os(macOS)
        self.trixDialogSurface(minWidth: 520, minHeight: 520)
        #else
        self.trixDialogSurface()
        #endif
    }

    @ViewBuilder
    func trixMacComposerReturn(text: Binding<String>, send: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else {
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder.tryToPerform(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), with: nil) {
                    return .handled
                }

                text.wrappedValue.append("\n")
                return .handled
            }

            send()
            return .handled
        }
        #else
        self
        #endif
    }
}
