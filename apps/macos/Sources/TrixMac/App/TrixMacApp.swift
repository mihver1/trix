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
