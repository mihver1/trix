import SwiftUI

struct MatrixRootView: View {
    @ObservedObject var model: MatrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                VStack(spacing: 14) {
                    MatrixAvatarView(
                        title: "Trix",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        size: 58
                    )
                    ProgressView("Restoring session")
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MatrixDesign.screenBackground)
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

#if os(iOS)
private struct MatrixWorkspaceView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                MatrixRoomListView(model: model, mode: .phoneInbox)
                    .navigationTitle("Chats")
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                MatrixSettingsView(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(MatrixDesign.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}
#else
private struct MatrixWorkspaceView: View {
    @ObservedObject var model: MatrixAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            MatrixRoomListView(model: model, mode: .sidebar)
                .navigationTitle("Trix")
        } detail: {
            MatrixWorkspaceDetailView(model: model)
        }
        .tint(MatrixDesign.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}

private struct MatrixWorkspaceDetailView: View {
    @ObservedObject var model: MatrixAppModel

    var body: some View {
        if let selectedRoom = model.selectedRoom {
            MatrixTimelineView(model: model, room: selectedRoom)
        } else {
            MatrixEmptyStateView(
                title: "Choose a room",
                systemImage: "bubble.left.and.bubble.right",
                message: "Matrix rooms appear in the sidebar after sync."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MatrixDesign.screenBackground)
        }
    }
}
#endif
