import Foundation
import UserNotifications

@MainActor
final class TrixAPNsCoordinator {
    static let shared = TrixAPNsCoordinator()

    private struct PendingRemoteNotification {
        let userInfo: [AnyHashable: Any]
        let applicationIsActive: Bool
    }

    private weak var model: TrixAppModel?
    private var latestToken: TrixAPNsDeviceToken?
    private var pendingRemoteNotifications: [PendingRemoteNotification] = []
    private var applicationIsActive = false
    private var didRequestUserNotificationAuthorization = false
    private let notificationCenter = UNUserNotificationCenter.current()

    private init() {}

    func attach(model: TrixAppModel) {
        self.model = model

        Task {
            await requestUserNotificationAuthorization()
        }

        guard let latestToken else {
            drainPendingRemoteNotifications()
            return
        }

        Task {
            await model.registerAPNsDeviceToken(latestToken)
        }
        drainPendingRemoteNotifications()
    }

    func setApplicationIsActive(_ isActive: Bool) {
        applicationIsActive = isActive
    }

    func requestUserNotificationAuthorization() async {
        guard !didRequestUserNotificationAuthorization else {
            return
        }
        didRequestUserNotificationAuthorization = true

        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return
        }

        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func didRegister(deviceToken: Data) {
        let token = TrixAPNsDeviceToken(data: deviceToken)
        latestToken = token

        guard let model else {
            return
        }

        Task {
            await model.registerAPNsDeviceToken(token)
        }
    }

    func didFailToRegisterForRemoteNotifications() {
        latestToken = nil
    }

    func didReceiveRemoteNotification(
        userInfo: [AnyHashable: Any],
        applicationIsActive explicitApplicationIsActive: Bool? = nil
    ) async -> Bool {
        let isActive = explicitApplicationIsActive ?? applicationIsActive
        guard let model else {
            pendingRemoteNotifications.append(
                PendingRemoteNotification(
                    userInfo: userInfo,
                    applicationIsActive: isActive
                )
            )
            return false
        }

        let result = await model.handleRemoteNotification(
            userInfo: userInfo,
            applicationIsActive: isActive
        )
        await apply(result)
        return result.didProcess
    }

    private func drainPendingRemoteNotifications() {
        guard !pendingRemoteNotifications.isEmpty else {
            return
        }

        let pending = pendingRemoteNotifications
        pendingRemoteNotifications = []
        Task {
            for notification in pending {
                _ = await didReceiveRemoteNotification(
                    userInfo: notification.userInfo,
                    applicationIsActive: notification.applicationIsActive
                )
            }
        }
    }

    private func apply(_ result: TrixRemoteNotificationHandlingResult) async {
        guard result.didProcess else {
            return
        }

        if result.badgeCount >= 0 {
            try? await notificationCenter.setBadgeCount(result.badgeCount)
        }

        guard let localNotification = result.localNotification else {
            return
        }

        await scheduleLocalNotification(localNotification)
    }

    private func scheduleLocalNotification(_ notification: TrixLocalNotificationRequest) async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.badge = NSNumber(value: notification.badgeCount)
        content.threadIdentifier = notification.threadIdentifier
        content.userInfo = [
            "trix": [
                "type": "local-unread",
                "thread": notification.threadIdentifier,
            ],
        ]

        let request = UNNotificationRequest(
            identifier: "trix-local-unread-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }
}

enum TrixUserNotificationPresentation {
    static func shouldPresentForegroundNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let trix = stringKeyedDictionary(userInfo["trix"]),
              trix["type"] as? String == "local-unread" else {
            return false
        }

        return true
    }

    static var foregroundOptions: UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    private static func stringKeyedDictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }

        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.reduce(into: [:]) { partialResult, pair in
                guard let key = pair.key as? String else {
                    return
                }
                partialResult[key] = pair.value
            }
        }

        return nil
    }
}
