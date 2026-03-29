import AppKit
import SwiftUI

@main
struct TrixMacAdminApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AdminAppModel()

    init() {
        if CommandLine.arguments.contains(MacAdminUITestLaunchArgument.enableUITesting) {
            UserDefaults.trixMacAdminIsUITesting = true
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
