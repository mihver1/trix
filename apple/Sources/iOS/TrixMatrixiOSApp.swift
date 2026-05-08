import SwiftUI

@main
struct TrixMatrixiOSApp: App {
    @StateObject private var model = MatrixAppModel.makeDefault()

    init() {
        XMPPLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            MatrixRootView(model: model)
        }
    }
}
