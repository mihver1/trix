import UIKit
import SwiftUI

@main
struct TrixiOSApp: App {
    @UIApplicationDelegateAdaptor(TrixiOSAppDelegate.self) private var appDelegate
    @StateObject private var model = TrixAppModel.makeDefault()

    init() {
        XMPPLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            TrixRootView(model: model)
                .task {
                    TrixAPNsCoordinator.shared.attach(model: model)
                    TrixVoIPPushCoordinator.shared.attach(model: model)
                }
        }
    }
}
