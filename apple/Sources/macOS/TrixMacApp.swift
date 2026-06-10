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
        .commands {
            TrixMacGoCommands(model: model)
        }

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

private struct TrixMacGoCommands: Commands {
    @ObservedObject var model: TrixAppModel

    var body: some Commands {
        CommandMenu("Go") {
            Button("Quick Open…") {
                model.presentQuickSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!model.isAuthenticated)

            Button("Next Unread Room") {
                model.selectNextUnreadRoom()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!model.isAuthenticated)
        }
    }
}
