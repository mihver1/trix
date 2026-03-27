import SwiftUI
import UIKit

@main
struct TrixiOSApp: App {
    init() {
        if UITestLaunchConfiguration.current.disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
