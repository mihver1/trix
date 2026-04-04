import SwiftUI

struct AdminWorkspaceView: View {
    @ObservedObject var model: AdminAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Workspace", selection: $model.selectedWorkspaceSection) {
                ForEach(AdminWorkspaceSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch model.selectedWorkspaceSection {
                case .overview:
                    OverviewView(model: model)
                case .registration:
                    RegistrationSettingsView(model: model)
                case .server:
                    ServerSettingsView(model: model)
                case .users:
                    UserListView(model: model)
                case .featureFlags:
                    FeatureFlagsWorkspaceView(model: model)
                case .debugMetrics:
                    DebugMetricsWorkspaceView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
