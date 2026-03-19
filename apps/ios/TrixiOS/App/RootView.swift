import SwiftUI

struct RootView: View {
    @AppStorage(ServerConfiguration.baseURLDefaultsKey)
    private var serverBaseURL = ServerConfiguration.defaultBaseURL.absoluteString

    @StateObject private var model = AppModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.isAwaitingApproval {
                    PendingApprovalView(
                        serverBaseURL: $serverBaseURL,
                        model: model
                    )
                } else if model.hasProvisionedIdentity {
                    DashboardView(
                        serverBaseURL: $serverBaseURL,
                        model: model
                    )
                } else {
                    CreateAccountView(
                        serverBaseURL: $serverBaseURL,
                        model: model
                    )
                }
            }
            .task {
                await model.start(baseURLString: serverBaseURL)
            }
        }
    }
}

#Preview {
    RootView()
}
