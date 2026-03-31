import AppKit
import SwiftUI

@main
struct TrixMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .background(WindowViewportConfigurator())
                .task {
                    appDelegate.model = model
                    let configuration = MacUITestLaunchConfiguration.current
                    do {
                        let bootstrap = MacUITestAppBootstrap.production()
                        if let urlString = try await bootstrap.prepareForLaunch(configuration: configuration) {
                            model.serverBaseURLString = urlString
                        }
                    } catch {
                        if configuration.isEnabled {
                            fatalError("Mac UI test bootstrap failed: \(error.localizedDescription)")
                        }
                    }
                    await model.start()
                }
        }
        .defaultSize(width: 1180, height: 720)

        Settings {
            WorkspaceSettingsView(model: model)
        }
        .defaultSize(width: 960, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor [weak self] in
            await self?.model?.handleRegisteredForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.model?.handleRemoteNotificationsRegistrationFailure(error)
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor [weak self] in
            await self?.model?.handleRemoteNotification(userInfo: userInfo)
        }
    }
}
