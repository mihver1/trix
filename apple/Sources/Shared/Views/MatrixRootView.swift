import SwiftUI

struct MatrixRootView: View {
    @ObservedObject var model: MatrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                ProgressView("Restoring session")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isAuthenticated {
                MatrixWorkspaceView(model: model)
            } else {
                MatrixLoginView(model: model)
            }
        }
        .task {
            await model.start()
        }
    }
}

private struct MatrixWorkspaceView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            MatrixRoomListView(model: model)
                .navigationTitle("Trix")
        } detail: {
            if let selectedRoom = model.selectedRoom {
                MatrixTimelineView(model: model, room: selectedRoom)
            } else {
                ContentUnavailableView(
                    "No Room Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a Matrix room from the list.")
                )
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}
