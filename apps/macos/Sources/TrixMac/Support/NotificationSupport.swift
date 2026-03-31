import Foundation
import UserNotifications

final class NotificationPreferencesStore {
    private enum Keys {
        static let isEnabled = "notifications.enabled"
        static let pollingInterval = "notifications.backgroundPollingInterval"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NotificationPreferences {
        var preferences = NotificationPreferences()
        if defaults.object(forKey: Keys.isEnabled) != nil {
            preferences.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        }

        let interval = defaults.double(forKey: Keys.pollingInterval)
        if interval > 0 {
            preferences.backgroundPollingIntervalSeconds = interval
        }

        return preferences
    }

    func save(_ preferences: NotificationPreferences) {
        defaults.set(preferences.isEnabled, forKey: Keys.isEnabled)
        defaults.set(preferences.backgroundPollingIntervalSeconds, forKey: Keys.pollingInterval)
    }
}

@MainActor
final class LocalNotificationCoordinator {
    private let center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter?) {
        self.center = center
    }

    static func makeDefault(bundle: Bundle = .main) -> LocalNotificationCoordinator {
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else {
            return LocalNotificationCoordinator(center: nil)
        }
        return LocalNotificationCoordinator(center: .current())
    }

    var isAvailable: Bool {
        center != nil
    }

    func permissionState() async -> NotificationPermissionState {
        guard let center else {
            return .denied
        }
        let settings = await center.notificationSettings()
        return NotificationPermissionState(settings.authorizationStatus)
    }

    func requestAuthorization() async throws -> NotificationPermissionState {
        guard let center else {
            return .denied
        }
        _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        return await permissionState()
    }

    func postMessageNotification(identifier: String, title: String, body: String) async {
        guard let center else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }
}

private extension NotificationPermissionState {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .notDetermined
        }
    }
}

enum ApplePushRegistrationEnvironment {
    static var current: ApplePushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

func apnsTokenHexString(from deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
}
