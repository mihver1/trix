import AppKit
import SwiftUI

@main
struct TrixMacApp: App {
    @NSApplicationDelegateAdaptor(TrixMacAppDelegate.self) private var appDelegate
    @StateObject private var model = TrixAppModel.makeDefault()

    init() {
        XMPPLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            TrixMacRootView(model: model)
                .frame(minWidth: 1120, minHeight: 680)
                .task {
                    TrixAPNsCoordinator.shared.attach(model: model)
                }
        }
        .defaultSize(width: 1240, height: 760)

        Settings {
            TrixAppLockProtectedView(model: model) {
                TrixMacSettingsView(model: model)
            }
        }
        .defaultSize(width: 760, height: 620)
    }
}
