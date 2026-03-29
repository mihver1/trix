import SwiftUI
import UIKit

@main
struct TrixiOSApp: App {
    private let uiTestConfiguration = UITestLaunchConfiguration.current

    init() {
        if uiTestConfiguration.disableAnimations {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(uiTestConfiguration.colorSchemeOverride)
        }
    }
}
