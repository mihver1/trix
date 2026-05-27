import AppKit
import UserNotifications

final class TrixMacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        Task { @MainActor in
            await TrixAPNsCoordinator.shared.requestUserNotificationAuthorization()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        completionHandler(
            TrixUserNotificationPresentation.shouldPresentForegroundNotification(userInfo: userInfo)
                ? TrixUserNotificationPresentation.foregroundOptions
                : []
        )
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
