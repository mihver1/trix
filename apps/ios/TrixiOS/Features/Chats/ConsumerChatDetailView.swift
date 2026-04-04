import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

private let consumerChatAccent = TrixTheme.accent
private let consumerMessageClusterWindow: TimeInterval = 5 * 60
private let consumerTimelineBottomAnchor = "consumer-timeline-bottom-anchor"

private struct ConsumerAttachmentDraft {
    let fileURL: URL
    let fileName: String
    let fileSizeLabel: String?
}

private enum ConsumerAttachmentImportError: LocalizedError {
    case failedToLoadSelectedMedia

    var errorDescription: String? {
        switch self {
        case .failedToLoadSelectedMedia:
            return TrixStrings.text(.chatConsumerAttachmentImportFailed)
        }
    }
}

enum ConsumerTimelineItem: Identifiable, Equatable {
    case daySeparator(String)
    case message(ConsumerRenderedMessage)

    var id: String {
        switch self {
        case let .daySeparator(label):
            return "day-\(label)"
        case let .message(message):
            return message.id
        }
    }
}

enum ConsumerMessageClusterPosition: Equatable {
    case single
    case top
    case middle
    case bottom
}

enum ConsumerReceiptStatus: Int, Comparable {
    case delivered = 0
    case read = 1

    static func < (lhs: ConsumerReceiptStatus, rhs: ConsumerReceiptStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var systemImageName: String {
        switch self {
        case .delivered:
            return "checkmark"
        case .read:
            return "checkmark.double"
        }
    }
}

struct ConsumerRenderedMessage: Identifiable, Equatable {
    let id: String
    let senderAccountId: String
    let senderDeviceId: String
    let contentType: ContentType
    let createdAtDate: Date
    let isOutgoing: Bool
    let senderName: String?
    let attachmentBody: SafeMessengerAttachment?
    let primaryText: String
    let secondaryText: String?
    let clusterPosition: ConsumerMessageClusterPosition
    let topSpacing: CGFloat
    let usesCenteredEventStyle: Bool
    let receiptStatus: ConsumerReceiptStatus?
    let reactions: [SafeMessengerReactionSummary]
}

struct ConsumerConversationTimelineRenderState: Equatable {
    let latestTimelineAnchorId: String?
    let timelineItems: [ConsumerTimelineItem]
    let fixtureKindsByMessageId: [String: UITestFixtureMessageKind]
    let latestSentMessageId: String?
    let latestSentText: String?
    let downloadingAttachmentMessageId: String?
}

struct ConsumerTimelineRenderPayload {
    let items: [ConsumerTimelineItem]
    let fixtureKindsByMessageId: [String: UITestFixtureMessageKind]
}

struct ConsumerChatDetailView: View {
    let chatSummary: ChatSummary
    @Binding var serverBaseURL: String
    var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot: SafeConversationSnapshot?
    @State private var timelineItems: [ConsumerTimelineItem] = []
    @State private var isLoadingSnapshot = false
    @State private var composerText = ""
    @State private var selectedAttachment: ConsumerAttachmentDraft?
    @State private var isImportingAttachment = false
    #if os(iOS)
    @State private var isShowingAttachmentOptions = false
    @State private var isImportingPhotoVideo = false
    @State private var selectedPhotoVideoItem: PhotosPickerItem?
    #endif
    @State private var localErrorMessage: String?
    @State private var activityMessage: String?
    @State private var downloadedAttachment: DownloadedAttachmentFile?
    @State private var downloadingAttachmentMessageId: String?
    @State private var isTypingPublished = false
    @State private var latestSentMessageId: String?
    @State private var latestSentText: String?
    @State private var fixtureKindsByMessageId: [String: UITestFixtureMessageKind] = [:]
    @FocusState private var isComposerFocused: Bool
    @State private var isConfirmingDmGlobalDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if let activityMessage {
                ConsumerChatBanner(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    text: activityMessage
                )
                .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.successBanner)
            }

            if let localErrorMessage {
                ConsumerChatBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: localErrorMessage
                )
                .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.errorBanner)
            }

            if let timelineRenderState {
                ConsumerConversationTimelineView(
                    renderState: timelineRenderState,
                    canReact: canReact,
                    model: model,
                    serverBaseURLString: serverBaseURL,
                    onOpenAttachment: openAttachment,
                    onSelectReaction: sendReaction
                )
                .equatable()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
            } else {
                Spacer()

                if isLoadingSnapshot {
                    ProgressView(TrixStrings.text(.chatLoadingConversation))
                } else {
                    ContentUnavailableView(
                        TrixStrings.text(.chatConversationUnavailableTitle),
                        systemImage: "icloud.slash",
                        description: Text(localErrorMessage ?? TrixStrings.text(.chatSnapshotUnavailableBody))
                    )
                }

                Spacer()
            }
        }
        .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.screen)
        .accessibilityValue(colorScheme == .dark ? "dark" : "light")
        .background(ConsumerChatBackdrop().ignoresSafeArea())
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canShowChatLifecycleMenu {
                    Menu {
                        Button("Leave on this device") {
                            Task { await performLeaveChat(scope: .thisDevice) }
                        }

                        Button("Leave on all my devices") {
                            Task { await performLeaveChat(scope: .allMyDevices) }
                        }

                        if effectiveChatType == .dm {
                            Button("Delete chat for both", role: .destructive) {
                                isConfirmingDmGlobalDelete = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(
                        model.isLoading ||
                            model.isPerformingChatLifecycleAction ||
                            isLoadingSnapshot
                    )
                }

                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(
                    model.isLoading ||
                        model.isPerformingChatLifecycleAction ||
                        isLoadingSnapshot
                )
            }
        }
        .task(id: snapshotTaskID) {
            await loadSnapshot()
        }
        .refreshable {
            await loadSnapshot()
        }
        .fileImporter(
            isPresented: $isImportingAttachment,
            allowedContentTypes: [.item]
        ) { result in
            handleAttachmentImport(result)
        }
        #if os(iOS)
        .confirmationDialog(
            TrixStrings.text(.chatChooseAttachment),
            isPresented: $isShowingAttachmentOptions,
            titleVisibility: .visible
        ) {
            Button(TrixStrings.text(.chatChoosePhotoOrVideo)) {
                isImportingPhotoVideo = true
            }

            Button(TrixStrings.text(.chatChooseFile)) {
                isImportingAttachment = true
            }

            Button(TrixStrings.text(.actionCancel), role: .cancel) {}
        }
        .photosPicker(
            isPresented: $isImportingPhotoVideo,
            selection: $selectedPhotoVideoItem,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotoVideoItem) { _, newValue in
            guard let newValue else {
                return
            }

            Task {
                await importPhotoVideoAttachment(from: newValue)
            }
        }
        #endif
        .sheet(item: $downloadedAttachment) { downloadedAttachment in
            AttachmentActivitySheet(items: [downloadedAttachment.fileURL])
        }
        .onChange(of: composerText) { _, newValue in
            publishTypingState(for: newValue)
        }
        .onDisappear {
            publishTypingState(for: "", force: true)
        }
        .confirmationDialog(
            "Delete this chat for both participants?",
            isPresented: $isConfirmingDmGlobalDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for both", role: .destructive) {
                Task { await performDmGlobalDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the DM for everyone. It cannot be undone.")
        }
    }

    private var effectiveChatType: ChatType {
        snapshot?.detail.chatType ?? chatSummary.chatType
    }

    private var canShowChatLifecycleMenu: Bool {
        effectiveChatType != .accountSync
    }

    private func performLeaveChat(scope: FfiLeaveChatScope) async {
        localErrorMessage = nil
        activityMessage = nil

        let response = await model.leaveChat(
            baseURLString: serverBaseURL,
            chatId: chatSummary.chatId,
            chatType: effectiveChatType,
            scope: scope
        )

        guard response != nil else {
            if let error = model.errorMessage {
                localErrorMessage = error
            }
            return
        }

        switch scope {
        case .thisDevice:
            activityMessage = "Left on this device"
        case .allMyDevices:
            activityMessage = "Left on all your devices"
        }

        await loadSnapshot()
    }

    private func performDmGlobalDelete() async {
        localErrorMessage = nil
        activityMessage = nil

        let response = await model.dmGlobalDeleteChat(
            baseURLString: serverBaseURL,
            chatId: chatSummary.chatId,
            chatType: effectiveChatType
        )

        guard response != nil else {
            if let error = model.errorMessage {
                localErrorMessage = error
            }
            return
        }

        activityMessage = "Chat removed for both participants"
        await loadSnapshot()
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let selectedAttachment {
                HStack(spacing: 12) {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(consumerChatAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedAttachment.fileName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        Text(selectedAttachment.fileSizeLabel ?? TrixStrings.text(.chatAttachmentReadyToSend))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        self.selectedAttachment = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(TrixTheme.primarySurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    #if os(iOS)
                    isShowingAttachmentOptions = true
                    #else
                    isImportingAttachment = true
                    #endif
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(consumerChatAccent)
                        .frame(width: 38, height: 38)
                }

                if selectedAttachment == nil {
                    ZStack {
                        TextField(
                            TrixStrings.text(.chatMessagePlaceholder),
                            text: $composerText,
                            axis: .vertical
                        )
                        .lineLimit(1...5)
                        .focused($isComposerFocused)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(TrixTheme.elevatedFieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isComposerFocused = true
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TrixStrings.text(.chatMessagePlaceholder))
                    .accessibilityValue(composerText.isEmpty ? "Empty" : composerText)
                    .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.messageBodyField)
                } else {
                    Text(TrixStrings.text(.chatAttachmentCaptionHint))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(TrixTheme.secondarySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
                        }
                }

                Button(action: sendCurrentPayload) {
                    Image(systemName: canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? consumerChatAccent : .secondary)
                }
                .disabled(!canSend || model.isLoading)
                .accessibilityLabel(TrixStrings.text(.actionSend))
                .accessibilityValue(canSend ? "Ready" : "Disabled")
                .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.sendButton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var timelineRenderState: ConsumerConversationTimelineRenderState? {
        guard let snapshot else {
            return nil
        }

        return ConsumerConversationTimelineRenderState(
            latestTimelineAnchorId: snapshot.latestTimelineAnchorId,
            timelineItems: timelineItems,
            fixtureKindsByMessageId: fixtureKindsByMessageId,
            latestSentMessageId: latestSentMessageId,
            latestSentText: latestSentText,
            downloadingAttachmentMessageId: downloadingAttachmentMessageId
        )
    }

    private var currentFixtureManifest: UITestFixtureManifest? {
        UITestLaunchConfiguration.current.isEnabled ? UITestFixtureManifestStore.load() : nil
    }

    private func applyConversationSnapshot(_ loadedSnapshot: SafeConversationSnapshot) {
        let renderPayload = ConsumerConversationTimelineBuilder.makeRenderPayload(
            for: loadedSnapshot,
            fixtureManifest: currentFixtureManifest
        )
        timelineItems = renderPayload.items
        fixtureKindsByMessageId = renderPayload.fixtureKindsByMessageId
        snapshot = loadedSnapshot
    }

    private var canSend: Bool {
        selectedAttachment != nil || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canReact: Bool {
        snapshot != nil && !model.isLoading && !isLoadingSnapshot
    }

    private var conversationTitle: String {
        if let detail = snapshot?.detail {
            return detail.resolvedTitle(currentAccountId: model.localIdentity?.accountId)
        }

        return chatSummary.resolvedTitle(currentAccountId: model.localIdentity?.accountId)
    }

    private var snapshotTaskID: String {
        let refreshToken = model.dashboardConversationRefreshTokens[chatSummary.chatId]
            ?? "0-\(snapshot?.detail.lastServerSeq ?? chatSummary.lastServerSeq)"
        return "\(chatSummary.chatId)-\(refreshToken)"
    }

    private func reload() {
        Task {
            await loadSnapshot()
        }
    }

    private func loadSnapshot() async {
        isLoadingSnapshot = true
        if snapshot == nil,
           let cachedSnapshot = model.cachedConversationSnapshot(chatId: chatSummary.chatId) {
            applyConversationSnapshot(cachedSnapshot)
        }
        localErrorMessage = nil

        defer {
            isLoadingSnapshot = false
        }

        do {
            let loadedSnapshot = try await model.fetchConversationSnapshot(
                baseURLString: serverBaseURL,
                chatId: chatSummary.chatId
            )
            applyConversationSnapshot(loadedSnapshot)
            if loadedSnapshot.latestMessageId != nil {
                _ = await model.acknowledgeConversationRead(
                    baseURLString: serverBaseURL,
                    chatId: loadedSnapshot.detail.chatId,
                    throughMessageId: loadedSnapshot.latestMessageId,
                    receiptTargetMessageId: readReceiptTargetMessageId(for: loadedSnapshot)
                )
            }
        } catch {
            localErrorMessage = TrixUserFacingText.conversationMessage(
                error,
                chatId: chatSummary.chatId,
                historySyncJobs: model.dashboard?.historySyncJobs ?? []
            )
        }
    }

    private func readReceiptTargetMessageId(for snapshot: SafeConversationSnapshot) -> String? {
        ConsumerConversationTimelineBuilder.latestIncomingNonReceiptMessageID(
            in: snapshot,
            currentAccountId: model.localIdentity?.accountId
        )
    }

    private func sendCurrentPayload() {
        if selectedAttachment != nil {
            sendAttachment()
        } else {
            sendText()
        }
    }

    private func sendText() {
        guard let snapshot else {
            return
        }

        let trimmedText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        localErrorMessage = nil
        activityMessage = nil

        Task {
            let draft = DebugMessageDraft(kind: .text, text: trimmedText)
            if let response = await model.postDebugMessage(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                draft: draft
            ) {
                composerText = ""
                publishTypingState(for: "", force: true)
                latestSentMessageId = response.messageId
                latestSentText = trimmedText
                activityMessage = TrixStrings.text(.chatMessageSent)
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func sendAttachment() {
        guard let snapshot, let selectedAttachment else {
            return
        }

        localErrorMessage = nil
        activityMessage = nil

        Task {
            if let outcome = await model.postDebugAttachment(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                fileURL: selectedAttachment.fileURL
            ) {
                composerText = ""
                publishTypingState(for: "", force: true)
                self.selectedAttachment = nil
                latestSentMessageId = outcome.createMessage.messageId
                let fallbackName = TrixStrings.text(.chatAttachmentDefaultName)
                latestSentText = outcome.fileName ?? fallbackName
                activityMessage = TrixStrings.text(
                    .chatAttachmentSent,
                    replacements: ["file_name": outcome.fileName ?? fallbackName]
                )
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func sendReaction(for message: ConsumerRenderedMessage, emoji: String) {
        guard let snapshot else {
            return
        }
        guard canReact else {
            localErrorMessage = TrixStrings.text(.chatReactionUnavailable)
            return
        }

        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmoji.isEmpty else {
            return
        }

        localErrorMessage = nil
        activityMessage = nil

        Task {
            let removeExisting = message.reactions.contains {
                $0.emoji == trimmedEmoji && $0.includesSelf
            }
            if await model.postReaction(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                targetMessageId: message.id,
                emoji: trimmedEmoji,
                removeExisting: removeExisting
            ) != nil {
                activityMessage = removeExisting
                    ? TrixStrings.text(.chatReactionRemoved)
                    : TrixStrings.text(.chatReactionAdded)
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func handleAttachmentImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(fileURL):
            do {
                selectedAttachment = try makeAttachmentDraft(fileURL: fileURL)
                localErrorMessage = nil
            } catch {
                localErrorMessage = error.trixUserFacingMessage
            }
        case let .failure(error):
            localErrorMessage = error.trixUserFacingMessage
        }
    }

    private func makeAttachmentDraft(fileURL: URL, preferredFileName: String? = nil) throws -> ConsumerAttachmentDraft {
        let didAccessScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let fallbackName = preferredFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFileName: String
        if let fallbackName, !fallbackName.isEmpty {
            rawFileName = fallbackName
        } else {
            rawFileName = fileURL.lastPathComponent
        }
        let fileName = rawFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileSizeLabel = try? fileURL
            .resourceValues(forKeys: [.fileSizeKey])
            .fileSize
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }

        return ConsumerAttachmentDraft(
            fileURL: fileURL,
            fileName: fileName.isEmpty ? TrixStrings.text(.chatAttachmentDefaultName) : fileName,
            fileSizeLabel: fileSizeLabel ?? nil
        )
    }

    #if os(iOS)
    @MainActor
    private func importPhotoVideoAttachment(from item: PhotosPickerItem) async {
        defer {
            selectedPhotoVideoItem = nil
        }

        do {
            let pickedMedia = try await makeTemporaryPhotoVideoAttachment(from: item)
            selectedAttachment = try makeAttachmentDraft(
                fileURL: pickedMedia.fileURL,
                preferredFileName: pickedMedia.fileName
            )
            localErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            localErrorMessage = error.trixUserFacingMessage
        }
    }

    private func makeTemporaryPhotoVideoAttachment(
        from item: PhotosPickerItem
    ) async throws -> (fileURL: URL, fileName: String) {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ConsumerAttachmentImportError.failedToLoadSelectedMedia
        }

        let contentType = item.supportedContentTypes.first(where: {
            $0.conforms(to: .image) || $0.conforms(to: .movie)
        }) ?? item.supportedContentTypes.first ?? .data
        let baseName: String
        if contentType.conforms(to: .movie) {
            baseName = TrixStrings.text(.chatVideoDefaultName)
        } else if contentType.conforms(to: .image) {
            baseName = TrixStrings.text(.chatPhotoDefaultName)
        } else {
            baseName = TrixStrings.text(.chatAttachmentDefaultName)
        }
        let fileExtension = contentType.preferredFilenameExtension ?? defaultAttachmentExtension(for: contentType)
        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("consumer-attachment-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)

        try data.write(to: tempFileURL, options: [.atomic])

        let displayName = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
        return (tempFileURL, displayName)
    }

    private func defaultAttachmentExtension(for contentType: UTType) -> String {
        if contentType.conforms(to: .movie) {
            return "mov"
        }

        if contentType.conforms(to: .image) {
            return "jpg"
        }

        return "bin"
    }
    #endif

    private func openAttachment(_ message: ConsumerRenderedMessage) {
        guard let attachmentBody = message.attachmentBody else {
            return
        }

        downloadingAttachmentMessageId = message.id
        localErrorMessage = nil
        activityMessage = TrixStrings.text(
            .chatDownloadingAttachment,
            replacements: ["title": message.primaryText]
        )

        Task {
            if let downloadedAttachment = await model.downloadAttachment(
                baseURLString: serverBaseURL,
                attachment: attachmentBody
            ) {
                self.downloadedAttachment = downloadedAttachment
                activityMessage = TrixStrings.text(
                    .chatAttachmentReadyToShare,
                    replacements: ["title": downloadedAttachment.fileName]
                )
            } else {
                localErrorMessage = model.errorMessage
                activityMessage = nil
            }

            downloadingAttachmentMessageId = nil
        }
    }

    private func publishTypingState(for text: String, force: Bool = false) {
        let shouldPublish = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard force || shouldPublish != isTypingPublished else {
            return
        }

        isTypingPublished = shouldPublish
        Task {
            await model.sendTypingUpdate(chatId: chatSummary.chatId, isTyping: shouldPublish)
        }
    }
}

enum ConsumerConversationTimelineBuilder {
    static func makeTimelineItems(
        for snapshot: SafeConversationSnapshot,
        fixtureManifest: UITestFixtureManifest? = nil
    ) -> [ConsumerTimelineItem] {
        makeRenderPayload(for: snapshot, fixtureManifest: fixtureManifest).items
    }

    static func makeRenderPayload(
        for snapshot: SafeConversationSnapshot,
        fixtureManifest: UITestFixtureManifest?
    ) -> ConsumerTimelineRenderPayload {
        // `loadConversationSnapshot()` already returns ascending server order, so keep typing cheap.
        let messages = snapshot.messages
        var items: [ConsumerTimelineItem] = []
        let participantDisplayNamesByAccountId = snapshot.detail.participantProfiles.reduce(into: [String: String]()) { partialResult, profile in
            partialResult[profile.accountId] = profile.primaryDisplayName
        }
        let fixtureKindsByMessageId = fixtureManifest?.messages.reduce(into: [String: UITestFixtureMessageKind]()) { partialResult, record in
            partialResult[record.messageId] = record.kind
        } ?? [:]
        let presentationMessages = messages.filter { message in
            !isReceiptMessage(message) && message.isVisibleInTimeline
        }
        var previousMessage: SafeMessengerMessage?

        for (index, message) in presentationMessages.enumerated() {
            if previousMessage.map({ !Calendar.current.isDate($0.createdAtDate, inSameDayAs: message.createdAtDate) }) ?? true {
                items.append(.daySeparator(daySeparatorTitle(for: message.createdAtDate)))
            }

            let nextMessage = presentationMessages.indices.contains(index + 1) ? presentationMessages[index + 1] : nil
            let continuesFromPrevious = previousMessage.map { canCluster($0, with: message) } ?? false
            let continuesToNext = nextMessage.map { canCluster(message, with: $0) } ?? false
            let senderName = participantDisplayNamesByAccountId[message.senderAccountId] ?? message.senderDisplayName
            let shouldShowSender = snapshot.detail.chatType == .group && !message.isOutgoing && !continuesFromPrevious
            let clusterPosition: ConsumerMessageClusterPosition

            if messageUsesCenteredEventStyle(message) {
                clusterPosition = .single
            } else if continuesFromPrevious && continuesToNext {
                clusterPosition = .middle
            } else if continuesFromPrevious {
                clusterPosition = .bottom
            } else if continuesToNext {
                clusterPosition = .top
            } else {
                clusterPosition = .single
            }

            let topSpacing: CGFloat
            if previousMessage == nil || !(previousMessage.map { Calendar.current.isDate($0.createdAtDate, inSameDayAs: message.createdAtDate) } ?? false) {
                topSpacing = 10
            } else if continuesFromPrevious {
                topSpacing = 4
            } else {
                topSpacing = 14
            }

            items.append(
                .message(
                    ConsumerRenderedMessage(
                        id: message.id,
                        senderAccountId: message.senderAccountId,
                        senderDeviceId: message.senderDeviceId,
                        contentType: messageContentType(message),
                        createdAtDate: message.createdAtDate,
                        isOutgoing: message.isOutgoing,
                        senderName: shouldShowSender ? senderName : nil,
                        attachmentBody: message.body?.attachment,
                        primaryText: messagePreviewTitle(message),
                        secondaryText: messagePreviewDetail(message),
                        clusterPosition: clusterPosition,
                        topSpacing: topSpacing,
                        usesCenteredEventStyle: messageUsesCenteredEventStyle(message),
                        receiptStatus: message.receiptStatus.map(ConsumerReceiptStatus.init),
                        reactions: message.reactions
                    )
                )
            )

            previousMessage = message
        }

        return ConsumerTimelineRenderPayload(
            items: items,
            fixtureKindsByMessageId: fixtureKindsByMessageId
        )
    }

    static func latestIncomingNonReceiptMessageID(
        in snapshot: SafeConversationSnapshot,
        currentAccountId: String?
    ) -> String? {
        guard let currentAccountId else {
            return nil
        }

        return snapshot.messages.reversed().first { message in
            message.isVisibleInTimeline
                && message.senderAccountId != currentAccountId
                && !isReceiptMessage(message)
        }?.id
    }

    private static func daySeparatorTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private static func canCluster(_ left: SafeMessengerMessage, with right: SafeMessengerMessage) -> Bool {
        guard !messageUsesCenteredEventStyle(left), !messageUsesCenteredEventStyle(right) else {
            return false
        }
        guard left.senderAccountId == right.senderAccountId else {
            return false
        }
        guard Calendar.current.isDate(left.createdAtDate, inSameDayAs: right.createdAtDate) else {
            return false
        }

        let delta = abs(right.createdAtDate.timeIntervalSince(left.createdAtDate))
        return delta <= consumerMessageClusterWindow
    }

    private static func messageContentType(_ message: SafeMessengerMessage) -> ContentType {
        switch effectiveBodyKind(for: message) {
        case .text:
            return .text
        case .reaction:
            return .reaction
        case .receipt:
            return .receipt
        case .attachment:
            return .attachment
        case .chatEvent:
            return .chatEvent
        }
    }

    private static func messageUsesCenteredEventStyle(_ message: SafeMessengerMessage) -> Bool {
        switch messageContentType(message) {
        case .reaction, .receipt, .chatEvent:
            return true
        case .text, .attachment:
            return false
        }
    }

    private static func messagePreviewTitle(_ message: SafeMessengerMessage) -> String {
        switch effectiveBodyKind(for: message) {
        case .text:
            return message.body?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (message.body?.text ?? message.previewText)
                : message.previewText
        case .reaction:
            let emoji = message.body?.emoji ?? ""
            let actionLabel = message.body?.reactionAction == .remove ? "Removed" : "Reacted"
            let summary = "\(actionLabel) \(emoji)".trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? message.previewText : summary
        case .receipt:
            return message.body?.receiptType == .read ? "Read receipt" : message.previewText
        case .attachment:
            return message.body?.attachment?.fileName ?? message.previewText
        case .chatEvent:
            return message.body?.eventType ?? message.previewText
        }
    }

    private static func messagePreviewDetail(_ message: SafeMessengerMessage) -> String? {
        switch effectiveBodyKind(for: message) {
        case .reaction, .receipt:
            return message.body?.targetMessageId.map { "Target \($0)" }
        case .attachment:
            guard let attachment = message.body?.attachment else {
                return nil
            }
            return "\(attachment.mimeType), \(attachment.sizeBytes) bytes"
        case .chatEvent:
            return message.body?.eventJSON
        case .text:
            return nil
        }
    }

    private static func fallbackBodyKind(for contentType: ContentType) -> SafeMessengerMessageBodyKind {
        switch contentType {
        case .text:
            .text
        case .reaction:
            .reaction
        case .receipt:
            .receipt
        case .attachment:
            .attachment
        case .chatEvent:
            .chatEvent
        }
    }

    private static func effectiveBodyKind(for message: SafeMessengerMessage) -> SafeMessengerMessageBodyKind {
        message.body?.kind ?? fallbackBodyKind(for: message.contentType)
    }

    private static func isReceiptMessage(_ message: SafeMessengerMessage) -> Bool {
        effectiveBodyKind(for: message) == .receipt
    }
}

private extension ConsumerReceiptStatus {
    init(_ value: SafeMessengerReceiptType) {
        switch value {
        case .delivered:
            self = .delivered
        case .read:
            self = .read
        }
    }
}

private struct ConsumerConversationTimelineView: View, Equatable {
    let renderState: ConsumerConversationTimelineRenderState
    let canReact: Bool
    let model: AppModel
    let serverBaseURLString: String
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void
    let onSelectReaction: (ConsumerRenderedMessage, String) -> Void

    nonisolated static func == (lhs: ConsumerConversationTimelineView, rhs: ConsumerConversationTimelineView) -> Bool {
        lhs.renderState == rhs.renderState && lhs.canReact == rhs.canReact
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        if UITestLaunchConfiguration.current.isEnabled {
                            VStack(spacing: 0) {
                                timelineRows()
                            }
                        } else {
                            LazyVStack(spacing: 0) {
                                timelineRows()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    scrollToBottom(using: proxy, animated: false)
                }
                .onChange(of: renderState.latestTimelineAnchorId) { _, _ in
                    scrollToBottom(using: proxy, animated: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.timeline)
        }
    }

    @ViewBuilder
    private func timelineRows() -> some View {
        if renderState.timelineItems.isEmpty {
            ContentUnavailableView(
                TrixStrings.text(.chatNoMessagesConsumerTitle),
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text(TrixStrings.text(.chatNoMessagesConsumerBody))
            )
            .padding(.top, 96)
        } else {
            ForEach(renderState.timelineItems) { item in
                ConsumerTimelineRow(
                    item: item,
                    fixtureKind: fixtureKind(for: item),
                    latestSentMessageId: renderState.latestSentMessageId,
                    latestSentText: renderState.latestSentText,
                    downloadingAttachmentMessageId: renderState.downloadingAttachmentMessageId,
                    canReact: canReact,
                    model: model,
                    serverBaseURLString: serverBaseURLString,
                    onOpenAttachment: onOpenAttachment,
                    onSelectReaction: onSelectReaction
                )
            }
        }

        Color.clear
            .frame(height: 1)
            .id(consumerTimelineBottomAnchor)
    }

    private func fixtureKind(for item: ConsumerTimelineItem) -> UITestFixtureMessageKind? {
        guard case let .message(message) = item else {
            return nil
        }

        return renderState.fixtureKindsByMessageId[message.id]
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(consumerTimelineBottomAnchor, anchor: .bottom)
        }

        if animated {
            withAnimation(.snappy(duration: 0.24)) {
                action()
            }
        } else {
            action()
        }
    }
}

private struct ConsumerChatBanner: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08))
    }
}

private struct ConsumerChatBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    TrixTheme.chatBackdropTop,
                    TrixTheme.chatBackdropBottom,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(TrixTheme.chatBackdropGlow)
                .frame(width: 320, height: 320)
                .blur(radius: 18)
                .offset(x: -120, y: -220)

            Circle()
                .fill(TrixTheme.chatAccentGlow)
                .frame(width: 280, height: 280)
                .blur(radius: 10)
                .offset(x: 140, y: 240)
        }
    }
}

private struct ConsumerTimelineRow: View {
    let item: ConsumerTimelineItem
    let fixtureKind: UITestFixtureMessageKind?
    let latestSentMessageId: String?
    let latestSentText: String?
    let downloadingAttachmentMessageId: String?
    let canReact: Bool
    let model: AppModel
    let serverBaseURLString: String
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void
    let onSelectReaction: (ConsumerRenderedMessage, String) -> Void

    var body: some View {
        if let fixtureKind {
            rowBody
                .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.message(fixtureKind))
        } else if isLatestSentMessage {
            rowBody
                .accessibilityIdentifier(TrixAccessibilityID.ChatDetail.latestSentMessage)
        } else {
            rowBody
        }
    }

    @ViewBuilder
    private var rowBody: some View {
        switch item {
        case let .daySeparator(label):
            ConsumerDaySeparator(label: label)
        case let .message(message):
            if message.usesCenteredEventStyle {
                ConsumerSystemEventRow(message: message)
            } else {
                ConsumerBubbleRow(
                    message: message,
                    isDownloadingAttachment: downloadingAttachmentMessageId == message.id,
                    canReact: canReact,
                    model: model,
                    serverBaseURLString: serverBaseURLString,
                    onOpenAttachment: onOpenAttachment,
                    onSelectReaction: onSelectReaction
                )
            }
        }
    }

    private var isLatestSentMessage: Bool {
        guard case let .message(message) = item else {
            return false
        }
        if message.id == latestSentMessageId {
            return true
        }
        guard message.isOutgoing, let latestSentText else {
            return false
        }
        return message.primaryText == latestSentText
    }
}

private struct ConsumerDaySeparator: View {
    let label: String

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(TrixTheme.chipSurface)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
                }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct ConsumerBubbleRow: View {
    let message: ConsumerRenderedMessage
    let isDownloadingAttachment: Bool
    let canReact: Bool
    let model: AppModel
    let serverBaseURLString: String
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void
    let onSelectReaction: (ConsumerRenderedMessage, String) -> Void

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 54)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if let senderName = message.senderName {
                    Text(senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(consumerChatAccent.opacity(0.88))
                        .padding(.horizontal, 8)
                }

                ConsumerMessageBubble(
                    message: message,
                    isDownloadingAttachment: isDownloadingAttachment,
                    canReact: canReact,
                    model: model,
                    serverBaseURLString: serverBaseURLString,
                    onOpenAttachment: onOpenAttachment,
                    onSelectReaction: onSelectReaction
                )

                if !message.reactions.isEmpty {
                    ConsumerReactionChipRow(
                        reactions: message.reactions,
                        isOutgoing: message.isOutgoing
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)

            if !message.isOutgoing {
                Spacer(minLength: 54)
            }
        }
        .padding(.top, message.topSpacing)
    }
}

private struct ConsumerMessageBubble: View {
    let message: ConsumerRenderedMessage
    let isDownloadingAttachment: Bool
    let canReact: Bool
    let model: AppModel
    let serverBaseURLString: String
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void
    let onSelectReaction: (ConsumerRenderedMessage, String) -> Void
    @State private var isReactionPickerPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch message.contentType {
            case .text:
                Text(message.primaryText)
                    .font(.body)
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .textSelection(.enabled)
            case .attachment:
                ConsumerAttachmentBubbleContent(
                    message: message,
                    isDownloading: isDownloadingAttachment,
                    model: model,
                    serverBaseURLString: serverBaseURLString,
                    onOpenAttachment: onOpenAttachment
                )
            case .reaction, .receipt, .chatEvent:
                EmptyView()
            }

            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if let receiptStatus = message.receiptStatus, message.isOutgoing {
                        Image(systemName: receiptStatus.systemImageName)
                            .font(.caption2.weight(.semibold))
                    }

                    Text(message.createdAtDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(message.isOutgoing ? .white.opacity(0.82) : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 320, alignment: message.isOutgoing ? .trailing : .leading)
        .background(message.isOutgoing ? consumerChatAccent : TrixTheme.incomingBubbleSurface)
        .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous)
                .stroke(message.isOutgoing ? .clear : TrixTheme.surfaceStroke, lineWidth: 1)
        }
        .shadow(
            color: message.isOutgoing ? consumerChatAccent.opacity(0.18) : TrixTheme.softShadow,
            radius: message.isOutgoing ? 14 : 10,
            y: message.isOutgoing ? 8 : 5
        )
        .contentShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .onLongPressGesture {
            guard canReact else {
                return
            }
            isReactionPickerPresented = true
        }
        .confirmationDialog(
            TrixStrings.text(.chatChooseReaction),
            isPresented: $isReactionPickerPresented,
            titleVisibility: .visible
        ) {
            ForEach(TrixCoreMessageBridge.defaultQuickReactionEmojis, id: \.self) { emoji in
                let includesSelf = message.reactions.contains {
                    $0.emoji == emoji && $0.includesSelf
                }
                Button(includesSelf ? "\(emoji) ✓" : emoji) {
                    onSelectReaction(message, emoji)
                }
            }
        }
    }

    private var bubbleCornerRadius: CGFloat {
        switch message.clusterPosition {
        case .single:
            return 24
        case .top, .bottom:
            return 21
        case .middle:
            return 18
        }
    }
}

private struct ConsumerReactionChipRow: View {
    let reactions: [SafeMessengerReactionSummary]
    let isOutgoing: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(reactions, id: \.emoji) { reaction in
                    Text(reactionLabel(reaction))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reaction.includesSelf ? consumerChatAccent : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TrixTheme.chipSurface, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(
                                    reaction.includesSelf
                                        ? consumerChatAccent.opacity(0.28)
                                        : TrixTheme.surfaceStroke,
                                    lineWidth: 1
                                )
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        }
        .scrollClipDisabled()
        .frame(maxWidth: 320, alignment: isOutgoing ? .trailing : .leading)
    }

    private func reactionLabel(_ reaction: SafeMessengerReactionSummary) -> String {
        reaction.count > 1 ? "\(reaction.emoji) \(reaction.count)" : reaction.emoji
    }
}

private struct ConsumerAttachmentBubbleContent: View {
    let message: ConsumerRenderedMessage
    let isDownloading: Bool
    let model: AppModel
    let serverBaseURLString: String
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void

    var body: some View {
        Button {
            onOpenAttachment(message)
        } label: {
            Group {
                if let attachment = message.attachmentBody,
                   ConsumerInlineAttachmentPreviewSupport.supports(attachment) {
                    VStack(alignment: .leading, spacing: 10) {
                        ConsumerInlineAttachmentPreview(
                            model: model,
                            serverBaseURLString: serverBaseURLString,
                            attachment: attachment,
                            isOutgoing: message.isOutgoing
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.primaryText)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(message.isOutgoing ? .white : .primary)
                                .lineLimit(2)

                            Text(detailLabel)
                                .font(.caption)
                                .foregroundStyle(message.isOutgoing ? .white.opacity(0.82) : .secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(message.isOutgoing ? Color.white.opacity(0.18) : consumerChatAccent.opacity(0.12))
                            .frame(width: 42, height: 42)
                            .overlay {
                                if isDownloading {
                                    ProgressView()
                                        .tint(message.isOutgoing ? .white : consumerChatAccent)
                                } else {
                                    Image(systemName: attachmentIconName)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(message.isOutgoing ? .white : consumerChatAccent)
                                }
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.primaryText)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(message.isOutgoing ? .white : .primary)
                                .lineLimit(2)

                            Text(detailLabel)
                                .font(.caption)
                                .foregroundStyle(message.isOutgoing ? .white.opacity(0.82) : .secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(message.attachmentBody == nil || isDownloading)
    }

    private var detailLabel: String {
        isDownloading
            ? TrixStrings.text(.chatAttachmentDecrypting)
            : (message.secondaryText ?? TrixStrings.text(.chatAttachmentTapToOpen))
    }

    private var attachmentIconName: String {
        let loweredTitle = message.primaryText.lowercased()
        if loweredTitle.hasSuffix(".jpg") || loweredTitle.hasSuffix(".jpeg") || loweredTitle.hasSuffix(".png") || loweredTitle.hasSuffix(".heic") {
            return "photo"
        }
        if loweredTitle.hasSuffix(".pdf") {
            return "doc.richtext"
        }
        return "paperclip"
    }
}

private struct ConsumerSystemEventRow: View {
    let message: ConsumerRenderedMessage

    var body: some View {
        VStack(spacing: 6) {
            Text(message.primaryText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let secondaryText = message.secondaryText {
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.82))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 280)
        .background(TrixTheme.systemEventSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TrixTheme.surfaceStroke, lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, message.topSpacing)
    }
}

private struct AttachmentActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension ContentType {
    var consumerSystemIconName: String {
        switch self {
        case .text:
            return "text.bubble"
        case .attachment:
            return "paperclip"
        case .reaction:
            return "face.smiling"
        case .receipt:
            return "checkmark.circle"
        case .chatEvent:
            return "sparkles"
        }
    }
}
