import SwiftUI

struct ClusterSidebarView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        List(selection: clusterSelectionBinding) {
            Section("Clusters") {
                ForEach(model.profiles) { profile in
                    Text(profile.displayName)
                        .tag(profile.id)
                }
            }
        }
        .accessibilityIdentifier(MacAdminAccessibilityIdentifier.sidebar)
        .navigationTitle("Trix Admin")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") {
                    model.beginAddCluster()
                }
            }
            ToolbarItem(placement: .automatic) {
                if let id = model.selectedClusterID {
                    Button("Edit") {
                        model.beginEditSelectedCluster()
                    }
                    .disabled(model.profiles.isEmpty)
                    Button("Remove", role: .destructive) {
                        Task { @MainActor in
                            await model.removeCluster(id: id)
                        }
                    }
                }
            }
        }
    }

    private var clusterSelectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedClusterID },
            set: { newId in
                Task { @MainActor in
                    await model.selectCluster(newId)
                }
            }
        )
    }
}
