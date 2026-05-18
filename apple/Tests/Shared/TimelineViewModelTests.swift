import Foundation
import XCTest
@testable import Trix

@MainActor
final class TimelineViewModelTests: XCTestCase {
    func testRoomSwitchClearsPreviousTimelineWhileNetworkLoadIsPending() async {
        let service = TimelineGateService(
            timelines: [
                "room-a": [Self.item(id: "a", roomID: "room-a", timestamp: 0)],
                "room-b": [Self.item(id: "b", roomID: "room-b", timestamp: 1)],
            ],
            delayedTimelineRoomIDs: ["room-b"]
        )
        let viewModel = TimelineViewModel()

        await viewModel.load(roomID: "room-a", session: Self.session, service: service)
        XCTAssertEqual(viewModel.items.map(\.id), ["a"])

        let loadTask = Task {
            await viewModel.load(roomID: "room-b", session: Self.session, service: service)
        }
        await service.waitForTimelineRequest(roomID: "room-b")

        XCTAssertEqual(viewModel.roomID, "room-b")
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(viewModel.loadProgress?.roomID, "room-b")

        await service.releaseTimeline(roomID: "room-b")
        await loadTask.value

        XCTAssertEqual(viewModel.items.map(\.id), ["b"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.loadProgress)
    }

    func testCachedTimelineForNewRoomAppearsBeforeArchiveSyncCompletes() async {
        let service = TimelineGateService(
            cachedTimelines: [
                "room-b": [Self.item(id: "b-cache", roomID: "room-b", timestamp: 1)],
            ],
            timelines: [
                "room-a": [Self.item(id: "a", roomID: "room-a", timestamp: 0)],
                "room-b": [Self.item(id: "b-live", roomID: "room-b", timestamp: 2)],
            ],
            delayedTimelineRoomIDs: ["room-b"]
        )
        let viewModel = TimelineViewModel()

        await viewModel.load(roomID: "room-a", session: Self.session, service: service)
        XCTAssertEqual(viewModel.items.map(\.id), ["a"])

        let loadTask = Task {
            await viewModel.load(roomID: "room-b", session: Self.session, service: service)
        }
        await service.waitForTimelineRequest(roomID: "room-b")

        XCTAssertEqual(viewModel.roomID, "room-b")
        XCTAssertEqual(viewModel.items.map(\.id), ["b-cache"])
        XCTAssertTrue(viewModel.isLoading)

        await service.releaseTimeline(roomID: "room-b")
        await loadTask.value

        XCTAssertEqual(viewModel.items.map(\.id), ["b-cache", "b-live"])
        XCTAssertFalse(viewModel.isLoading)
    }

    private static let session = TrixSession(
        userID: "@me:trix.selfhost.ru",
        deviceID: "TEST",
        homeserverURL: XMPPClientConfiguration.connectionURL,
        accessToken: "test-password",
        refreshToken: nil,
        oidcData: nil,
        sdkStoreID: "test",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    private static func item(id: String, roomID: String, timestamp: TimeInterval) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: "@peer:trix.selfhost.ru",
            timestamp: Date(timeIntervalSince1970: timestamp),
            body: id,
            isLocalEcho: false,
            attachment: nil,
            deliveryState: .delivered
        )
    }
}

private actor TimelineGateService: TrixRoomService {
    private let cachedTimelines: [String: [TrixTimelineItem]]
    private let timelines: [String: [TrixTimelineItem]]
    private var delayedTimelineRoomIDs: Set<String>
    private var requestedTimelineRoomIDs: Set<String> = []
    private var timelineRequestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var timelineReleaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        cachedTimelines: [String: [TrixTimelineItem]] = [:],
        timelines: [String: [TrixTimelineItem]],
        delayedTimelineRoomIDs: Set<String> = []
    ) {
        self.cachedTimelines = cachedTimelines
        self.timelines = timelines
        self.delayedTimelineRoomIDs = delayedTimelineRoomIDs
    }

    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        cachedTimelines[roomID, default: []]
    }

    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        requestedTimelineRoomIDs.insert(roomID)
        let waiters = timelineRequestWaiters.removeValue(forKey: roomID) ?? []
        for waiter in waiters {
            waiter.resume()
        }

        if delayedTimelineRoomIDs.contains(roomID) {
            await withCheckedContinuation { continuation in
                timelineReleaseWaiters[roomID] = continuation
            }
        }

        return timelines[roomID, default: []]
    }

    func waitForTimelineRequest(roomID: String) async {
        if requestedTimelineRoomIDs.contains(roomID) {
            return
        }

        await withCheckedContinuation { continuation in
            timelineRequestWaiters[roomID, default: []].append(continuation)
        }
    }

    func releaseTimeline(roomID: String) {
        delayedTimelineRoomIDs.remove(roomID)
        timelineReleaseWaiters.removeValue(forKey: roomID)?.resume()
    }

    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        throw TrixClientError.roomUnavailable
    }

    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction] {
        throw TrixClientError.reactionsUnavailable
    }

    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability {
        .blocked(roomID: roomID, reason: .unavailable)
    }

    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        throw TrixClientError.attachmentTransferFailed
    }

    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload {
        throw TrixClientError.attachmentDownloadUnavailable
    }
}
