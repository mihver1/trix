import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var roomID: String?
    @Published private(set) var items: [MatrixTimelineItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var isSendingAttachment = false
    @Published private(set) var downloadingAttachmentID: String?
    @Published private(set) var downloadedAttachment: MatrixAttachmentDownload?
    @Published private(set) var errorMessage: String?
    private var cachedItemsByRoomID: [String: [MatrixTimelineItem]] = [:]

    func load(
        roomID: String,
        session: MatrixSession,
        service: MatrixRoomService,
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
                loadedItems,
                cachedItemsByRoomID[roomID] ?? []
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
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func send(
        text: String,
        roomID: String,
        session: MatrixSession,
        service: MatrixRoomService
    ) async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let item = try await service.sendText(text, roomID: roomID, session: session)
            store(item, for: roomID)
        } catch {
            if self.roomID == roomID {
                errorMessage = error.matrixUserFacingMessage
            }
        }
    }

    func sendAttachment(
        _ attachment: MatrixAttachmentUpload,
        roomID: String,
        session: MatrixSession,
        service: MatrixRoomService
    ) async {
        isSendingAttachment = true
        errorMessage = nil
        defer { isSendingAttachment = false }

        do {
            let item = try await service.sendAttachment(attachment, roomID: roomID, session: session)
            store(item, for: roomID)
        } catch {
            if self.roomID == roomID {
                errorMessage = error.matrixUserFacingMessage
            }
        }
    }

    func downloadAttachment(
        for item: MatrixTimelineItem,
        session: MatrixSession,
        service: MatrixRoomService
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
            errorMessage = error.matrixUserFacingMessage
        }
    }

    func dismissDownloadedAttachment() {
        downloadedAttachment = nil
    }

    func clear() {
        roomID = nil
        items = []
        isLoading = false
        isSending = false
        isSendingAttachment = false
        downloadingAttachmentID = nil
        downloadedAttachment = nil
        errorMessage = nil
        cachedItemsByRoomID = [:]
    }

    private func store(_ item: MatrixTimelineItem, for roomID: String) {
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
        _ lhs: [MatrixTimelineItem],
        _ rhs: [MatrixTimelineItem]
    ) -> [MatrixTimelineItem] {
        var byID: [String: MatrixTimelineItem] = [:]
        for item in lhs {
            byID[item.id] = item
        }
        for item in rhs {
            byID[item.id] = item
        }

        return byID.values.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
    }
}
