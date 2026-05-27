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
            if XMPPLiveSmokeRunner.isRequested {
                EmptyView()
                    .frame(width: 1, height: 1)
            } else {
                TrixMacRootView(model: model)
                    .frame(minWidth: 1120, minHeight: 680)
                    .task {
                        TrixAPNsCoordinator.shared.attach(model: model)
                    }
            }
        }
        .defaultSize(width: 1240, height: 760)

        Window("Active Call", id: TrixActiveCallWindowID) {
            if XMPPLiveSmokeRunner.isRequested {
                EmptyView()
            } else {
                TrixMacActiveCallWindow(model: model)
            }
        }
        .defaultSize(width: 430, height: 76)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            if XMPPLiveSmokeRunner.isRequested {
                EmptyView()
            } else {
                TrixMacSettingsView(model: model)
            }
        }
        .defaultSize(width: 760, height: 620)
    }
}
