import Foundation

struct TrixTimelineLoadProgress: Equatable {
    let roomID: String
    let fractionCompleted: Double
    let status: String
}

struct TrixMentionCandidate: Identifiable, Equatable, Sendable {
    let userID: String
    let displayName: String
    let tokens: [String]

    var id: String {
        userID.lowercased()
    }

    init(userID: String, displayName: String) {
        self.userID = userID
        self.displayName = displayName
        self.tokens = Self.tokens(userID: userID, displayName: displayName)
    }

    private static func tokens(userID: String, displayName: String) -> [String] {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var values: [String] = []

        if normalizedUserID.hasPrefix("@"),
           let separator = normalizedUserID.firstIndex(of: ":") {
            let localpart = String(normalizedUserID[normalizedUserID.index(after: normalizedUserID.startIndex)..<separator])
            let server = String(normalizedUserID[normalizedUserID.index(after: separator)...])
            values.append(normalizedUserID)
            values.append("@\(localpart)")
            values.append("@\(localpart):\(server)")
        } else {
            let parts = normalizedUserID.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2,
               let localpart = parts.first,
               let server = parts.last,
               !localpart.isEmpty,
                !server.isEmpty {
                values.append("@\(localpart)")
                values.append("@\(localpart):\(server)")
            } else if !normalizedUserID.isEmpty {
                values.append("@\(normalizedUserID)")
            }
        }

        if let displayToken = mentionToken(from: displayName) {
            values.append(displayToken)
        }

        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func mentionToken(from displayName: String) -> String? {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let token = String(
            displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .unicodeScalars
                .filter { allowedScalars.contains($0) }
        )
        guard !token.isEmpty else {
            return nil
        }

        return "@\(token.lowercased())"
    }
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
    @Published private(set) var mentionCandidates: [TrixMentionCandidate] = []
    @Published private(set) var replyTarget: TrixReplyReference?
    @Published private(set) var threadTarget: TrixThreadReference?
    @Published private(set) var editingMessage: TrixTimelineItem?
    @Published private(set) var editingDraftText: String?
    @Published private(set) var messageActionMessageID: String?
    @Published private(set) var displayedMarkerMessageID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var firstUnreadMessageID: String?
    private var cachedItemsByRoomID: [String: [TrixTimelineItem]] = [:]
    private var mentionCandidatesByRoomID: [String: [TrixMentionCandidate]] = [:]
    private var displayedMessageIDByRoomID: [String: String] = [:]
    private var unreadAnchorContextByRoomID: [String: UnreadAnchorContext] = [:]
    private var firstUnreadMessageIDByRoomID: [String: String] = [:]
    /// Most-recently-used preview item ids, oldest first. Bounds the decrypted
    /// attachment bytes held in `inlineAttachmentPreviews`: long scroll
    /// sessions and gallery paging would otherwise accumulate every preview
    /// for the lifetime of the room. Evicted previews reload from the
    /// encrypted media cache when their row or gallery page is shown again.
    private var inlineAttachmentPreviewAccessOrder: [String] = []
    private static let maxResidentInlineAttachmentPreviews = 32

    private struct UnreadAnchorContext {
        var unreadCount: Int
        var readMarker: TrixRoomReadMarkerState?
        var currentUserID: String
        var isFrozen: Bool
    }

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
            freezeUnreadAnchorIfNeeded(for: roomID)
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
            freezeUnreadAnchorIfNeeded(for: roomID)
            errorMessage = error.trixUserFacingMessage
        }
    }

    @discardableResult
    func send(
        text: String,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService,
        metadata: TrixTextMessageSendMetadata? = nil,
        outboxStore: TrixOutboxStore? = nil
    ) async -> TrixTimelineItem? {
        if editingMessage != nil {
            return await editActiveMessage(text: text, roomID: roomID, session: session, service: service)
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            if self.roomID == roomID {
                errorMessage = TrixClientError.emptyMessage.trixUserFacingMessage
            }
            return nil
        }

        let request = TrixTextMessageSendRequest(
            text: body,
            roomID: roomID,
            metadata: metadata ?? sendMetadata(for: body, roomID: roomID)
        )
        do {
            let item = try await service.sendText(request, session: session)
            let displayItem = Self.item(item, applyingLocalMetadataFrom: request.metadata)
            store(displayItem, for: roomID)
            clearReplyTarget()
            return displayItem
        } catch {
            if let outboxStore,
               TrixSendRetryPolicy.isRetryableSendError(error),
               let queuedItem = queueOfflineSend(request, session: session, outboxStore: outboxStore) {
                clearReplyTarget()
                return queuedItem
            }

            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
            return nil
        }
    }

    private func queueOfflineSend(
        _ request: TrixTextMessageSendRequest,
        session: TrixSession,
        outboxStore: TrixOutboxStore
    ) -> TrixTimelineItem? {
        // The first failed direct send counts as attempt one.
        let message = TrixOutboxMessage(
            roomID: request.roomID,
            body: request.text,
            metadata: request.metadata,
            createdAt: Date(),
            attemptCount: 1
        )
        do {
            try outboxStore.append(message, accountJID: session.userID)
        } catch {
            return nil
        }

        let echoItem = message.echoItem(sender: session.userID)
        store(echoItem, for: request.roomID)
        return echoItem
    }

    func applyOutboxItems(_ outboxItems: [TrixTimelineItem], for roomID: String) {
        guard !outboxItems.isEmpty else {
            return
        }

        let mergedItems = Self.mergedTimelineItems(
            cachedItemsByRoomID[roomID] ?? [],
            outboxItems
        )
        cachedItemsByRoomID[roomID] = mergedItems
        if self.roomID == roomID {
            items = mergedItems
        }
    }

    func replaceOutboxEcho(echoID: String, with item: TrixTimelineItem, for roomID: String) {
        var cachedItems = cachedItemsByRoomID[roomID] ?? []
        cachedItems.removeAll { $0.id == echoID }
        let mergedItems = Self.mergedTimelineItems(cachedItems, [item])
        cachedItemsByRoomID[roomID] = mergedItems
        if self.roomID == roomID {
            items = mergedItems
        }
    }

    func removeOutboxEcho(echoID: String, roomID: String) {
        var cachedItems = cachedItemsByRoomID[roomID] ?? items
        cachedItems.removeAll { $0.id == echoID }
        cachedItemsByRoomID[roomID] = cachedItems
        if self.roomID == roomID {
            items = cachedItems
        }
    }

    func setOutboxEchoDeliveryState(_ deliveryState: TrixDeliveryState, echoID: String, roomID: String) {
        var cachedItems = cachedItemsByRoomID[roomID] ?? items
        guard let index = cachedItems.firstIndex(where: { $0.id == echoID }) else {
            return
        }

        cachedItems[index] = cachedItems[index].withDeliveryState(deliveryState)
        cachedItemsByRoomID[roomID] = cachedItems
        if self.roomID == roomID {
            items = cachedItems
        }
    }

    func setMentionCandidates(_ candidates: [TrixMentionCandidate], for roomID: String) {
        let normalizedCandidates = Self.normalizedMentionCandidates(candidates)
        mentionCandidatesByRoomID[roomID] = normalizedCandidates
        if self.roomID == roomID {
            mentionCandidates = normalizedCandidates
        }
    }

    func mentionSuggestions(for draft: String) -> [TrixMentionCandidate] {
        guard let query = Self.currentMentionQuery(in: draft) else {
            return []
        }

        guard !query.isEmpty else {
            return Array(mentionCandidates.prefix(8))
        }

        return mentionCandidates
            .filter { candidate in
                candidate.tokens.contains { token in
                    token.dropFirst().hasPrefix(query)
                }
            }
            .prefix(8)
            .map { $0 }
    }

    func beginReply(to item: TrixTimelineItem) {
        guard !item.isRetracted else {
            errorMessage = TrixClientError.invalidMessageReference.trixUserFacingMessage
            return
        }

        replyTarget = Self.replyReference(for: item)
    }

    func clearReplyTarget() {
        replyTarget = nil
    }

    func blockSend(reason: String) {
        errorMessage = reason
    }

    func beginThread(from item: TrixTimelineItem) {
        guard !item.isRetracted else {
            errorMessage = TrixClientError.invalidMessageReference.trixUserFacingMessage
            return
        }

        let threadID = item.thread?.threadID ?? "trix-thread-\(UUID().uuidString)"
        threadTarget = TrixThreadReference(
            threadID: threadID,
            rootMessageID: item.thread?.rootMessageID ?? item.id,
            parentMessageID: item.id,
            parentThreadID: item.thread?.parentThreadID
        )
    }

    func continueThread(_ thread: TrixThreadReference) {
        threadTarget = thread
    }

    func clearThreadTarget() {
        threadTarget = nil
    }

    @discardableResult
    func beginEditing(_ item: TrixTimelineItem, currentUserID: String) -> Bool {
        guard canEdit(item, currentUserID: currentUserID) else {
            errorMessage = TrixClientError.messageEditUnavailable.trixUserFacingMessage
            return false
        }

        editingMessage = item
        editingDraftText = item.body
        replyTarget = nil
        return true
    }

    func cancelEditing() {
        editingMessage = nil
        editingDraftText = nil
    }

    @discardableResult
    func editText(
        messageID: String,
        newText: String,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async -> Bool {
        guard let item = items.first(where: { $0.id == messageID }),
              canEdit(item, currentUserID: session.userID) else {
            errorMessage = TrixClientError.messageEditUnavailable.trixUserFacingMessage
            return false
        }
        let body = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            errorMessage = TrixClientError.emptyMessage.trixUserFacingMessage
            return false
        }

        isSending = true
        messageActionMessageID = messageID
        errorMessage = nil
        defer {
            isSending = false
            messageActionMessageID = nil
        }

        do {
            let item = try await service.editText(
                TrixMessageEditRequest(
                    messageID: messageID,
                    roomID: roomID,
                    newText: body
                ),
                session: session
            )
            store(item, for: roomID)
            if editingMessage?.id == messageID {
                cancelEditing()
            }
            return true
        } catch {
            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
            return false
        }
    }

    @discardableResult
    func retractMessage(
        messageID: String,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async -> Bool {
        guard let item = items.first(where: { $0.id == messageID }),
              canRetract(item, currentUserID: session.userID) else {
            errorMessage = TrixClientError.messageRetractionUnavailable.trixUserFacingMessage
            return false
        }

        messageActionMessageID = messageID
        errorMessage = nil
        defer { messageActionMessageID = nil }

        do {
            let item = try await service.retractMessage(
                TrixMessageRetractionRequest(
                    messageID: messageID,
                    roomID: roomID
                ),
                session: session
            )
            store(item, for: roomID)
            if editingMessage?.id == messageID {
                cancelEditing()
            }
            return true
        } catch {
            if self.roomID == roomID {
                errorMessage = error.trixUserFacingMessage
            }
            return false
        }
    }

    func markRoomDisplayed(
        roomID: String,
        messageID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async -> TrixRoomReadMarkerState? {
        guard self.roomID == roomID else {
            return nil
        }

        let roomKey = roomID.lowercased()
        guard displayedMessageIDByRoomID[roomKey] != messageID else {
            return nil
        }

        displayedMarkerMessageID = messageID
        defer { displayedMarkerMessageID = nil }

        do {
            let marker = try await service.markRoomDisplayed(
                TrixRoomDisplayedMarkerRequest(roomID: roomID, messageID: messageID),
                session: session
            )
            applyReadMarker(marker)
            displayedMessageIDByRoomID[roomKey] = messageID
            return marker
        } catch TrixClientError.readMarkerUnavailable {
            displayedMessageIDByRoomID[roomKey] = messageID
            return nil
        } catch {
            errorMessage = error.trixUserFacingMessage
            return nil
        }
    }

    func markLatestVisibleItemDisplayed(
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async -> TrixRoomReadMarkerState? {
        // Unsent outbox echoes are local-only items: the server cannot resolve
        // their ids, so read markers must target the last real message.
        guard let latestItem = items.last(where: { item in
            item.deliveryState != .pending && item.deliveryState != .failed
        }) else {
            return nil
        }

        return await markRoomDisplayed(
            roomID: roomID,
            messageID: latestItem.id,
            session: session,
            service: service
        )
    }

    /// Starts a fresh "New Messages" anchor computation for a room visit.
    /// The anchor is computed once after the timeline loads and stays frozen
    /// while the user reads, until the room is selected again.
    func prepareUnreadAnchor(roomID: String, unreadCount: Int, currentUserID: String) {
        unreadAnchorContextByRoomID[roomID] = UnreadAnchorContext(
            unreadCount: unreadCount,
            readMarker: nil,
            currentUserID: currentUserID,
            isFrozen: false
        )
        firstUnreadMessageIDByRoomID[roomID] = nil
        if self.roomID == roomID {
            firstUnreadMessageID = nil
        }
    }

    func setUnreadAnchorReadMarker(_ readMarker: TrixRoomReadMarkerState?, roomID: String) {
        guard var context = unreadAnchorContextByRoomID[roomID],
              !context.isFrozen else {
            return
        }

        context.readMarker = readMarker
        unreadAnchorContextByRoomID[roomID] = context
    }

    private func freezeUnreadAnchorIfNeeded(for roomID: String) {
        guard var context = unreadAnchorContextByRoomID[roomID],
              !context.isFrozen else {
            return
        }

        let roomItems = cachedItemsByRoomID[roomID] ?? items
        guard !roomItems.isEmpty else {
            return
        }

        context.isFrozen = true
        unreadAnchorContextByRoomID[roomID] = context
        let anchorID = Self.firstUnreadMessageID(
            in: roomItems,
            readMarker: context.readMarker,
            unreadCount: context.unreadCount,
            currentUserID: context.currentUserID
        )
        firstUnreadMessageIDByRoomID[roomID] = anchorID
        if self.roomID == roomID {
            firstUnreadMessageID = anchorID
        }
    }

    static func firstUnreadMessageID(
        in items: [TrixTimelineItem],
        readMarker: TrixRoomReadMarkerState?,
        unreadCount: Int,
        currentUserID: String
    ) -> String? {
        let currentUserKey = normalizedUserKey(currentUserID)
        func isIncoming(_ item: TrixTimelineItem) -> Bool {
            !item.isLocalEcho && normalizedUserKey(item.sender) != currentUserKey
        }

        let sortedItems = items.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
        guard sortedItems.contains(where: isIncoming) else {
            return nil
        }

        if let readMarker,
           let markerIndex = sortedItems.firstIndex(where: { $0.id == readMarker.displayedMessageID }) {
            return sortedItems[sortedItems.index(after: markerIndex)...]
                .first(where: isIncoming)?
                .id
        }

        guard unreadCount > 0 else {
            return nil
        }

        let incomingItems = sortedItems.filter(isIncoming)
        return incomingItems.suffix(unreadCount).first?.id
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

    @discardableResult
    func downloadAttachment(
        for item: TrixTimelineItem,
        session: TrixSession,
        service: TrixRoomService,
        mediaCacheStore: TrixMediaCacheStore? = nil,
        mediaCachePolicy: TrixMediaCachePolicy = .defaultPolicy
    ) async -> TrixMediaCacheSnapshot? {
        guard let attachment = item.attachment else {
            return nil
        }

        if let cachedPreview = inlineAttachmentPreviews[item.id] {
            downloadedAttachment = cachedPreview
            touchResidentInlineAttachmentPreview(item.id)
            if let mediaCacheStore {
                return try? mediaCacheStore.snapshot(accountID: session.userID)
            }
            return nil
        }

        if let mediaCacheStore,
           let cachedDownload = try? mediaCacheStore.loadAttachment(for: item, accountID: session.userID) {
            downloadedAttachment = cachedDownload
            if TrixInlineMediaPreviewSupport.canRenderInlinePreview(cachedDownload) {
                storeResidentInlineAttachmentPreview(cachedDownload, for: item.id)
                inlineAttachmentPreviewFailures[item.id] = nil
            }
            return try? mediaCacheStore.snapshot(accountID: session.userID)
        }

        downloadingAttachmentID = item.id
        attachmentDownloadFailures[item.id] = nil
        errorMessage = nil
        defer { downloadingAttachmentID = nil }

        do {
            let download = try await service.downloadAttachment(attachment, session: session)
            downloadedAttachment = download
            if TrixInlineMediaPreviewSupport.canRenderInlinePreview(download) {
                storeResidentInlineAttachmentPreview(download, for: item.id)
                inlineAttachmentPreviewFailures[item.id] = nil
            }
            if let mediaCacheStore {
                return try? mediaCacheStore.saveAttachment(
                    download,
                    for: item,
                    accountID: session.userID,
                    policy: mediaCachePolicy
                )
            }
            return nil
        } catch {
            let message = error.trixUserFacingMessage
            attachmentDownloadFailures[item.id] = message
            errorMessage = message
        }
        return nil
    }

    @discardableResult
    func loadInlineAttachmentPreview(
        for item: TrixTimelineItem,
        session: TrixSession,
        service: TrixRoomService,
        mediaCacheStore: TrixMediaCacheStore? = nil,
        mediaCachePolicy: TrixMediaCachePolicy = .defaultPolicy
    ) async -> TrixMediaCacheSnapshot? {
        guard let attachment = item.attachment,
              TrixInlineMediaPreviewSupport.canAttemptInlinePreview(attachment) else {
            return nil
        }

        if inlineAttachmentPreviews[item.id] != nil {
            // A repeated request (row reappeared, gallery page revisited)
            // marks the preview as recently used so the LRU cap evicts colder
            // entries first.
            touchResidentInlineAttachmentPreview(item.id)
            return nil
        }

        guard !inlineAttachmentPreviewLoadingIDs.contains(item.id),
              inlineAttachmentPreviewFailures[item.id] == nil else {
            return nil
        }

        if let mediaCacheStore,
           let cachedDownload = try? mediaCacheStore.loadAttachment(for: item, accountID: session.userID),
           TrixInlineMediaPreviewSupport.canRenderInlinePreview(cachedDownload) {
            storeResidentInlineAttachmentPreview(cachedDownload, for: item.id)
            return try? mediaCacheStore.snapshot(accountID: session.userID)
        }

        setInlineAttachmentPreviewLoading(true, for: item.id)
        defer {
            setInlineAttachmentPreviewLoading(false, for: item.id)
        }

        do {
            let download = try await service.downloadAttachment(attachment, session: session)
            guard self.roomID == item.roomID,
                  TrixInlineMediaPreviewSupport.canRenderInlinePreview(download) else {
                return nil
            }

            storeResidentInlineAttachmentPreview(download, for: item.id)
            if let mediaCacheStore {
                return try? mediaCacheStore.saveAttachment(
                    download,
                    for: item,
                    accountID: session.userID,
                    policy: mediaCachePolicy
                )
            }
            return nil
        } catch {
            guard self.roomID == item.roomID else {
                return nil
            }

            inlineAttachmentPreviewFailures[item.id] = error.trixUserFacingMessage
        }
        return nil
    }

    private func storeResidentInlineAttachmentPreview(
        _ download: TrixAttachmentDownload,
        for itemID: String
    ) {
        inlineAttachmentPreviews[itemID] = download
        touchResidentInlineAttachmentPreview(itemID)
        while inlineAttachmentPreviewAccessOrder.count > Self.maxResidentInlineAttachmentPreviews {
            let evictedID = inlineAttachmentPreviewAccessOrder.removeFirst()
            inlineAttachmentPreviews.removeValue(forKey: evictedID)
        }
    }

    private func touchResidentInlineAttachmentPreview(_ itemID: String) {
        inlineAttachmentPreviewAccessOrder.removeAll { $0 == itemID }
        inlineAttachmentPreviewAccessOrder.append(itemID)
    }

    func dismissDownloadedAttachment() {
        downloadedAttachment = nil
    }

    func clearAttachmentDownloads() {
        downloadingAttachmentID = nil
        attachmentDownloadFailures = [:]
        downloadedAttachment = nil
        inlineAttachmentPreviews = [:]
        inlineAttachmentPreviewLoadingIDs = []
        inlineAttachmentPreviewFailures = [:]
        inlineAttachmentPreviewAccessOrder = []
    }

    func dismissErrorMessage() {
        errorMessage = nil
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
        inlineAttachmentPreviewAccessOrder = []
        attachmentSendAvailability = nil
        typingUserIDs = []
        mentionCandidates = []
        replyTarget = nil
        threadTarget = nil
        editingMessage = nil
        editingDraftText = nil
        messageActionMessageID = nil
        displayedMarkerMessageID = nil
        errorMessage = nil
        firstUnreadMessageID = nil
        cachedItemsByRoomID = [:]
        mentionCandidatesByRoomID = [:]
        displayedMessageIDByRoomID = [:]
        unreadAnchorContextByRoomID = [:]
        firstUnreadMessageIDByRoomID = [:]
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
        inlineAttachmentPreviewAccessOrder = []
        attachmentSendAvailability = nil
        typingUserIDs = []
        mentionCandidates = roomID.flatMap { mentionCandidatesByRoomID[$0] } ?? []
        replyTarget = nil
        threadTarget = nil
        editingMessage = nil
        editingDraftText = nil
        messageActionMessageID = nil
        displayedMarkerMessageID = nil
        errorMessage = nil
        firstUnreadMessageID = roomID.flatMap { firstUnreadMessageIDByRoomID[$0] }
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

    private func applyReadMarker(_ marker: TrixRoomReadMarkerState) {
        let roomID = marker.roomID
        let existingItems = cachedItemsByRoomID[roomID] ?? items
        let updatedItems = existingItems.map { item in
            guard item.id == marker.displayedMessageID else {
                return item
            }

            return item.withReadState(
                item.readState.withDisplayedReceipt(
                    TrixReadMarkerReceipt(
                        messageID: marker.displayedMessageID,
                        senderID: marker.senderID,
                        displayedAt: marker.displayedAt
                    )
                )
            )
        }
        cachedItemsByRoomID[roomID] = updatedItems
        if self.roomID == roomID {
            items = updatedItems
        }
    }

    private func sendMetadata(for text: String, roomID: String) -> TrixTextMessageSendMetadata {
        TrixTextMessageSendMetadata(
            mentions: mentionReferences(in: text, roomID: roomID),
            replyTo: replyTarget,
            thread: threadTarget
        )
    }

    private func mentionReferences(in text: String, roomID: String) -> [TrixMentionReference] {
        let candidates = mentionCandidatesByRoomID[roomID] ?? mentionCandidates
        let candidatesByToken = Dictionary(
            candidates.flatMap { candidate in
                candidate.tokens.map { ($0, candidate) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !candidatesByToken.isEmpty else {
            return []
        }

        var references: [TrixMentionReference] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let atIndex = text[index...].firstIndex(of: "@") else {
                break
            }

            if atIndex > text.startIndex {
                let previous = text[text.index(before: atIndex)]
                if Self.isMentionTokenCharacter(previous) {
                    index = text.index(after: atIndex)
                    continue
                }
            }

            var endIndex = text.index(after: atIndex)
            while endIndex < text.endIndex, Self.isMentionTokenCharacter(text[endIndex]) {
                endIndex = text.index(after: endIndex)
            }

            guard endIndex > text.index(after: atIndex) else {
                index = endIndex
                continue
            }

            let displayText = String(text[atIndex..<endIndex])
            if let candidate = candidatesByToken[displayText.lowercased()] {
                let range = TrixTextReferenceRange(
                    begin: atIndex.utf16Offset(in: text),
                    end: endIndex.utf16Offset(in: text)
                )
                if range.isValid(in: text) {
                    references.append(
                        TrixMentionReference(
                            targetUserID: candidate.userID,
                            displayText: displayText,
                            range: range
                        )
                    )
                }
            }

            index = endIndex
        }

        return references
    }

    private func editActiveMessage(
        text: String,
        roomID: String,
        session: TrixSession,
        service: TrixRoomService
    ) async -> TrixTimelineItem? {
        guard let editingMessage else {
            return nil
        }

        let didEdit = await editText(
            messageID: editingMessage.id,
            newText: text,
            roomID: roomID,
            session: session,
            service: service
        )
        return didEdit ? items.first(where: { $0.id == editingMessage.id }) : nil
    }

    private func canEdit(_ item: TrixTimelineItem, currentUserID: String) -> Bool {
        guard isOwnEditableText(item, currentUserID: currentUserID) else {
            return false
        }

        return latestEditableOwnTextItem(currentUserID: currentUserID)?.id == item.id
    }

    private func canRetract(_ item: TrixTimelineItem, currentUserID: String) -> Bool {
        isOwnEditableText(item, currentUserID: currentUserID)
    }

    private func isOwnEditableText(_ item: TrixTimelineItem, currentUserID: String) -> Bool {
        Self.normalizedUserKey(item.sender) == Self.normalizedUserKey(currentUserID) &&
            item.attachment == nil &&
            !item.isRetracted &&
            item.deliveryState != .pending &&
            item.deliveryState != .failed &&
            !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func latestEditableOwnTextItem(currentUserID: String) -> TrixTimelineItem? {
        items.last { item in
            isOwnEditableText(item, currentUserID: currentUserID)
        }
    }

    private static func normalizedMentionCandidates(_ candidates: [TrixMentionCandidate]) -> [TrixMentionCandidate] {
        var seen = Set<String>()
        return candidates
            .filter { !$0.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.userID.lowercased()).inserted }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func currentMentionQuery(in draft: String) -> String? {
        guard let atIndex = draft.lastIndex(of: "@") else {
            return nil
        }

        if atIndex > draft.startIndex {
            let previous = draft[draft.index(before: atIndex)]
            guard !isMentionTokenCharacter(previous) else {
                return nil
            }
        }

        let tokenStart = draft.index(after: atIndex)
        let suffix = draft[tokenStart...]
        guard suffix.allSatisfy(isMentionTokenCharacter) else {
            return nil
        }

        return suffix.lowercased()
    }

    private static func isMentionTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                CharacterSet(charactersIn: "._-:").contains(scalar)
        }
    }

    private static func replyReference(for item: TrixTimelineItem) -> TrixReplyReference {
        TrixReplyReference(
            targetMessageID: item.id,
            targetSenderID: item.sender,
            targetRoomID: item.roomID,
            preview: TrixReplyPreview(
                senderID: item.sender,
                body: item.attachment == nil ? item.body : nil,
                attachmentFilename: item.attachment?.filename,
                isUnavailable: item.isRetracted
            )
        )
    }

    private static func item(
        _ item: TrixTimelineItem,
        applyingLocalMetadataFrom metadata: TrixTextMessageSendMetadata
    ) -> TrixTimelineItem {
        guard !metadata.isEmpty else {
            return item
        }

        return TrixTimelineItem(
            id: item.id,
            roomID: item.roomID,
            sender: item.sender,
            timestamp: item.timestamp,
            body: item.body,
            isLocalEcho: item.isLocalEcho,
            attachment: item.attachment,
            deliveryState: item.deliveryState,
            reactions: item.reactions,
            mentions: item.mentions.isEmpty ? metadata.mentions : item.mentions,
            replyTo: item.replyTo ?? metadata.replyTo,
            thread: item.thread ?? metadata.thread,
            editState: item.editState,
            retractionState: item.retractionState,
            readState: item.readState
        )
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
                byID[item.id] = mergedTimelineItem(existingItem, item)
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

    private static func mergedTimelineItem(
        _ existingItem: TrixTimelineItem,
        _ incomingItem: TrixTimelineItem
    ) -> TrixTimelineItem {
        let retractionState = incomingItem.retractionState ?? existingItem.retractionState
        let editState = incomingItem.editState ?? existingItem.editState
        let body: String
        if let retractionState {
            body = retractionState.tombstoneBody
        } else if incomingItem.editState == nil, existingItem.editState != nil {
            body = existingItem.body
        } else {
            body = incomingItem.body
        }

        return TrixTimelineItem(
            id: incomingItem.id,
            roomID: incomingItem.roomID,
            sender: incomingItem.sender,
            timestamp: incomingItem.timestamp,
            body: body,
            isLocalEcho: incomingItem.isLocalEcho,
            attachment: retractionState == nil ? incomingItem.attachment : nil,
            deliveryState: TrixTimelineItem.mergedDeliveryState(
                existingItem.deliveryState,
                incomingItem.deliveryState
            ),
            reactions: retractionState == nil ? mergedReactions(existingItem.reactions, incomingItem.reactions) : [],
            mentions: incomingItem.mentions.isEmpty ? existingItem.mentions : incomingItem.mentions,
            replyTo: incomingItem.replyTo ?? existingItem.replyTo,
            thread: mergedThread(existingItem.thread, incomingItem.thread),
            editState: editState,
            retractionState: retractionState,
            readState: mergedReadState(existingItem.readState, incomingItem.readState)
        )
    }

    private static func mergedReactions(
        _ existingReactions: [TrixMessageReaction],
        _ incomingReactions: [TrixMessageReaction]
    ) -> [TrixMessageReaction] {
        incomingReactions.isEmpty ? existingReactions : incomingReactions
    }

    private static func mergedThread(
        _ existingThread: TrixThreadReference?,
        _ incomingThread: TrixThreadReference?
    ) -> TrixThreadReference? {
        guard let incomingThread else {
            return existingThread
        }
        guard let existingThread,
              existingThread.threadID == incomingThread.threadID else {
            return incomingThread
        }

        return incomingThread.withReplyCount(max(existingThread.replyCount, incomingThread.replyCount))
    }

    private static func mergedReadState(
        _ existingReadState: TrixTimelineReadState,
        _ incomingReadState: TrixTimelineReadState
    ) -> TrixTimelineReadState {
        var receiptsBySender = Dictionary(
            existingReadState.displayedBy.map { ($0.senderID.lowercased(), $0) },
            uniquingKeysWith: { first, second in
                first.displayedAt >= second.displayedAt ? first : second
            }
        )
        for receipt in incomingReadState.displayedBy {
            let key = receipt.senderID.lowercased()
            if let existing = receiptsBySender[key],
               existing.displayedAt > receipt.displayedAt {
                continue
            }
            receiptsBySender[key] = receipt
        }

        return TrixTimelineReadState(
            displayedBy: receiptsBySender.values.sorted { first, second in
                first.displayedAt < second.displayedAt
            }
        )
    }

    private static func normalizedUserKey(_ userID: String) -> String {
        (try? TrixUserIdentity.normalizedXMPPUserID(userID)) ??
            userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
