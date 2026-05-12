import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    @State private var isShowingPeerDevices = false
    @State private var isShowingGroupMembers = false
    @State private var isLoadingPeerDevices = false
    @State private var peerDevices: [TrixPeerDeviceIdentity] = []
    @State private var peerDeviceError: String?
    @State private var fileImportError: String?
    @State private var typingPauseTask: Task<Void, Never>?
    @State private var lastSentTypingState: TrixTypingState = .idle
    @State private var isShowingLocalForgetConfirmation = false
    @State private var isShowingGroupLeaveConfirmation = false

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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if timelineViewModel.items.isEmpty {
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
        .sheet(isPresented: $isShowingPeerDevices) {
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
        .sheet(isPresented: $isShowingGroupMembers) {
            TrixGroupMembersView(model: model, room: room)
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
            await model.selectRoom(room)
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
        room.isEncrypted || peerDevices.contains(where: \.canSendEncrypted)
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

    private var encryptionRequiredBanner: some View {
        HStack(spacing: 10) {
            TrixBannerView(
                text: "OMEMO is required for Trix chats. Trust a contact device before sending.",
                systemImage: "lock.slash.fill",
                tint: .orange
            )
            .layoutPriority(1)

            Button {
                showPeerDevices()
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
        if timelineViewModel.isLoading {
            ProgressView("Loading timeline")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 36)
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

    private var timelineEntries: [TrixTimelineEntry] {
        Self.timelineEntries(for: timelineViewModel.items)
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
                    showPeerDevices()
                } label: {
                    Image(systemName: "checkmark.shield")
                }
                .help("OMEMO devices")
            } else {
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

    private func showPeerDevices() {
        isShowingPeerDevices = true
        Task {
            await loadPeerDevices(refresh: true)
        }
    }

    private func importAttachment(from result: Result<[URL], Error>) {
        do {
            guard canSendEncryptedAttachments else {
                throw timelineViewModel.attachmentSendAvailability?.blockReason.map { TrixAttachmentImportError.blocked($0.message) }
                    ?? TrixAttachmentImportError.blocked("Encrypted attachments are not available yet.")
            }

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

    private func readAttachmentUpload(from url: URL) throws -> TrixAttachmentUpload {
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

    private static func displayName(from userID: String) -> String {
        let localpart = userID
            .split(separator: "@")
            .first
            .map(String.init)

        return localpart?.capitalized ?? userID
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
                            loadInlinePreview: loadInlineAttachmentPreview
                        )
                    } else {
                        Text(item.body)
                            .font(.body)
                            .foregroundStyle(item.isLocalEcho ? .white : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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

                    Label("Encrypted attachment", systemImage: "lock.fill")
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
        }
    }

    private var attachmentButtonImage: String {
        if isDownloading {
            return "hourglass"
        }

        return attachment.isImage ? "eye.circle.fill" : "arrow.down.circle.fill"
    }

    private var attachmentButtonHelp: String {
        if failureMessage != nil {
            return "Retry encrypted attachment download"
        }

        if attachment.isImage {
            return "Download and preview encrypted image"
        }

        return "Download encrypted attachment"
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
