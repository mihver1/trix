import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let consumerChatAccent = Color(red: 0.14, green: 0.55, blue: 0.98)
private let consumerMessageClusterWindow: TimeInterval = 5 * 60
private let consumerTimelineBottomAnchor = "consumer-timeline-bottom-anchor"

private struct ConsumerAttachmentDraft {
    let fileURL: URL
    let fileName: String
    let fileSizeLabel: String?
}

private enum ConsumerTimelineItem: Identifiable {
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

private enum ConsumerMessageClusterPosition {
    case single
    case top
    case middle
    case bottom
}

private enum ConsumerReceiptStatus: Int, Comparable {
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

private struct ConsumerRenderedMessage: Identifiable {
    let id: String
    let senderAccountId: String
    let senderDeviceId: String
    let contentType: ContentType
    let createdAtDate: Date
    let isOutgoing: Bool
    let senderName: String?
    let attachmentBody: FfiMessageBody?
    let primaryText: String
    let secondaryText: String?
    let clusterPosition: ConsumerMessageClusterPosition
    let topSpacing: CGFloat
    let usesCenteredEventStyle: Bool
    let receiptStatus: ConsumerReceiptStatus?
}

struct ConsumerChatDetailView: View {
    let chatSummary: ChatSummary
    @Binding var serverBaseURL: String
    @ObservedObject var model: AppModel

    @State private var snapshot: ChatSnapshot?
    @State private var isLoadingSnapshot = false
    @State private var composerText = ""
    @State private var selectedAttachment: ConsumerAttachmentDraft?
    @State private var isImportingAttachment = false
    @State private var localErrorMessage: String?
    @State private var activityMessage: String?
    @State private var downloadedAttachment: DownloadedAttachmentFile?
    @State private var downloadingAttachmentMessageId: String?
    @State private var isTypingPublished = false

    var body: some View {
        VStack(spacing: 0) {
            if let activityMessage {
                ConsumerChatBanner(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    text: activityMessage
                )
            }

            if let localErrorMessage {
                ConsumerChatBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    text: localErrorMessage
                )
            }

            if let snapshot {
                conversationTimeline(for: snapshot)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composer
                    }
            } else {
                Spacer()

                if isLoadingSnapshot {
                    ProgressView("Loading Conversation")
                } else {
                    ContentUnavailableView(
                        "Conversation Unavailable",
                        systemImage: "icloud.slash",
                        description: Text(localErrorMessage ?? "The chat snapshot could not be loaded.")
                    )
                }

                Spacer()
            }
        }
        .background(ConsumerChatBackdrop().ignoresSafeArea())
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || isLoadingSnapshot)
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
        .sheet(item: $downloadedAttachment) { downloadedAttachment in
            AttachmentActivitySheet(items: [downloadedAttachment.fileURL])
        }
        .onChange(of: composerText) { _, newValue in
            publishTypingState(for: newValue)
        }
        .onDisappear {
            publishTypingState(for: "", force: true)
        }
    }

    private func conversationTimeline(for snapshot: ChatSnapshot) -> some View {
        let timelineItems = makeTimelineItems(for: snapshot)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if timelineItems.isEmpty {
                        ContentUnavailableView(
                            "No Messages Yet",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Start the conversation. New messages will appear here in a normal chat timeline.")
                        )
                        .padding(.top, 96)
                    } else {
                        ForEach(timelineItems) { item in
                            ConsumerTimelineRow(
                                item: item,
                                downloadingAttachmentMessageId: downloadingAttachmentMessageId,
                                onOpenAttachment: openAttachment
                            )
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(consumerTimelineBottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: snapshot.latestTimelineAnchorId) { _, _ in
                scrollToBottom(using: proxy, animated: true)
            }
        }
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

                        Text(selectedAttachment.fileSizeLabel ?? "Ready to send")
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
                .background(Color.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    isImportingAttachment = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(consumerChatAccent)
                        .frame(width: 38, height: 38)
                }

                if selectedAttachment == nil {
                    TextField(
                        "Message",
                        text: $composerText,
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    Text("Attachments send as secure files. Captions come next.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.88))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                Button(action: sendCurrentPayload) {
                    Image(systemName: canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? consumerChatAccent : .secondary)
                }
                .disabled(!canSend || model.isLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        selectedAttachment != nil || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var conversationTitle: String {
        if let detail = snapshot?.detail {
            return detail.resolvedTitle(currentAccountId: model.localIdentity?.accountId)
        }

        return chatSummary.resolvedTitle(currentAccountId: model.localIdentity?.accountId)
    }

    private var snapshotTaskID: String {
        let latestInboxId = model.dashboard?
            .inboxItems
            .filter { $0.message.chatId == chatSummary.chatId }
            .map(\.inboxId)
            .max() ?? 0
        let latestServerSeq = model.dashboard?
            .chats
            .first { $0.chatId == chatSummary.chatId }?
            .lastServerSeq ?? chatSummary.lastServerSeq

        return "\(chatSummary.chatId)-\(latestInboxId)-\(latestServerSeq)"
    }

    private func reload() {
        Task {
            await loadSnapshot()
        }
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

    private func loadSnapshot() async {
        isLoadingSnapshot = true
        localErrorMessage = nil

        defer {
            isLoadingSnapshot = false
        }

        do {
            let loadedSnapshot = try await model.fetchChatSnapshot(
                baseURLString: serverBaseURL,
                chatId: chatSummary.chatId
            )
            snapshot = loadedSnapshot
            if loadedSnapshot.detail.lastServerSeq > 0 {
                _ = await model.acknowledgeChatRead(
                    baseURLString: serverBaseURL,
                    chatId: loadedSnapshot.detail.chatId,
                    throughServerSeq: loadedSnapshot.detail.lastServerSeq,
                    receiptTargetMessageId: readReceiptTargetMessageId(for: loadedSnapshot)
                )
            }
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }

    private func readReceiptTargetMessageId(for snapshot: ChatSnapshot) -> String? {
        guard let currentAccountId = model.localIdentity?.accountId else {
            return nil
        }

        let orderedHistory = snapshot.history.sorted {
            if $0.serverSeq == $1.serverSeq {
                return $0.createdAtUnix < $1.createdAtUnix
            }
            return $0.serverSeq < $1.serverSeq
        }

        return orderedHistory.reversed().first { message in
            message.senderAccountId != currentAccountId && message.contentType != .receipt
        }?.id
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
            if await model.postDebugMessage(
                baseURLString: serverBaseURL,
                chatId: snapshot.detail.chatId,
                epoch: snapshot.detail.epoch,
                draft: draft
            ) != nil {
                composerText = ""
                publishTypingState(for: "", force: true)
                activityMessage = "Message sent"
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
                epoch: snapshot.detail.epoch,
                fileURL: selectedAttachment.fileURL
            ) {
                composerText = ""
                publishTypingState(for: "", force: true)
                self.selectedAttachment = nil
                activityMessage = "Sent \(outcome.fileName ?? "attachment")"
                await loadSnapshot()
            } else {
                localErrorMessage = model.errorMessage
            }
        }
    }

    private func handleAttachmentImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(fileURL):
            let didAccessScopedResource = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessScopedResource {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let fileName = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileSizeLabel = try? fileURL
                .resourceValues(forKeys: [.fileSizeKey])
                .fileSize
                .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            selectedAttachment = ConsumerAttachmentDraft(
                fileURL: fileURL,
                fileName: fileName.isEmpty ? "Attachment" : fileName,
                fileSizeLabel: fileSizeLabel ?? nil
            )
            localErrorMessage = nil
        case let .failure(error):
            localErrorMessage = error.localizedDescription
        }
    }

    private func openAttachment(_ message: ConsumerRenderedMessage) {
        guard let attachmentBody = message.attachmentBody else {
            return
        }

        downloadingAttachmentMessageId = message.id
        localErrorMessage = nil
        activityMessage = "Downloading \(message.primaryText)"

        Task {
            if let downloadedAttachment = await model.downloadAttachment(
                baseURLString: serverBaseURL,
                body: attachmentBody
            ) {
                self.downloadedAttachment = downloadedAttachment
                activityMessage = "Ready to share \(downloadedAttachment.fileName)"
            } else {
                localErrorMessage = model.errorMessage
                activityMessage = nil
            }

            downloadingAttachmentMessageId = nil
        }
    }

    private func makeTimelineItems(for snapshot: ChatSnapshot) -> [ConsumerTimelineItem] {
        if !snapshot.localTimelineItems.isEmpty {
            return makeProjectedTimelineItems(
                snapshot.localTimelineItems,
                chatType: snapshot.detail.chatType
            )
        }

        let currentAccountId = model.localIdentity?.accountId
        let messages = snapshot.history.sorted {
            if $0.serverSeq == $1.serverSeq {
                return $0.createdAtUnix < $1.createdAtUnix
            }
            return $0.serverSeq < $1.serverSeq
        }
        var items: [ConsumerTimelineItem] = []
        var receiptStatusByMessageId: [String: ConsumerReceiptStatus] = [:]
        let presentationMessages = messages.compactMap { message -> MessageEnvelope? in
            guard isReceiptMessage(message) else {
                return message
            }

            if let targetMessageId = receiptTargetMessageId(for: message) {
                receiptStatusByMessageId[targetMessageId] = mergedReceiptStatus(
                    receiptStatusByMessageId[targetMessageId],
                    with: receiptStatus(for: message) ?? .delivered
                )
            }
            return nil
        }
        var previousMessage: MessageEnvelope?

        for (index, message) in presentationMessages.enumerated() {
            if previousMessage.map({ !Calendar.current.isDate($0.createdAtDate, inSameDayAs: message.createdAtDate) }) ?? true {
                items.append(.daySeparator(daySeparatorTitle(for: message.createdAtDate)))
            }

            let nextMessage = presentationMessages.indices.contains(index + 1) ? presentationMessages[index + 1] : nil
            let continuesFromPrevious = previousMessage.map { canCluster($0, with: message) } ?? false
            let continuesToNext = nextMessage.map { canCluster(message, with: $0) } ?? false
            let isOutgoing = currentAccountId.map { message.senderAccountId == $0 } ?? false
            let senderName = snapshot.detail
                .participantProfile(accountId: message.senderAccountId)?
                .primaryDisplayName
            let shouldShowSender = snapshot.detail.chatType == .group && !isOutgoing && !continuesFromPrevious
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
                        contentType: message.contentType,
                        createdAtDate: message.createdAtDate,
                        isOutgoing: isOutgoing,
                        senderName: shouldShowSender ? senderName : nil,
                        attachmentBody: TrixCoreMessageBridge.attachmentBody(for: message),
                        primaryText: TrixCoreMessageBridge.preview(for: message)?.title ?? message.debugPreview,
                        secondaryText: TrixCoreMessageBridge.preview(for: message)?.detail ?? message.debugDetail,
                        clusterPosition: clusterPosition,
                        topSpacing: topSpacing,
                        usesCenteredEventStyle: messageUsesCenteredEventStyle(message),
                        receiptStatus: receiptStatusByMessageId[message.id]
                    )
                )
            )

            previousMessage = message
        }

        return items
    }

    private func makeProjectedTimelineItems(
        _ timeline: [LocalTimelineItemSnapshot],
        chatType: ChatType
    ) -> [ConsumerTimelineItem] {
        let sortedItems = timeline.sorted {
            if $0.serverSeq == $1.serverSeq {
                return $0.createdAtUnix < $1.createdAtUnix
            }
            return $0.serverSeq < $1.serverSeq
        }
        var items: [ConsumerTimelineItem] = []
        var receiptStatusByMessageId: [String: ConsumerReceiptStatus] = [:]
        let presentationItems = sortedItems.compactMap { item -> LocalTimelineItemSnapshot? in
            guard isReceiptItem(item) else {
                return item
            }

            if let targetMessageId = receiptTargetMessageId(for: item) {
                receiptStatusByMessageId[targetMessageId] = mergedReceiptStatus(
                    receiptStatusByMessageId[targetMessageId],
                    with: receiptStatus(for: item) ?? .delivered
                )
            }
            return nil
        }
        var previousItem: LocalTimelineItemSnapshot?

        for (index, item) in presentationItems.enumerated() {
            if previousItem.map({ !Calendar.current.isDate($0.createdAtDate, inSameDayAs: item.createdAtDate) }) ?? true {
                items.append(.daySeparator(daySeparatorTitle(for: item.createdAtDate)))
            }

            let nextItem = presentationItems.indices.contains(index + 1) ? presentationItems[index + 1] : nil
            let continuesFromPrevious = previousItem.map { canCluster($0, with: item) } ?? false
            let continuesToNext = nextItem.map { canCluster(item, with: $0) } ?? false
            let shouldShowSender = chatType == .group && !item.isOutgoing && !continuesFromPrevious
            let clusterPosition: ConsumerMessageClusterPosition

            if projectedItemUsesCenteredEventStyle(item) {
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
            if previousItem == nil || !(previousItem.map { Calendar.current.isDate($0.createdAtDate, inSameDayAs: item.createdAtDate) } ?? false) {
                topSpacing = 10
            } else if continuesFromPrevious {
                topSpacing = 4
            } else {
                topSpacing = 14
            }

            items.append(
                .message(
                    ConsumerRenderedMessage(
                        id: item.id,
                        senderAccountId: item.senderAccountId,
                        senderDeviceId: item.senderDeviceId,
                        contentType: item.contentType,
                        createdAtDate: item.createdAtDate,
                        isOutgoing: item.isOutgoing,
                        senderName: shouldShowSender ? item.senderDisplayName : nil,
                        attachmentBody: item.contentType == .attachment ? item.messageBody : nil,
                        primaryText: item.bodyPreview?.title ?? item.previewText,
                        secondaryText: item.bodyPreview?.detail,
                        clusterPosition: clusterPosition,
                        topSpacing: topSpacing,
                        usesCenteredEventStyle: projectedItemUsesCenteredEventStyle(item),
                        receiptStatus: receiptStatusByMessageId[item.id]
                    )
                )
            )

            previousItem = item
        }

        return items
    }

    private func daySeparatorTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func canCluster(_ left: MessageEnvelope, with right: MessageEnvelope) -> Bool {
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

    private func canCluster(_ left: LocalTimelineItemSnapshot, with right: LocalTimelineItemSnapshot) -> Bool {
        guard !projectedItemUsesCenteredEventStyle(left), !projectedItemUsesCenteredEventStyle(right) else {
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

    private func messageUsesCenteredEventStyle(_ message: MessageEnvelope) -> Bool {
        switch message.contentType {
        case .reaction, .receipt, .chatEvent:
            return true
        case .text, .attachment:
            return false
        }
    }

    private func projectedItemUsesCenteredEventStyle(_ item: LocalTimelineItemSnapshot) -> Bool {
        switch item.projectionKind {
        case .applicationMessage:
            switch item.contentType {
            case .reaction, .receipt, .chatEvent:
                return true
            case .text, .attachment:
                return false
            }
        case .proposalQueued, .commitMerged, .welcomeRef, .system:
            return true
        }
    }

    private func receiptStatus(for message: MessageEnvelope) -> ConsumerReceiptStatus? {
        guard message.contentType == .receipt,
              let body = TrixCoreMessageBridge.parsedBody(for: message),
              body.kind == .receipt else {
            return nil
        }

        return body.receiptType == .read ? .read : .delivered
    }

    private func receiptStatus(for item: LocalTimelineItemSnapshot) -> ConsumerReceiptStatus? {
        guard item.contentType == .receipt || item.messageBody?.kind == .receipt else {
            return nil
        }

        return item.messageBody?.receiptType == .read ? .read : .delivered
    }

    private func isReceiptMessage(_ message: MessageEnvelope) -> Bool {
        message.contentType == .receipt
    }

    private func isReceiptItem(_ item: LocalTimelineItemSnapshot) -> Bool {
        item.contentType == .receipt || item.messageBody?.kind == .receipt
    }

    private func receiptTargetMessageId(for message: MessageEnvelope) -> String? {
        guard let body = TrixCoreMessageBridge.parsedBody(for: message), body.kind == .receipt else {
            return nil
        }

        return body.targetMessageId
    }

    private func receiptTargetMessageId(for item: LocalTimelineItemSnapshot) -> String? {
        guard item.contentType == .receipt || item.messageBody?.kind == .receipt else {
            return nil
        }

        return item.messageBody?.targetMessageId
    }

    private func mergedReceiptStatus(
        _ current: ConsumerReceiptStatus?,
        with next: ConsumerReceiptStatus
    ) -> ConsumerReceiptStatus {
        current.map { max($0, next) } ?? next
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
                    Color(red: 0.95, green: 0.98, blue: 1.0),
                    Color(red: 0.90, green: 0.95, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 320, height: 320)
                .blur(radius: 18)
                .offset(x: -120, y: -220)

            Circle()
                .fill(consumerChatAccent.opacity(0.11))
                .frame(width: 280, height: 280)
                .blur(radius: 10)
                .offset(x: 140, y: 240)
        }
    }
}

private struct ConsumerTimelineRow: View {
    let item: ConsumerTimelineItem
    let downloadingAttachmentMessageId: String?
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void

    var body: some View {
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
                    onOpenAttachment: onOpenAttachment
                )
            }
        }
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
                .background(.white.opacity(0.8))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct ConsumerBubbleRow: View {
    let message: ConsumerRenderedMessage
    let isDownloadingAttachment: Bool
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void

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
                    onOpenAttachment: onOpenAttachment
                )
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
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void

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
        .background(message.isOutgoing ? consumerChatAccent : Color.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius, style: .continuous))
        .shadow(
            color: message.isOutgoing ? consumerChatAccent.opacity(0.18) : .black.opacity(0.05),
            radius: message.isOutgoing ? 14 : 10,
            y: message.isOutgoing ? 8 : 5
        )
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

private struct ConsumerAttachmentBubbleContent: View {
    let message: ConsumerRenderedMessage
    let isDownloading: Bool
    let onOpenAttachment: (ConsumerRenderedMessage) -> Void

    var body: some View {
        Button {
            onOpenAttachment(message)
        } label: {
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

                    Text(isDownloading ? "Decrypting secure attachment..." : (message.secondaryText ?? "Tap to open"))
                        .font(.caption)
                        .foregroundStyle(message.isOutgoing ? .white.opacity(0.82) : .secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(message.attachmentBody == nil || isDownloading)
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
        .background(.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
