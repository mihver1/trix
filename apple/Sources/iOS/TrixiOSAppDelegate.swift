import UIKit
import UserNotifications

final class TrixiOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        Task { @MainActor in
            TrixVoIPPushCoordinator.shared.start()
            await TrixAPNsCoordinator.shared.requestUserNotificationAuthorization()
        }
        return true
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
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            TrixAPNsCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            TrixAPNsCoordinator.shared.didFailToRegisterForRemoteNotifications()
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await TrixAPNsCoordinator.shared.didReceiveRemoteNotification(
            userInfo: userInfo,
            applicationIsActive: application.applicationState == .active
        ) ? .newData : .noData
    }
}
