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

private struct TrixMentionProfileSelection: Identifiable {
    let userID: String

    var id: String {
        trixNormalizedUserKey(userID)
    }
}

struct TrixTimelineView: View {
    @ObservedObject var model: TrixAppModel
    let room: TrixRoomSummary
    @ObservedObject private var timelineViewModel: TimelineViewModel
    @ObservedObject private var callViewModel: TrixCallViewModel
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
    @State private var isShowingNotificationSettings = false
    @State private var mentionMembers: [TrixRoomMember] = []
    @State private var isLoadingMentionMembers = false
    @State private var selectedMentionTargets: [String: TrixRoomMember] = [:]
    @State private var replyDraftTarget: TrixTimelineItem?
    @State private var threadDraftTarget: TrixTimelineItem?
    @State private var editingItem: TrixTimelineItem?
    @State private var retractionCandidate: TrixTimelineItem?
    @State private var activeThreadFilter: TrixTimelineThreadFilter?
    @State private var lastDisplayedMarkerMessageID: String?
    @State private var selectedMentionProfile: TrixMentionProfileSelection?

    init(model: TrixAppModel, room: TrixRoomSummary) {
        self.model = model
        self.room = room
        self._timelineViewModel = ObservedObject(wrappedValue: model.timelineViewModel)
        self._callViewModel = ObservedObject(wrappedValue: model.callViewModel)
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
                                    currentUserID: currentUserID,
                                    roomKind: room.kind,
                                    threadReplyCount: threadReplyCount(for: presentation.item),
                                    canEdit: canEdit(presentation.item),
                                    canRetract: canRetract(presentation.item),
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
                                    reply: {
                                        startReply(to: presentation.item)
                                    },
                                    replyInThread: {
                                        startThreadReply(to: presentation.item)
                                    },
                                    edit: {
                                        startEditing(presentation.item)
                                    },
                                    retract: {
                                        retractionCandidate = presentation.item
                                    },
                                    openThread: {
                                        openThread(for: presentation.item)
                                    },
                                    openMention: { userID in
                                        openMentionProfile(userID)
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
                    markLatestVisibleMessageDisplayed(items)
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
        .sheet(isPresented: $isShowingNotificationSettings) {
            TrixRoomNotificationSettingsView(model: model, room: room)
        }
        .sheet(item: $selectedMentionProfile) { selection in
            TrixMentionProfileView(model: model, userID: selection.userID)
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
            "Leave this group?",
            isPresented: $isShowingGroupLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                Task {
                    await model.leaveGroup(room)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will leave this private group and stop receiving updates unless someone adds you again. Other members keep the group.")
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(
                get: { retractionCandidate != nil },
                set: { isPresented in
                    if !isPresented {
                        retractionCandidate = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Message", role: .destructive) {
                guard let item = retractionCandidate else {
                    return
                }
                retractionCandidate = nil
                Task {
                    await model.retractMessage(item)
                }
            }
            Button("Cancel", role: .cancel) {
                retractionCandidate = nil
            }
        } message: {
            Text("Recipients may already have archived copies. Trix will show a tombstone where supported.")
        }
        .task(id: room.id) {
            resetDeviceTrustState()
            resetComposerState()
            if timelineViewModel.roomID != room.id {
                await model.selectRoom(room)
            }
            await loadMentionMembers()
            markLatestVisibleMessageDisplayed(timelineViewModel.items)
            await loadPeerDevices(refresh: false)
            await model.loadAttachmentSendAvailability(roomID: room.id)
            await model.loadCallState(for: room)
        }
        .task(id: "typing-\(room.id)") {
            while !Task.isCancelled {
                await model.loadTypingState(roomID: room.id)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: "calls-\(room.id)") {
            while !Task.isCancelled {
                await model.loadCallState(for: room)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: draft) { _, newValue in
            handleDraftChange(newValue)
        }
        .task(id: timelineToastMessage) {
            guard let message = timelineToastMessage else {
                return
            }

            try? await Task.sleep(for: TrixTransientBanner.autoDismissDelay)
            guard !Task.isCancelled else {
                return
            }

            await dismissTimelineToast(matching: message)
        }
        .task(id: model.stickerImportMessage) {
            guard let message = model.stickerImportMessage else {
                return
            }

            try? await Task.sleep(for: TrixTransientBanner.autoDismissDelay)
            guard !Task.isCancelled else {
                return
            }

            await dismissStickerImportMessage(matching: message)
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

    private var currentUserID: String? {
        model.account?.userID ?? model.session?.userID
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
                    tint: .red,
                    dismissAction: dismissTimelineToast
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let stickerImportMessage = model.stickerImportMessage {
                TrixBannerView(
                    text: stickerImportMessage,
                    systemImage: "face.smiling",
                    tint: TrixDesign.accent,
                    dismissAction: model.dismissStickerImportMessage
                )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let callErrorMessage = callViewModel.errorMessage {
                TrixBannerView(
                    text: callErrorMessage,
                    systemImage: "video.badge.exclamationmark",
                    tint: .orange,
                    dismissAction: callViewModel.dismissErrorMessage
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            callControls

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

            if let activeThreadFilter {
                TrixThreadFilterBar(
                    filter: activeThreadFilter,
                    close: {
                        closeThread()
                    }
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

    @ViewBuilder
    private var callControls: some View {
        let callState = callViewModel.callLifecycleState(roomID: room.id)
        if room.kind == .direct {
            if callState.phase == .incomingRinging,
               let incomingCall = callViewModel.incomingDirectCall(roomID: room.id) {
                TrixIncomingDirectCallBar(
                    callerTitle: callParticipantTitle(incomingCall.callerID),
                    isWorking: callState.isActing || callViewModel.isActing(roomID: room.id),
                    accept: {
                        Task.detached(priority: .userInitiated) {
                            await model.acceptIncomingDirectCall(incomingCall)
                        }
                    },
                    decline: {
                        Task.detached(priority: .userInitiated) {
                            await model.declineIncomingDirectCall(incomingCall)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else if callState.platformSurfaceState == .directCallBar || callState.phase == .connecting {
                let activeCall = callViewModel.currentCall(roomID: room.id, kind: .directVideo)
                TrixDirectCallBar(
                    title: directCallTitle(for: callState),
                    subtitle: activeCall?.liveKitRoom ?? directCallSubtitle(for: callState),
                    activeCall: activeCall,
                    state: callState,
                    isWorking: callState.isActing || callViewModel.isActing(roomID: room.id),
                    setMicrophoneMuted: { muted in
                        Task.detached(priority: .userInitiated) {
                            await model.setCallMicrophoneMuted(muted, in: room)
                        }
                    },
                    setCameraEnabled: { enabled in
                        Task.detached(priority: .userInitiated) {
                            await model.setCallCameraEnabled(enabled, in: room)
                        }
                    },
                    end: {
                        Task.detached(priority: .userInitiated) {
                            await model.leaveCall(in: room)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        } else {
            TrixGroupVoiceRoomBar(
                snapshot: callViewModel.groupVoiceRoom(roomID: room.id),
                participantTitle: callParticipantTitle,
                isJoined: callState.kind == .groupVoice && callViewModel.currentCall(roomID: room.id, kind: .groupVoice) != nil,
                isWorking: callState.isActing || callViewModel.isActing(roomID: room.id),
                join: {
                    Task.detached(priority: .userInitiated) {
                        await model.joinGroupVoiceRoom(in: room)
                    }
                },
                leave: {
                    Task.detached(priority: .userInitiated) {
                        await model.leaveCall(in: room)
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func directCallTitle(for state: TrixCallLifecycleState) -> String {
        switch state.phase {
        case .connecting:
            return "Connecting video call"
        case .reconnecting:
            return "Reconnecting video call"
        case .ending:
            return "Ending video call"
        default:
            return "Video call"
        }
    }

    private func directCallSubtitle(for state: TrixCallLifecycleState) -> String {
        switch state.remoteMediaReadiness {
        case .ready:
            return "Encrypted media ready"
        case .waiting:
            return "Waiting for encrypted media"
        case .none:
            return state.callID ?? "Encrypted media"
        }
    }

    private func canStartDirectVideoCall(with state: TrixCallLifecycleState) -> Bool {
        switch state.phase {
        case .idle, .ended, .failed:
            return true
        case .outgoingPreparing, .outgoingRinging, .incomingRinging, .connecting, .active, .reconnecting, .ending:
            return false
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let editingItem {
                TrixComposerContextBanner(
                    systemImage: "pencil",
                    title: "Edit message",
                    subtitle: quotePreviewText(for: editingItem),
                    tint: TrixDesign.accent,
                    clear: cancelComposerContext
                )
            } else if activeThreadFilter == nil,
                      let threadTarget = activeThreadComposerTarget {
                TrixComposerContextBanner(
                    systemImage: "text.bubble",
                    title: "Thread",
                    subtitle: quotePreviewText(for: threadTarget),
                    tint: TrixDesign.groupAccent,
                    clear: clearThreadContext
                )
            } else if let replyDraftTarget {
                TrixComposerContextBanner(
                    systemImage: "arrowshape.turn.up.left",
                    title: "Reply",
                    subtitle: quotePreviewText(for: replyDraftTarget),
                    tint: TrixDesign.accent,
                    clear: cancelComposerContext
                )
            }

            if let mentionQuery = activeMentionQuery,
               !filteredMentionMembers(for: mentionQuery).isEmpty {
                TrixMentionPickerView(
                    members: filteredMentionMembers(for: mentionQuery),
                    isLoading: isLoadingMentionMembers,
                    select: insertMention
                )
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
                            .foregroundStyle(TrixDesign.accent)
                            .frame(width: 38, height: 38)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(timelineViewModel.isSendingAttachment || !canSendEncryptedAttachments || editingItem != nil)
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
                .disabled(editingItem != nil)
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
                .help(editingItem == nil ? "Send message" : "Save edit")
            }
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

        guard let activeThreadFilter else {
            return timelineViewModel.items
        }

        return timelineViewModel.items.filter { item in
            item.id == activeThreadFilter.rootMessageID ||
                item.thread?.threadID == activeThreadFilter.threadID ||
                item.thread?.rootMessageID == activeThreadFilter.rootMessageID
        }
    }

    private var timelineToastMessage: String? {
        timelineViewModel.errorMessage ?? fileImportError
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

    private var activeThreadComposerTarget: TrixTimelineItem? {
        if let threadDraftTarget {
            return threadDraftTarget
        }

        guard let activeThreadFilter else {
            return nil
        }

        return timelineViewModel.items.first { item in
            item.id == activeThreadFilter.rootMessageID
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendEncrypted,
              !timelineViewModel.isSending,
              !text.isEmpty else {
            return
        }

        sendTypingStateIfNeeded(.paused)

        if let editingItem {
            Task {
                let didEdit = await model.editTextMessage(
                    messageID: editingItem.id,
                    newText: text
                )
                guard didEdit else {
                    return
                }

                draft = ""
                self.editingItem = nil
                selectedMentionTargets = [:]
            }
            return
        }

        let metadata = sendMetadata(for: text)
        let shouldWaitForResult = !metadata.isEmpty
        if !shouldWaitForResult {
            draft = ""
            selectedMentionTargets = [:]
            replyDraftTarget = nil
            threadDraftTarget = nil
        }

        Task {
            let didSend = await model.send(text: text, metadata: metadata)
            guard didSend, shouldWaitForResult else {
                return
            }

            draft = ""
            selectedMentionTargets = [:]
            replyDraftTarget = nil
            threadDraftTarget = nil
        }
    }

    private func sendMetadata(for text: String) -> TrixTextMessageSendMetadata {
        TrixTextMessageSendMetadata(
            mentions: mentionReferences(in: text),
            replyTo: replyDraftTarget.map(replyReference),
            thread: activeThreadComposerTarget.map(threadReference)
        )
    }

    private func mentionReferences(in text: String) -> [TrixMentionReference] {
        selectedMentionTargets.values.flatMap { member in
            let token = mentionToken(for: member)
            var references: [TrixMentionReference] = []
            var searchStart = text.startIndex

            while searchStart < text.endIndex,
                  let range = text.range(of: token, range: searchStart..<text.endIndex) {
                let begin = range.lowerBound.utf16Offset(in: text)
                let end = range.upperBound.utf16Offset(in: text)
                let referenceRange = TrixTextReferenceRange(begin: begin, end: end)
                if referenceRange.isValid(in: text) {
                    references.append(
                        TrixMentionReference(
                            targetUserID: member.userID,
                            displayText: token,
                            range: referenceRange
                        )
                    )
                }
                searchStart = range.upperBound
            }

            return references
        }
        .sorted { lhs, rhs in
            if lhs.range.begin != rhs.range.begin {
                return lhs.range.begin < rhs.range.begin
            }

            return lhs.targetUserID < rhs.targetUserID
        }
    }

    private func replyReference(for item: TrixTimelineItem) -> TrixReplyReference {
        TrixReplyReference(
            targetMessageID: item.id,
            targetSenderID: item.sender,
            targetRoomID: item.roomID,
            preview: TrixReplyPreview(
                senderID: item.sender,
                body: item.attachment == nil && !item.isRetracted ? item.body : nil,
                attachmentFilename: item.attachment?.filename,
                isUnavailable: item.isRetracted
            )
        )
    }

    private func threadReference(for item: TrixTimelineItem) -> TrixThreadReference {
        if let thread = item.thread {
            return TrixThreadReference(
                threadID: thread.threadID,
                rootMessageID: thread.rootMessageID ?? item.id,
                parentMessageID: item.id,
                parentThreadID: thread.parentThreadID,
                replyCount: threadReplyCount(for: item) + 1
            )
        }

        return TrixThreadReference(
            threadID: Self.threadID(rootMessageID: item.id),
            rootMessageID: item.id,
            parentMessageID: item.id,
            replyCount: threadReplyCount(for: item) + 1
        )
    }

    private func startReply(to item: TrixTimelineItem) {
        guard !item.isRetracted else {
            return
        }

        editingItem = nil
        threadDraftTarget = nil
        replyDraftTarget = item
    }

    private func startThreadReply(to item: TrixTimelineItem) {
        guard room.kind == .group,
              !item.isRetracted else {
            return
        }

        editingItem = nil
        replyDraftTarget = nil
        threadDraftTarget = item
        openThread(for: item)
    }

    private func startEditing(_ item: TrixTimelineItem) {
        guard canEdit(item) else {
            return
        }

        replyDraftTarget = nil
        threadDraftTarget = nil
        editingItem = item
        selectedMentionTargets = mentionMembersByToken(in: item.body)
        draft = item.body
    }

    private func cancelComposerContext() {
        replyDraftTarget = nil
        threadDraftTarget = nil
        editingItem = nil
        selectedMentionTargets = [:]
        draft = ""
    }

    private func clearThreadContext() {
        threadDraftTarget = nil
        activeThreadFilter = nil
    }

    private func closeThread() {
        withAnimation(.snappy(duration: 0.2)) {
            clearThreadContext()
        }
    }

    private func openMentionProfile(_ userID: String) {
        selectedMentionProfile = TrixMentionProfileSelection(userID: userID)
    }

    private func resetComposerState() {
        draft = ""
        selectedMentionTargets = [:]
        replyDraftTarget = nil
        threadDraftTarget = nil
        editingItem = nil
        retractionCandidate = nil
        activeThreadFilter = nil
        lastDisplayedMarkerMessageID = nil
    }

    private func openThread(for item: TrixTimelineItem) {
        guard room.kind == .group else {
            return
        }

        let threadID = item.thread?.threadID ?? Self.threadID(rootMessageID: item.id)
        let rootMessageID = item.thread?.rootMessageID ?? item.id
        let rootItem = timelineViewModel.items.first { $0.id == rootMessageID } ?? item
        withAnimation(.snappy(duration: 0.2)) {
            activeThreadFilter = TrixTimelineThreadFilter(
                threadID: threadID,
                rootMessageID: rootMessageID,
                title: quotePreviewText(for: rootItem)
            )
        }
    }

    private func canEdit(_ item: TrixTimelineItem) -> Bool {
        isOwnTextMessage(item) &&
            !item.isRetracted &&
            item.id == lastEditableOwnTextMessageID
    }

    private func canRetract(_ item: TrixTimelineItem) -> Bool {
        isOwnTextMessage(item) && !item.isRetracted
    }

    private func isOwnTextMessage(_ item: TrixTimelineItem) -> Bool {
        item.isLocalEcho &&
            item.attachment == nil &&
            !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var lastEditableOwnTextMessageID: String? {
        timelineViewModel.items.last(where: isOwnTextMessage)?.id
    }

    private func threadReplyCount(for item: TrixTimelineItem) -> Int {
        let threadID = item.thread?.threadID ?? Self.threadID(rootMessageID: item.id)
        let rootMessageID = item.thread?.rootMessageID ?? item.id
        let localCount = timelineViewModel.items.filter { candidate in
            candidate.id != item.id &&
                (
                    candidate.thread?.threadID == threadID ||
                        candidate.thread?.rootMessageID == rootMessageID
                )
        }.count

        return max(localCount, item.thread?.replyCount ?? 0)
    }

    private func quotePreviewText(for item: TrixTimelineItem) -> String {
        if let retractionState = item.retractionState {
            return retractionState.tombstoneBody
        }

        if let attachment = item.attachment {
            return attachment.isSticker ? "Sticker" : attachment.filename
        }

        let trimmed = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Message unavailable"
        }

        if trimmed.count <= 120 {
            return trimmed
        }

        return "\(trimmed.prefix(117))..."
    }

    private var activeMentionQuery: String? {
        guard let range = activeMentionTokenRange(in: draft) else {
            return nil
        }

        return String(draft[draft.index(after: range.lowerBound)..<range.upperBound])
    }

    private func activeMentionTokenRange(in text: String) -> Range<String.Index>? {
        guard let atIndex = text.lastIndex(of: "@") else {
            return nil
        }

        let suffix = text[atIndex..<text.endIndex]
        guard !suffix.dropFirst().contains(where: \.isWhitespace) else {
            return nil
        }

        if atIndex > text.startIndex {
            let previousIndex = text.index(before: atIndex)
            guard text[previousIndex].isWhitespace else {
                return nil
            }
        }

        return atIndex..<text.endIndex
    }

    private func filteredMentionMembers(for query: String) -> [TrixRoomMember] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeMembers = mentionMembers.filter(\.membership.isActive)
        let filteredMembers: [TrixRoomMember]
        if normalizedQuery.isEmpty {
            filteredMembers = activeMembers
        } else {
            filteredMembers = activeMembers.filter { member in
                member.title.lowercased().contains(normalizedQuery) ||
                    member.userID.lowercased().contains(normalizedQuery)
            }
        }

        return filteredMembers
            .filter { member in
                guard let currentUserID else {
                    return true
                }
                return trixNormalizedUserKey(member.userID) != trixNormalizedUserKey(currentUserID)
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .prefix(6)
            .map(\.self)
    }

    private func insertMention(_ member: TrixRoomMember) {
        let token = mentionToken(for: member)
        if let range = activeMentionTokenRange(in: draft) {
            draft.replaceSubrange(range, with: "\(token) ")
        } else {
            if !draft.isEmpty,
               draft.last?.isWhitespace == false {
                draft.append(" ")
            }
            draft.append("\(token) ")
        }
        selectedMentionTargets[member.userID] = member
    }

    private func pruneMentionTargets() {
        selectedMentionTargets = selectedMentionTargets.filter { _, member in
            draft.contains(mentionToken(for: member))
        }
    }

    private func mentionMembersByToken(in text: String) -> [String: TrixRoomMember] {
        Dictionary(
            uniqueKeysWithValues: mentionMembers
                .filter { text.contains(mentionToken(for: $0)) }
                .map { ($0.userID, $0) }
        )
    }

    private func mentionToken(for member: TrixRoomMember) -> String {
        let compactTitle = member.title
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "@", with: "")
        let fallback = Self.displayName(from: member.userID)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "@", with: "")
        let token = compactTitle.isEmpty ? fallback : compactTitle
        return "@\(token)"
    }

    private func loadMentionMembers() async {
        isLoadingMentionMembers = true
        defer { isLoadingMentionMembers = false }

        do {
            mentionMembers = try await model.members(roomID: room.id)
        } catch {
            mentionMembers = []
        }
    }

    private func markLatestVisibleMessageDisplayed(_ items: [TrixTimelineItem]) {
        guard timelineViewModel.roomID == room.id,
              let latest = items.last,
              latest.id != lastDisplayedMarkerMessageID else {
            return
        }

        lastDisplayedMarkerMessageID = latest.id
        Task {
            await model.markRoomDisplayed(roomID: room.id, messageID: latest.id)
        }
    }

    private static func threadID(rootMessageID: String) -> String {
        "trix-thread-\(rootMessageID)"
    }

    @MainActor
    private func dismissTimelineToast() {
        timelineViewModel.dismissErrorMessage()
        fileImportError = nil
    }

    @MainActor
    private func dismissTimelineToast(matching message: String) {
        if timelineViewModel.errorMessage == message {
            timelineViewModel.dismissErrorMessage()
        }
        if fileImportError == message {
            fileImportError = nil
        }
    }

    @MainActor
    private func dismissStickerImportMessage(matching message: String) {
        guard model.stickerImportMessage == message else {
            return
        }

        model.dismissStickerImportMessage()
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

    private func callParticipantTitle(_ userID: String) -> String {
        if let currentUserID = model.session?.userID,
           trixNormalizedUserKey(userID) == trixNormalizedUserKey(currentUserID) {
            return "You"
        }

        return Self.displayName(from: userID)
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

                    TrixRoomNotificationProfileMark(
                        profile: model.roomNotificationProfile(for: room.id),
                        size: 20
                    )
                }
                Text(room.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if room.kind == .direct {
                let callState = callViewModel.callLifecycleState(roomID: room.id)
                Button {
                    Task.detached(priority: .userInitiated) {
                        await model.startDirectVideoCall(in: room)
                    }
                } label: {
                    Image(systemName: callState.phase.isActiveLike && callState.kind == .directVideo ? "video.fill" : "video")
                }
                .disabled(
                    !canSendEncrypted ||
                        callViewModel.isActing(roomID: room.id) ||
                        !canStartDirectVideoCall(with: callState)
                )
                .help("Video call")

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
                Button {
                    isShowingNotificationSettings = true
                } label: {
                    Label(
                        "Notifications",
                        systemImage: model.roomNotificationProfile(for: room.id).systemImage
                    )
                }

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
        pruneMentionTargets()
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

    fileprivate static func displayName(from userID: String) -> String {
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

private struct TrixRoomNotificationSettingsView: View {
    @ObservedObject var model: TrixAppModel
    let room: TrixRoomSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Picker("Profile", selection: profileBinding) {
                        ForEach(TrixRoomNotificationProfile.allCases) { profile in
                            Label(profile.label, systemImage: profile.systemImage)
                                .tag(profile)
                        }
                    }
                    .pickerStyle(.inline)

                    if model.isUpdatingRoomNotificationProfile {
                        ProgressView()
                    }

                    if let message = model.roomNotificationProfileMessage {
                        TrixBannerView(
                            text: message,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange,
                            dismissAction: model.dismissRoomNotificationProfileMessage
                        )
                    }
                }
            }
            .navigationTitle(room.name)
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .trixDialogSurface(minWidth: 360, minHeight: 300)
    }

    private var profileBinding: Binding<TrixRoomNotificationProfile> {
        Binding(
            get: { model.roomNotificationProfile(for: room.id) },
            set: { profile in
                Task {
                    await model.setRoomNotificationProfile(profile, for: room.id)
                }
            }
        )
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

private struct TrixIncomingDirectCallBar: View {
    let callerTitle: String
    let isWorking: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TrixDesign.accent)
                .frame(width: 34, height: 34)
                .background(TrixDesign.accent.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming video call")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(callerTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: decline) {
                Image(systemName: "phone.down.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isWorking)
            .help("Decline")
            .accessibilityLabel("Decline video call")

            Button(action: accept) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "video.fill")
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            .help("Accept")
            .accessibilityLabel("Accept video call")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct TrixDirectCallBar: View {
    let title: String
    let subtitle: String
    let activeCall: TrixActiveMediaCall?
    let state: TrixCallLifecycleState
    let isWorking: Bool
    let setMicrophoneMuted: (Bool) -> Void
    let setCameraEnabled: (Bool) -> Void
    let end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TrixCallVideoStage(activeCall: activeCall, state: state)

            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                mediaControls

                Button(action: end) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "phone.down.fill")
                            .frame(width: 30, height: 30)
                    }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(isWorking)
                .help("End")
                .accessibilityLabel("End video call")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var mediaControls: some View {
        HStack(spacing: 6) {
            Button {
                setMicrophoneMuted(state.localAudioState != .muted)
            } label: {
                Image(systemName: state.localAudioState == .muted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking || state.localAudioState == .unavailable)
            .help(state.localAudioState == .muted ? "Unmute microphone" : "Mute microphone")
            .accessibilityLabel(state.localAudioState == .muted ? "Unmute microphone" : "Mute microphone")

            Button {
                setCameraEnabled(state.localCameraState != .on)
            } label: {
                Image(systemName: state.localCameraState == .on ? "video.fill" : "video.slash.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking || state.localCameraState == .unavailable)
            .help(state.localCameraState == .on ? "Turn camera off" : "Turn camera on")
            .accessibilityLabel(state.localCameraState == .on ? "Turn camera off" : "Turn camera on")
        }
    }
}

private struct TrixGroupVoiceRoomBar: View {
    let snapshot: TrixGroupVoiceRoomSnapshot
    let participantTitle: (String) -> String
    let isJoined: Bool
    let isWorking: Bool
    let join: () -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TrixDesign.groupAccent)
                    .frame(width: 34, height: 34)
                    .background(TrixDesign.groupAccent.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice room")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(participantCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                actionButton
            }

            if snapshot.activeParticipantIDs.isEmpty {
                Text("No one in voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(snapshot.activeParticipantIDs, id: \.self) { participantID in
                            TrixVoiceParticipantChip(title: participantTitle(participantID))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }

    private var participantCountLabel: String {
        let count = snapshot.activeParticipantCount
        if count == 1 {
            return "1 participant"
        }

        return "\(count) participants"
    }

    @ViewBuilder
    private var actionButton: some View {
        if isJoined {
            Button(action: leave) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Leave", systemImage: "phone.down.fill")
                }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .disabled(isWorking)
            .help("Leave voice room")
        } else {
            Button(action: join) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Join", systemImage: "waveform")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            .help("Join voice room")
        }
    }
}

private struct TrixVoiceParticipantChip: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "person.fill")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(TrixDesign.groupAccent.opacity(0.12), in: Capsule())
            .foregroundStyle(TrixDesign.groupAccent)
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

private struct TrixTimelineThreadFilter: Equatable {
    let threadID: String
    let rootMessageID: String
    let title: String
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
    @Environment(\.dismiss) private var dismiss

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

                Text("Trust only after comparing the visual fingerprint with each contact over an independent channel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .navigationTitle("Trust \(roomName)")
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .help("Close")
                }

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

            TrixVisualDeviceVerificationView(
                device: device,
                canApprove: !device.canSendEncrypted && device.isActive,
                isBusy: isLoading,
                approve: {
                    trust(device)
                }
            )
        }
        .padding(10)
        .background(TrixDesign.secondarySurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TrixPeerDeviceTrustView: View {
    @Environment(\.dismiss) private var dismiss

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

                                    TrixVisualDeviceVerificationView(
                                        device: device,
                                        canApprove: !device.canSendEncrypted && device.isActive,
                                        isBusy: isLoading,
                                        approve: {
                                            trust(device)
                                        }
                                    )
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

                Text("Trust only after comparing the visual fingerprint with the contact over an independent channel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .navigationTitle("Trust \(roomName)")
            .trixInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .help("Close")
                }

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

private struct TrixComposerContextBanner: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let tint: Color
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Clear")
            .accessibilityLabel("Clear composer context")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct TrixMentionPickerView: View {
    let members: [TrixRoomMember]
    let isLoading: Bool
    let select: (TrixRoomMember) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                }

                ForEach(members) { member in
                    Button {
                        select(member)
                    } label: {
                        HStack(spacing: 7) {
                            TrixAvatarView(
                                title: member.title,
                                systemImage: "person.fill",
                                size: 24,
                                tint: TrixDesign.accent
                            )

                            Text(member.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(TrixDesign.elevatedFieldSurface, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Mention \(member.title)")
                    .accessibilityLabel("Mention \(member.title)")
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct TrixMentionProfileView: View {
    @ObservedObject var model: TrixAppModel
    let userID: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = TrixProfileViewModel()
    @State private var isOpeningDirectMessage = false
    @State private var directMessageError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.isLoading, viewModel.profile == nil {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let profile = viewModel.profile {
                        profileDetails(profile)
                    } else {
                        LabeledContent("User", value: userID)
                    }

                    if let directMessageError {
                        TrixBannerView(
                            text: directMessageError,
                            systemImage: "exclamationmark.triangle",
                            tint: .red
                        )
                    }

                    if let errorMessage = viewModel.errorMessage {
                        TrixBannerView(
                            text: errorMessage,
                            systemImage: "exclamationmark.triangle",
                            tint: .red
                        )
                    }
                }
                .padding(20)
            }
            .trixScrollContentBackgroundHidden()
        }
        .background(TrixDesign.screenBackground)
        .task(id: userID) {
            await viewModel.load {
                try await model.profile(userID: userID)
            }
        }
        .trixDialogSurface(minWidth: 420, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 14) {
            TrixMentionProfileIconCircle(size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Text(userID)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                Task {
                    await openDirectMessage()
                }
            } label: {
                if isOpeningDirectMessage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Label("Message", systemImage: "bubble.left.and.bubble.right.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCurrentUser || isOpeningDirectMessage)
            .help(isCurrentUser ? "This is you" : "Open direct message")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close profile")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(TrixDesign.primarySurface)
    }

    private var title: String {
        viewModel.profile?.title ?? TrixTimelineView.displayName(from: userID)
    }

    private var isCurrentUser: Bool {
        guard let currentUserID = model.account?.userID ?? model.session?.userID else {
            return false
        }

        return trixNormalizedUserKey(currentUserID) == trixNormalizedUserKey(userID)
    }

    private func openDirectMessage() async {
        guard !isCurrentUser, !isOpeningDirectMessage else {
            return
        }

        isOpeningDirectMessage = true
        directMessageError = nil
        defer { isOpeningDirectMessage = false }

        if let room = existingDirectRoom {
            await model.selectRoom(room)
            dismiss()
            return
        }

        let didCreate = await model.createEncryptedDirectRoom(
            inviteeUserID: userID,
            roomName: title
        )
        guard didCreate else {
            directMessageError = model.roomListViewModel.errorMessage ?? model.errorMessage ?? "Could not open direct message"
            return
        }

        dismiss()
    }

    private var existingDirectRoom: TrixRoomSummary? {
        model.roomListViewModel.rooms.first { room in
            room.kind == .direct &&
                room.id.caseInsensitiveCompare(userID) == .orderedSame
        }
    }

    @ViewBuilder
    private func profileDetails(_ profile: TrixUserProfile) -> some View {
        LabeledContent("User", value: profile.userID)

        if let statusMessage = profile.metadata.statusMessage {
            LabeledContent("Status", value: statusMessage)
        }

        if let bio = profile.metadata.bio {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bio")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(bio)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }

        if let website = profile.metadata.website {
            LabeledContent("Website", value: website)
        }
    }
}

private struct TrixMentionProfileIconCircle: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(TrixDesign.accent.opacity(0.15))

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(TrixDesign.accent)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct TrixThreadFilterBar: View {
    let filter: TrixTimelineThreadFilter
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.caption.weight(.bold))
                .foregroundStyle(TrixDesign.groupAccent)
                .frame(width: 28, height: 28)
                .background(TrixDesign.groupAccent.opacity(0.12), in: Circle())

            Text(filter.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close thread")
            .accessibilityLabel("Close thread")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TrixDesign.elevatedFieldSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
        }
    }
}

private struct TrixTimelineRow: View {
    let presentation: TrixTimelineMessagePresentation
    let currentUserID: String?
    let roomKind: TrixRoomKind
    let threadReplyCount: Int
    let canEdit: Bool
    let canRetract: Bool
    let isDownloadingAttachment: Bool
    let attachmentFailure: String?
    let inlineAttachmentPreview: TrixAttachmentDownload?
    let isLoadingInlineAttachmentPreview: Bool
    let inlineAttachmentPreviewFailure: String?
    let isReacting: Bool
    let downloadAttachment: () -> Void
    let loadInlineAttachmentPreview: () -> Void
    let react: (String) -> Void
    let reply: () -> Void
    let replyInThread: () -> Void
    let edit: () -> Void
    let retract: () -> Void
    let openThread: () -> Void
    let openMention: (String) -> Void
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
                        if let replyTo = item.replyTo {
                            TrixQuotePreviewView(
                                reply: replyTo,
                                isOutgoing: item.isLocalEcho
                            )
                        }

                        if item.isRetracted {
                            TrixRetractedMessageView(
                                tombstone: item.retractionState?.tombstoneBody ?? "Message deleted",
                                isOutgoing: item.isLocalEcho
                            )
                        } else if let attachment = item.attachment {
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
                                isOutgoing: item.isLocalEcho,
                                mentions: item.mentions,
                                currentUserID: currentUserID,
                                openMention: openMention
                            )
                        }

                        if !item.isRetracted {
                            TrixReactionChips(
                                aggregates: item.reactionAggregates,
                                isOutgoing: item.isLocalEcho,
                                react: react
                            )
                        }

                        if threadReplyCount > 0 {
                            TrixThreadSummaryButton(
                                count: threadReplyCount,
                                isOutgoing: item.isLocalEcho,
                                open: openThread
                            )
                        }

                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                if !item.isRetracted {
                                    TrixReactionMenu(
                                        isOutgoing: item.isLocalEcho,
                                        isWorking: isReacting,
                                        react: react
                                    )
                                }

                                if item.isEdited && !item.isRetracted {
                                    Text("edited")
                                        .font(.caption2.weight(.medium))
                                }

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
        .contextMenu {
            if !item.isRetracted {
                Button {
                    reply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }

                if roomKind == .group {
                    Button {
                        replyInThread()
                    } label: {
                        Label("Reply in Thread", systemImage: "text.bubble")
                    }
                }
            }

            if canEdit {
                Divider()

                Button {
                    edit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            if canRetract {
                Button(role: .destructive) {
                    retract()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
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

private struct TrixQuotePreviewView: View {
    let reply: TrixReplyReference
    let isOutgoing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(senderTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(previewBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var senderTitle: String {
        guard let senderID = reply.targetSenderID ?? reply.preview?.senderID else {
            return "Message"
        }

        return TrixTimelineView.displayName(from: senderID)
    }

    private var previewText: String {
        if reply.preview?.isUnavailable == true {
            return "Message unavailable"
        }

        if let body = reply.preview?.body,
           !body.isEmpty {
            return body
        }

        if let attachmentFilename = reply.preview?.attachmentFilename,
           !attachmentFilename.isEmpty {
            return attachmentFilename
        }

        return "Message unavailable"
    }

    private var accent: Color {
        isOutgoing ? .white.opacity(0.82) : TrixDesign.accent
    }

    private var secondaryForeground: Color {
        isOutgoing ? .white.opacity(0.78) : .secondary
    }

    private var previewBackground: Color {
        isOutgoing ? Color.white.opacity(0.14) : TrixDesign.secondarySurface
    }
}

private struct TrixRetractedMessageView: View {
    let tombstone: String
    let isOutgoing: Bool

    var body: some View {
        Label(tombstone, systemImage: "trash")
            .font(.body.italic())
            .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TrixThreadSummaryButton: View {
    let count: Int
    let isOutgoing: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                    .font(.caption2.weight(.bold))
                Text(summary)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Open thread")
        .accessibilityLabel("Open thread")
    }

    private var summary: String {
        count == 1 ? "1 reply" : "\(count) replies"
    }

    private var foreground: Color {
        isOutgoing ? .white : TrixDesign.groupAccent
    }

    private var background: Color {
        isOutgoing ? Color.white.opacity(0.18) : TrixDesign.groupAccent.opacity(0.12)
    }
}

private struct TrixCollapsibleMessageText: View {
    let text: String
    let isOutgoing: Bool
    let mentions: [TrixMentionReference]
    let currentUserID: String?
    let openMention: (String) -> Void
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
        Text(attributedMessageText(value))
            .font(.body)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard let userID = Self.mentionUserID(from: url) else {
                    return .systemAction
                }

                openMention(userID)
                return .handled
            })
    }

    private func attributedMessageText(_ value: String) -> AttributedString {
        var attributed = AttributedString(value)
        attributed.foregroundColor = textColor

        let tokens = mentionTokens
        guard !tokens.isEmpty else {
            return attributed
        }

        for match in mentionMatches(in: value, tokens: tokens) {
            guard let attributedRange = Range(match.range, in: attributed),
                  let url = Self.mentionURL(for: match.targetUserID) else {
                continue
            }

            attributed[attributedRange].link = url
            attributed[attributedRange].font = .body.weight(.semibold)
            attributed[attributedRange].underlineStyle = .single
            attributed[attributedRange].foregroundColor = mentionColor(isCurrentUserMention: match.isCurrentUserMention)
        }

        return attributed
    }

    private var mentionTokens: [(token: String, targetUserID: String, isCurrentUserMention: Bool)] {
        mentions.compactMap { mention in
            let token = mention.displayText ?? mentionText(from: mention.range)
            guard let token,
                  !token.isEmpty else {
                return nil
            }

            return (
                token,
                mention.targetUserID,
                currentUserID.map {
                    trixNormalizedUserKey($0) == trixNormalizedUserKey(mention.targetUserID)
                } ?? false
            )
        }
    }

    private func mentionText(from range: TrixTextReferenceRange) -> String? {
        guard range.isValid(in: text),
              let start = text.index(text.startIndex, offsetBy: range.begin, limitedBy: text.endIndex),
              let end = text.index(text.startIndex, offsetBy: range.end, limitedBy: text.endIndex),
              start < end else {
            return nil
        }

        return String(text[start..<end])
    }

    private func mentionMatches(
        in value: String,
        tokens: [(token: String, targetUserID: String, isCurrentUserMention: Bool)]
    ) -> [(range: Range<String.Index>, targetUserID: String, isCurrentUserMention: Bool)] {
        tokens.flatMap { token in
            var matches: [(range: Range<String.Index>, targetUserID: String, isCurrentUserMention: Bool)] = []
            var searchStart = value.startIndex

            while searchStart < value.endIndex,
                  let range = value.range(
                    of: token.token,
                    options: [.caseInsensitive],
                    range: searchStart..<value.endIndex
                  ) {
                matches.append((range, token.targetUserID, token.isCurrentUserMention))
                searchStart = range.upperBound
            }

            return matches
        }
        .sorted { lhs, rhs in
            lhs.range.lowerBound < rhs.range.lowerBound
        }
    }

    private func mentionColor(isCurrentUserMention: Bool) -> Color {
        if isOutgoing {
            return isCurrentUserMention ? .yellow : .white
        }

        return isCurrentUserMention ? TrixDesign.accent : TrixDesign.groupAccent
    }

    private static func mentionURL(for userID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "trix"
        components.host = "mention"
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
        ]
        return components.url
    }

    private static func mentionUserID(from url: URL) -> String? {
        guard url.scheme == "trix",
              url.host == "mention",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?.first { $0.name == "user_id" }?.value
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
                        tint: TrixDesign.accent,
                        dismissAction: model.dismissStickerImportMessage
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
        .task(id: model.stickerImportMessage) {
            guard let message = model.stickerImportMessage else {
                return
            }

            try? await Task.sleep(for: TrixTransientBanner.autoDismissDelay)
            guard !Task.isCancelled else {
                return
            }

            await dismissStickerImportMessage(matching: message)
        }
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

    @MainActor
    private func dismissStickerImportMessage(matching message: String) {
        guard model.stickerImportMessage == message else {
            return
        }

        model.dismissStickerImportMessage()
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
    #if os(iOS)
    @GestureState private var isLongPressing = false
    #elseif os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        stickerSurface
            .scaleEffect(isMagnified ? Self.magnifiedScale : 1, anchor: .center)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                guard canInteract else {
                    return
                }

                send()
            }
            .opacity(canInteract ? 1 : 0.52)
            .help(sticker.emoji.map { "Send sticker \($0)" } ?? "Send sticker")
            .accessibilityLabel(sticker.emoji.map { "Send sticker \($0)" } ?? "Send sticker")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard canInteract else {
                    return
                }

                send()
            }
            .zIndex(isMagnified ? 1 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isMagnified)
            #if os(iOS)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.22, maximumDistance: 18)
                    .updating($isLongPressing) { value, state, _ in
                        state = value
                    }
            )
            #elseif os(macOS)
            .onHover { isHovering in
                self.isHovering = canInteract && isHovering
            }
            #endif
    }

    private var canInteract: Bool {
        canSend && data != nil
    }

    private var isMagnified: Bool {
        guard canInteract else {
            return false
        }

        #if os(iOS)
        return isLongPressing
        #elseif os(macOS)
        return isHovering
        #else
        return false
        #endif
    }

    private var stickerSurface: some View {
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
        .frame(width: Self.tileSize, height: Self.tileSize)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TrixDesign.surfaceStroke, lineWidth: 1)
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

    private static let tileSize: CGFloat = 72
    private static let magnifiedScale: CGFloat = 2
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
