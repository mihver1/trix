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
            items = try await service.timeline(roomID: roomID, session: session)
        } catch {
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
            _ = try await service.sendText(text, roomID: roomID, session: session)
            items = try await service.timeline(roomID: roomID, session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
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
            _ = try await service.sendAttachment(attachment, roomID: roomID, session: session)
            items = try await service.timeline(roomID: roomID, session: session)
        } catch {
            errorMessage = error.matrixUserFacingMessage
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
    }
}
