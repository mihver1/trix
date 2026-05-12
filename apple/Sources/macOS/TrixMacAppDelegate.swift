import AppKit
import UserNotifications

final class TrixMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        Task { @MainActor in
            await TrixAPNsCoordinator.shared.requestUserNotificationAuthorization()
        }
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            TrixAPNsCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            TrixAPNsCoordinator.shared.didFailToRegisterForRemoteNotifications()
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in
            _ = await TrixAPNsCoordinator.shared.didReceiveRemoteNotification(
                userInfo: userInfo,
                applicationIsActive: application.isActive
            )
        }
    }
}
