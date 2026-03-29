import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        Group {
            if let overview = model.overview {
                Form {
                    Section("Cluster") {
                        LabeledContent("Name", value: overview.clusterDisplayName)
                        LabeledContent("Environment", value: model.selectedCluster?.environmentLabel ?? "—")
                    }
                    Section("Service") {
                        LabeledContent("Status", value: overview.response.status)
                        LabeledContent("Health", value: overview.response.healthStatus.rawValue)
                        LabeledContent("Version", value: overview.response.version)
                        if let sha = overview.response.gitSha, !sha.isEmpty {
                            LabeledContent("Git SHA", value: sha)
                        }
                        LabeledContent("Uptime (ms)", value: String(overview.response.uptimeMs))
                    }
                    Section("Accounts") {
                        LabeledContent("Users", value: String(overview.response.userCount))
                        LabeledContent("Disabled", value: String(overview.response.disabledUserCount))
                        LabeledContent("Public registration", value: overview.response.allowPublicAccountRegistration ? "On" : "Off")
                    }
                    Section("Session") {
                        LabeledContent("Admin", value: overview.response.adminUsername)
                    }
                }
                .formStyle(.grouped)
            } else if model.isWorkspaceLoading {
                ProgressView("Loading overview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No overview",
                    systemImage: "doc.text",
                    description: Text(model.workspaceError ?? "Select a cluster and sign in.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") {
                    Task { await model.refreshWorkspaceData() }
                }
                .disabled(model.isWorkspaceLoading || model.activeSession == nil)
            }
        }
    }
}
