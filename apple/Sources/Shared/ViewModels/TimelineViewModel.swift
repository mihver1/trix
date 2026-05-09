import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var roomID: String?
    @Published private(set) var items: [TrixTimelineItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var isSendingAttachment = false
    @Published private(set) var isLoadingAttachmentAvailability = false
    @Published private(set) var downloadingAttachmentID: String?
    @Published private(set) var downloadedAttachment: TrixAttachmentDownload?
    @Published private(set) var attachmentSendAvailability: TrixAttachmentSendAvailability?
    @Published private(set) var typingUserIDs: [String] = []
    @Published private(set) var errorMessage: String?
    private var cachedItemsByRoomID: [String: [TrixTimelineItem]] = [:]

    func load(
        roomID: String,
        session: TrixSession,
        service: TrixRoomService,
        showsLoading: Bool = true
    ) async {
        self.roomID = roomID
        if showsLoading {
            isLoading = true
        }
        errorMessage = nil
        defer {
            if showsLoading {
                isLoading = false
            }
        }

        do {
            let loadedItems = try await service.timeline(roomID: roomID, session: session)
            guard self.roomID == roomID else {
                return
            }

            let mergedItems = Self.mergedTimelineItems(
                cachedItemsByRoomID[roomID] ?? [],
                loadedItems
            )
            cachedItemsByRoomID[roomID] = mergedItems
            items = mergedItems
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

        downloadingAttachmentID = item.id
        errorMessage = nil
        defer { downloadingAttachmentID = nil }

        do {
            downloadedAttachment = try await service.downloadAttachment(attachment, session: session)
        } catch {
            errorMessage = error.trixUserFacingMessage
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
        isSending = false
        isSendingAttachment = false
        isLoadingAttachmentAvailability = false
        downloadingAttachmentID = nil
        downloadedAttachment = nil
        attachmentSendAvailability = nil
        typingUserIDs = []
        errorMessage = nil
        cachedItemsByRoomID = [:]
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
