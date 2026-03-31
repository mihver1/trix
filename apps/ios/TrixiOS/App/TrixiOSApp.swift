import SwiftUI
import UIKit

@main
struct TrixiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    private let uiTestConfiguration = UITestLaunchConfiguration.current

    init() {
        if uiTestConfiguration.disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(uiTestConfiguration.colorSchemeOverride)
                .task {
                    appDelegate.model = model
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor [weak self] in
            await self?.model?.handleRegisteredForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.model?.handleRemoteNotificationsRegistrationFailure(error)
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let model else {
            return .noData
        }

        return await model.handleRemoteNotification(userInfo: userInfo)
    }
}
