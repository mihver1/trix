import XCTest
@testable import Trix

final class TrixRemoteNotificationPayloadTests: XCTestCase {
    func testAcceptsGenericVisibleSyncNotification() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "alert": [
                    "title": "Trix",
                    "body": "New encrypted message",
                ],
                "badge": 2,
                "content-available": 1,
                "sound": "default",
            ],
            "trix": [
                "type": "sync",
                "account": "alice@trix.selfhost.ru",
                "room": "room@example",
            ],
        ])

        XCTAssertTrue(payload.isSyncNotification)
        XCTAssertTrue(payload.presentsRemoteNotification)
        XCTAssertEqual(payload.accountID, "alice@trix.selfhost.ru")
        XCTAssertEqual(payload.roomID, "room@example")
        XCTAssertEqual(payload.badge, 2)
    }

    func testAcceptsSilentSyncNotificationFallback() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "content-available": 1,
            ],
            "trix": [
                "type": "sync",
            ],
        ])

        XCTAssertTrue(payload.isSyncNotification)
        XCTAssertFalse(payload.presentsRemoteNotification)
    }

    func testRejectsNonGenericAlertBody() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "alert": [
                    "title": "Trix",
                    "body": "Alice: secret text",
                ],
                "content-available": 1,
                "sound": "default",
            ],
            "trix": [
                "type": "sync",
            ],
        ])

        XCTAssertFalse(payload.isSyncNotification)
        XCTAssertFalse(payload.presentsRemoteNotification)
    }

    func testRejectsPlaintextBodyOutsideGenericAlert() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "alert": [
                    "title": "Trix",
                    "body": "New encrypted message",
                ],
                "content-available": 1,
                "sound": "default",
            ],
            "trix": [
                "type": "sync",
                "body": "secret text",
            ],
        ])

        XCTAssertFalse(payload.isSyncNotification)
        XCTAssertTrue(payload.presentsRemoteNotification)
    }

    func testRejectsNotificationProfileHints() {
        let payload = TrixRemoteNotificationPayload(userInfo: [
            "aps": [
                "content-available": 1,
            ],
            "trix": [
                "type": "sync",
                "notification_profile": "muted",
            ],
        ])

        XCTAssertFalse(payload.isSyncNotification)
        XCTAssertFalse(payload.presentsRemoteNotification)
    }
}
