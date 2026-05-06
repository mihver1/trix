import SwiftUI

@main
struct TrixMatrixiOSApp: App {
    @StateObject private var model = MatrixAppModel.makeDefault()

    init() {
        MatrixLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            MatrixRootView(model: model)
        }
    }
}
