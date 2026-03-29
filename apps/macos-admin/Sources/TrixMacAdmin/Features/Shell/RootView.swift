import SwiftUI

struct RootView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        NavigationSplitView {
            ClusterSidebarView(model: model)
        } detail: {
            detailContent
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        }
        .sheet(isPresented: Binding(
            get: { model.clusterEditorDraft != nil },
            set: { if !$0 { model.cancelClusterEditor() } }
        )) {
            NavigationStack {
                ClusterProfileEditorView(model: model)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.selectedCluster == nil {
            ContentUnavailableView(
                "No cluster",
                systemImage: "server.rack",
                description: Text("Add a cluster profile in the sidebar.")
            )
        } else if model.activeSession == nil {
            VStack(alignment: .leading, spacing: 16) {
                clusterHeader
                if model.requiresReauthentication {
                    Label("Your session expired. Sign in again to continue.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                AdminLoginView(model: model)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                clusterHeader
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                Divider()
                NavigationStack {
                    AdminWorkspaceView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var clusterHeader: some View {
        if let cluster = model.selectedCluster {
            VStack(alignment: .leading, spacing: 4) {
                Text(cluster.displayName)
                    .font(.title2)
                HStack(spacing: 8) {
                    Text(cluster.environmentLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    sessionStateLabel
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Sign out") {
                        Task {
                            await model.signOut()
                        }
                    }
                    .disabled(model.activeSession == nil)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var sessionStateLabel: some View {
        if model.requiresReauthentication {
            Text("Reconnect required")
                .foregroundStyle(.orange)
        } else if let session = model.activeSession {
            Text("Signed in as \(session.username)")
        } else {
            Text("Not signed in")
        }
    }
}
