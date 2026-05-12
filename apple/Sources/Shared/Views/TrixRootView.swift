import SwiftUI

struct TrixRootView: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                VStack(spacing: 14) {
                    TrixAvatarView(
                        title: "Trix",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        size: 58
                    )
                    ProgressView("Restoring session")
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TrixDesign.screenBackground)
            } else if model.isAuthenticated {
                TrixWorkspaceView(model: model)
            } else {
                TrixLoginView(model: model)
            }
        }
        .task {
            await model.start()
        }
    }
}

#if os(iOS)
private struct TrixWorkspaceView: View {
    @ObservedObject var model: TrixAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                TrixRoomListView(model: model, mode: .phoneInbox)
                    .navigationTitle("Chats")
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
            }

            NavigationStack {
                TrixSettingsView(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(TrixDesign.accent)
        .task(id: scenePhase) {
            TrixAPNsCoordinator.shared.setApplicationIsActive(scenePhase == .active)
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}
#else
private struct TrixWorkspaceView: View {
    @ObservedObject var model: TrixAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            TrixRoomListView(model: model, mode: .sidebar)
                .navigationTitle("Trix")
        } detail: {
            TrixWorkspaceDetailView(model: model)
        }
        .tint(TrixDesign.accent)
        .task(id: scenePhase) {
            TrixAPNsCoordinator.shared.setApplicationIsActive(scenePhase == .active)
            guard scenePhase == .active else {
                return
            }

            await model.runForegroundRefreshLoop()
        }
    }
}

private struct TrixWorkspaceDetailView: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        if let selectedRoom = model.selectedRoom {
            TrixTimelineView(model: model, room: selectedRoom)
        } else {
            TrixEmptyStateView(
                title: "Choose a room",
                systemImage: "bubble.left.and.bubble.right",
                message: "Trix rooms appear in the sidebar after sync."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TrixDesign.screenBackground)
        }
    }
}
#endif
