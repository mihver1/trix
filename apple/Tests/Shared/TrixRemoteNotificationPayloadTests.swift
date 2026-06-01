import Foundation
import Security
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

    func testForegroundPresentationOnlyAllowsLocalUnreadNotifications() {
        XCTAssertTrue(
            TrixUserNotificationPresentation.shouldPresentForegroundNotification(userInfo: [
                "trix": [
                    "type": "local-unread",
                    "thread": "bob@trix.selfhost.ru",
                ],
            ])
        )
        XCTAssertFalse(
            TrixUserNotificationPresentation.shouldPresentForegroundNotification(userInfo: [
                "trix": [
                    "type": "sync",
                ],
            ])
        )
    }

    @MainActor
    func testBackgroundSyncNotificationAvoidsPerRoomReadMarkerRefresh() async throws {
        let fixture = try makeRemoteNotificationHandlingFixture()
        defer { fixture.cleanup() }

        await fixture.model.login(userID: fixture.accountID, password: "test-password")
        XCTAssertNil(fixture.model.errorMessage)

        let baseline = await fixture.service.readMarkerStateRequestCount()
        let result = await fixture.model.handleRemoteNotification(
            userInfo: Self.syncPayload(account: fixture.accountID),
            applicationIsActive: false
        )

        XCTAssertTrue(result.didProcess)
        let requestsAfterNotification = await fixture.service.readMarkerStateRequestCount()
        XCTAssertEqual(requestsAfterNotification, baseline)
    }

    @MainActor
    func testForegroundSyncNotificationKeepsFullReadMarkerRefresh() async throws {
        let fixture = try makeRemoteNotificationHandlingFixture()
        defer { fixture.cleanup() }

        await fixture.model.login(userID: fixture.accountID, password: "test-password")
        XCTAssertNil(fixture.model.errorMessage)

        let baseline = await fixture.service.readMarkerStateRequestCount()
        let result = await fixture.model.handleRemoteNotification(
            userInfo: Self.syncPayload(account: fixture.accountID),
            applicationIsActive: true
        )

        XCTAssertTrue(result.didProcess)
        let requestsAfterNotification = await fixture.service.readMarkerStateRequestCount()
        XCTAssertGreaterThan(requestsAfterNotification, baseline)
    }

    private static func syncPayload(account: String) -> [AnyHashable: Any] {
        [
            "aps": [
                "content-available": 1,
            ],
            "trix": [
                "type": "sync",
                "account": account,
            ],
        ]
    }
}

@MainActor
private func makeRemoteNotificationHandlingFixture() throws -> RemoteNotificationHandlingFixture {
    let accountID = "@me:trix.selfhost.ru"
    let service = MockTrixService(now: Date(timeIntervalSince1970: 100))
    let stickerKeychainService = "com.softgrid.trix.tests.remote-notifications.stickers.\(UUID().uuidString)"
    let mediaKeychainService = "com.softgrid.trix.tests.remote-notifications.media.\(UUID().uuidString)"
    let notificationKeychainService = "com.softgrid.trix.tests.remote-notifications.notifications.\(UUID().uuidString)"
    let mediaSettingsSuiteName = "com.softgrid.trix.tests.remote-notifications.media-settings.\(UUID().uuidString)"
    let mediaSettingsUserDefaults = try XCTUnwrap(UserDefaults(suiteName: mediaSettingsSuiteName))
    let stickerStore = TrixStickerLibraryStore(
        keychainService: stickerKeychainService,
        keychainAccount: "key",
        directoryName: "RemoteNotificationStickerLibraryTests-\(UUID().uuidString)"
    )
    let mediaStore = TrixMediaCacheStore(
        keychainService: mediaKeychainService,
        keychainAccount: "key",
        directoryName: "RemoteNotificationMediaCacheTests-\(UUID().uuidString)"
    )
    let notificationStore = TrixRoomNotificationProfileStore(
        keychainService: notificationKeychainService,
        keychainAccount: "key"
    )

    let model = TrixAppModel(
        sessionStore: RemoteNotificationTestSessionStore(),
        registrationService: MockInviteRegistrationService(),
        stickerLibraryStore: stickerStore,
        mediaCacheStore: mediaStore,
        mediaCacheSettingsStore: UserDefaultsTrixMediaCacheSettingsStore(userDefaults: mediaSettingsUserDefaults),
        roomNotificationProfileStore: notificationStore,
        trixService: service
    )

    return RemoteNotificationHandlingFixture(
        accountID: accountID,
        service: service,
        model: model,
        cleanup: {
            try? stickerStore.clear(accountID: accountID)
            _ = try? mediaStore.clearAll(accountID: accountID)
            try? notificationStore.clear(accountID: accountID)
            mediaSettingsUserDefaults.removePersistentDomain(forName: mediaSettingsSuiteName)
            deleteRemoteNotificationTestKeychainItem(service: stickerKeychainService)
            deleteRemoteNotificationTestKeychainItem(service: mediaKeychainService)
            deleteRemoteNotificationTestKeychainItem(service: notificationKeychainService)
        }
    )
}

private struct RemoteNotificationHandlingFixture {
    let accountID: String
    let service: MockTrixService
    let model: TrixAppModel
    let cleanup: () -> Void
}

private struct RemoteNotificationTestSessionStore: TrixSessionStore {
    func loadSession() throws -> TrixSession? {
        nil
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}

private func deleteRemoteNotificationTestKeychainItem(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "key",
    ] as CFDictionary)
}
