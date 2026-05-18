import Foundation

struct TrixTimelineLoadProgress: Equatable {
    let roomID: String
    let fractionCompleted: Double
    let status: String
}

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var roomID: String?
    @Published private(set) var items: [TrixTimelineItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: TrixTimelineLoadProgress?
    @Published private(set) var isSending = false
    @Published private(set) var isSendingAttachment = false
    @Published private(set) var isLoadingAttachmentAvailability = false
    @Published private(set) var downloadingAttachmentID: String?
    @Published private(set) var attachmentDownloadFailures: [String: String] = [:]
    @Published private(set) var reactionActionMessageID: String?
    @Published private(set) var downloadedAttachment: TrixAttachmentDownload?
    @Published private(set) var inlineAttachmentPreviews: [String: TrixAttachmentDownload] = [:]
    @Published private(set) var inlineAttachmentPreviewLoadingIDs: Set<String> = []
    @Published private(set) var inlineAttachmentPreviewFailures: [String: String] = [:]
    @Published private(set) var attachmentSendAvailability: TrixAttachmentSendAvailability?
    @Published private(set) var typingUserIDs: [String] = []
    @Published private(set) var errorMessage: String?
    private var cachedItemsByRoomID: [String: [TrixTimelineItem]] = [:]

    func prepareForRoomSwitch(roomID: String) {
        guard self.roomID != roomID else {
            return
        }

        self.roomID = roomID
        resetRoomScopedState()
        items = cachedItemsByRoomID[roomID] ?? []
        isLoading = true
        loadProgress = TrixTimelineLoadProgress(
            roomID: roomID,
            fractionCompleted: 0.1,
            status: "Opening chat"
        )
    }

    func load(
        roomID: String,
        session: TrixSession,
        service: TrixRoomService,
        showsLoading: Bool = true
    ) async {
        prepareForLoad(roomID: roomID, showsLoading: showsLoading)
        if showsLoading {
            isLoading = true
        }
        errorMessage = nil
        defer {
            if showsLoading, self.roomID == roomID {
                isLoading = false
                loadProgress = nil
            }
        }

        do {
            if showsLoading {
                updateLoadProgress(roomID: roomID, fractionCompleted: 0.25, status: "Loading local cache")
            }
            if let cachedItems = try? await service.cachedTimeline(roomID: roomID, session: session),
               !cachedItems.isEmpty {
                guard self.roomID == roomID, !Task.isCancelled else {
                    return
                }

                storeLoadedItems(cachedItems, for: roomID)
            }

            if showsLoading {
                updateLoadProgress(roomID: roomID, fractionCompleted: 0.65, status: "Syncing encrypted archive")
            }
            let loadedItems = try await service.timeline(roomID: roomID, session: session)
            guard self.roomID == roomID, !Task.isCancelled else {
                return
            }

            storeLoadedItems(loadedItems, for: roomID)
            if showsLoading {
                updateLoadProgress(roomID: roomID, fractionCompleted: 1, status: "Timeline ready")
            }
        } catch {
            guard self.roomID == roomID else {
                return
            }

            if let cachedItems = cachedItemsByRoomID[roomID] {
                items = cachedItems
            }
            errorMessage = error.trixUserFacingMessage
        }
    }

    func send(
        text: String,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let item = try await service.sendText(text, roomID: roomID, session: session)
            store(item, for: roomID)
        } catch {
            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
        }
    }

    func setReaction(
        _ emoji: String,
        item: TrixTimelineItem,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        reactionActionMessageID = item.id
        errorMessage = nil
        defer { reactionActionMessageID = nil }

        do {
            let reactions = try await service.setReaction(emoji, messageID: item.id, roomID: roomID, session: session)
            store(item.withReactions(reactions), for: roomID)
        } catch {
            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
        }
    }

    func sendAttachment(
        _ attachment: TrixAttachmentUpload,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        isSendingAttachment = true
        errorMessage = nil
        defer { isSendingAttachment = false }

        do {
            let item = try await service.sendAttachment(attachment, roomID: roomID, session: session)
            store(item, for: roomID)
        } catch {
            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
        }
    }

    func downloadAttachment(
        for item: TrixTimelineItem,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        guard let attachment = item.attachment else {
            return
        }

        if let cachedPreview = inlineAttachmentPreviews[item.id] {
            downloadedAttachment = cachedPreview
            return
        }

        downloadingAttachmentID = item.id
        attachmentDownloadFailures[item.id] = nil
        errorMessage = nil
        defer { downloadingAttachmentID = nil }

        do {
            let download = try await service.downloadAttachment(attachment, session: session)
            downloadedAttachment = download
            if TrixInlineMediaPreviewSupport.canRenderInlinePreview(download) {
                inlineAttachmentPreviews[item.id] = download
                inlineAttachmentPreviewFailures[item.id] = nil
            }
        } catch {
            let message = error.trixUserFacingMessage
            attachmentDownloadFailures[item.id] = message
            errorMessage = message
        }
    }

    func loadInlineAttachmentPreview(
        for item: TrixTimelineItem,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        guard let attachment = item.attachment,
              TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment),
              inlineAttachmentPreviews[item.id] == nil,
              !inlineAttachmentPreviewLoadingIDs.contains(item.id),
              inlineAttachmentPreviewFailures[item.id] == nil else {
            return
        }

        setInlineAttachmentPreviewLoading(true, for: item.id)
        defer {
            setInlineAttachmentPreviewLoading(false, for: item.id)
        }

        do {
            let download = try await service.downloadAttachment(attachment, session: session)
            guard self.roomID == item.roomID,
                  TrixInlineMediaPreviewSupport.canRenderInlinePreview(download) else {
                return
            }

            inlineAttachmentPreviews[item.id] = download
        } catch {
            guard self.roomID == item.roomID else {
                return
            }

            inlineAttachmentPreviewFailures[item.id] = error.trixUserFacingMessage
        }
    }

    func dismissDownloadedAttachment() {
        downloadedAttachment = nil
    }

    func loadAttachmentSendAvailability(
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async {
        isLoadingAttachmentAvailability = true
        defer { isLoadingAttachmentAvailability = false }

        do {
            let availability = try await service.attachmentSendAvailability(roomID: roomID, session: session)
            guard self.roomID == roomID else {
                return
            }

            attachmentSendAvailability = availability
        } catch {
            guard self.roomID == roomID else {
                return
            }

            attachmentSendAvailability = .blocked(roomID: roomID, reason: .unavailable)
        }
    }

    func clearAttachmentSendAvailability() {
        isLoadingAttachmentAvailability = false
        attachmentSendAvailability = nil
    }

    func loadTypingState(
        roomID: String,
        session: TrixSession,
        service: TrixTypingService
    ) async {
        do {
            let typingState = try await service.typingState(roomID: roomID, session: session)
            guard self.roomID == roomID else {
                return
            }

            typingUserIDs = typingState.typingUserIDs
        } catch {
            guard self.roomID == roomID else {
                return
            }

            typingUserIDs = []
        }
    }

    func clearTypingState() {
        typingUserIDs = []
    }

    func clear() {
        roomID = nil
        items = []
        isLoading = false
        loadProgress = nil
        isSending = false
        isSendingAttachment = false
        isLoadingAttachmentAvailability = false
        downloadingAttachmentID = nil
        attachmentDownloadFailures = [:]
        reactionActionMessageID = nil
        downloadedAttachment = nil
        inlineAttachmentPreviews = [:]
        inlineAttachmentPreviewLoadingIDs = []
        inlineAttachmentPreviewFailures = [:]
        attachmentSendAvailability = nil
        typingUserIDs = []
        errorMessage = nil
        cachedItemsByRoomID = [:]
    }

    private func prepareForLoad(roomID: String, showsLoading: Bool) {
        if self.roomID != roomID {
            self.roomID = roomID
            resetRoomScopedState()
            items = cachedItemsByRoomID[roomID] ?? []
        }

        if showsLoading {
            isLoading = true
            loadProgress = TrixTimelineLoadProgress(
                roomID: roomID,
                fractionCompleted: 0.15,
                status: "Preparing timeline"
            )
        }
    }

    private func updateLoadProgress(roomID: String, fractionCompleted: Double, status: String) {
        guard self.roomID == roomID else {
            return
        }

        loadProgress = TrixTimelineLoadProgress(
            roomID: roomID,
            fractionCompleted: fractionCompleted,
            status: status
        )
    }

    private func resetRoomScopedState() {
        items = []
        isSending = false
        isSendingAttachment = false
        isLoadingAttachmentAvailability = false
        downloadingAttachmentID = nil
        attachmentDownloadFailures = [:]
        reactionActionMessageID = nil
        downloadedAttachment = nil
        inlineAttachmentPreviews = [:]
        inlineAttachmentPreviewLoadingIDs = []
        inlineAttachmentPreviewFailures = [:]
        attachmentSendAvailability = nil
        typingUserIDs = []
        errorMessage = nil
    }

    private func setInlineAttachmentPreviewLoading(_ isLoading: Bool, for itemID: String) {
        var loadingIDs = inlineAttachmentPreviewLoadingIDs
        if isLoading {
            loadingIDs.insert(itemID)
        } else {
            loadingIDs.remove(itemID)
        }
        inlineAttachmentPreviewLoadingIDs = loadingIDs
    }

    private func storeLoadedItems(_ loadedItems: [TrixTimelineItem], for roomID: String) {
        let mergedItems = Self.mergedTimelineItems(
            cachedItemsByRoomID[roomID] ?? [],
            loadedItems
        )
        cachedItemsByRoomID[roomID] = mergedItems
        items = mergedItems
    }

    private func store(_ item: TrixTimelineItem, for roomID: String) {
        let mergedItems = Self.mergedTimelineItems(
            cachedItemsByRoomID[roomID] ?? [],
            [item]
        )
        cachedItemsByRoomID[roomID] = mergedItems

        if self.roomID == roomID {
            items = mergedItems
        }
    }

    private static func mergedTimelineItems(
        _ lhs: [TrixTimelineItem],
        _ rhs: [TrixTimelineItem]
    ) -> [TrixTimelineItem] {
        var byID: [String: TrixTimelineItem] = [:]
        for item in lhs {
            byID[item.id] = item
        }
        for item in rhs {
            if let existingItem = byID[item.id] {
                byID[item.id] = item.withDeliveryState(
                    TrixTimelineItem.mergedDeliveryState(
                        existingItem.deliveryState,
                        item.deliveryState
                    )
                )
            } else {
                byID[item.id] = item
            }
        }

        return byID.values.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
    }
}
