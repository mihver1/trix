import SwiftUI

@main
struct TrixMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.start()
                }
        }
        .defaultSize(width: 1220, height: 780)
    }
}
