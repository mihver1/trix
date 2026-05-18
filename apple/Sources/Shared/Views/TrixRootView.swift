import SwiftUI

struct TrixRootView: View {
    @ObservedObject var model: TrixAppModel

    var body: some View {
        Group {
            if model.isStarting {
                TrixStartupRestoreView(status: model.startupStatus)
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

struct TrixStartupRestoreView: View {
    let status: TrixStartupStatus

    var body: some View {
        VStack(spacing: 18) {
            TrixAvatarView(
                title: "Trix",
                systemImage: "bubble.left.and.bubble.right.fill",
                size: 58
            )

            ProgressView()
                .controlSize(.regular)

            VStack(spacing: 8) {
                Text("Restoring session")
                    .font(.headline)

                if !status.step.isEmpty {
                    Text(status.step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !status.title.isEmpty {
                    Text(status.title)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }

                if !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TrixDesign.screenBackground)
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
