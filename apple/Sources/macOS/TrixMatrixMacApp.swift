import SwiftUI

@main
struct TrixMatrixMacApp: App {
    @StateObject private var model = MatrixAppModel()

    init() {
        MatrixLiveSmokeRunner.installIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            MatrixRootView(model: model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
