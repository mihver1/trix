import SwiftUI

@main
struct TrixAdminApp: App {
    @StateObject private var model = TrixAdminAppModel()

    var body: some Scene {
        WindowGroup {
            TrixAdminRootView(model: model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 780)
    }
}
