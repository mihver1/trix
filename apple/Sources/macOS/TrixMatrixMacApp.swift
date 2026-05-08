import SwiftUI

@main
struct TrixMatrixMacApp: App {
    @StateObject private var model = MatrixAppModel.makeDefault()

    init() {
        XMPPLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            MatrixMacRootView(model: model)
                .frame(minWidth: 1120, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 760)

        Settings {
            MatrixMacSettingsView(model: model)
        }
        .defaultSize(width: 760, height: 620)
    }
}
