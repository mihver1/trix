import Foundation
import XCTest
@testable import Trix

final class TrixGroupLeaveOperationTests: XCTestCase {
    func testControlPlaneSuccessTreatsLocalMUCLeaveAsBestEffort() async throws {
        let recorder = GroupLeaveRecorder(localLeaveError: TrixClientError.roomUnavailable)
        let operation = TrixGroupLeaveOperation(
            controlPlaneLeave: recorder.controlPlaneLeave(roomID:session:),
            localMUCLeave: recorder.localMUCLeave
        )

        try await operation.leave(roomID: "smoke@conference.trix.selfhost.ru", session: Self.session)

        let events = await recorder.events
        XCTAssertEqual(events, [.controlPlane, .localMUC])
    }

    func testControlPlaneFailureSkipsLocalMUCLeave() async throws {
        let recorder = GroupLeaveRecorder(controlPlaneError: TrixClientError.groupLeaveUnavailable)
        let operation = TrixGroupLeaveOperation(
            controlPlaneLeave: recorder.controlPlaneLeave(roomID:session:),
            localMUCLeave: recorder.localMUCLeave
        )

        do {
            try await operation.leave(roomID: "smoke@conference.trix.selfhost.ru", session: Self.session)
            XCTFail("Expected control-plane leave failure to stop the operation")
        } catch TrixClientError.groupLeaveUnavailable {
            // Expected.
        }

        let events = await recorder.events
        XCTAssertEqual(events, [.controlPlane])
    }

    private static let session = TrixSession(
        userID: "peer@trix.selfhost.ru",
        deviceID: "test-device",
        homeserverURL: URL(string: "xmpp://trix.selfhost.ru")!,
        accessToken: "test-password",
        refreshToken: nil,
        oidcData: nil,
        sdkStoreID: "test",
        createdAt: Date()
    )
}

private actor GroupLeaveRecorder {
    enum Event: Equatable {
        case controlPlane
        case localMUC
    }

    private(set) var events: [Event] = []
    private let controlPlaneError: Error?
    private let localLeaveError: Error?

    init(controlPlaneError: Error? = nil, localLeaveError: Error? = nil) {
        self.controlPlaneError = controlPlaneError
        self.localLeaveError = localLeaveError
    }

    func controlPlaneLeave(roomID: String, session: TrixSession) async throws {
        events.append(.controlPlane)
        if let controlPlaneError {
            throw controlPlaneError
        }
    }

    func localMUCLeave() async throws {
        events.append(.localMUC)
        if let localLeaveError {
            throw localLeaveError
        }
    }
}
