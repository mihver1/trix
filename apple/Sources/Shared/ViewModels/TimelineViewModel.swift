import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var roomID: String?
    @Published private(set) var items: [MatrixTimelineItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?

    func load(roomID: String, session: MatrixSession, service: MatrixRoomService) async {
        self.roomID = roomID
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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

    func clear() {
        roomID = nil
        items = []
        isLoading = false
        isSending = false
        errorMessage = nil
    }
}
