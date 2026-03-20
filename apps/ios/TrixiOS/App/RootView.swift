import SwiftUI

struct RootView: View {
    @AppStorage(ServerConfiguration.baseURLDefaultsKey)
    private var serverBaseURL = ServerConfiguration.defaultBaseURL.absoluteString

    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.isAwaitingApproval {
                NavigationStack {
                    PendingApprovalView(
                        serverBaseURL: $serverBaseURL,
                        model: model
                    )
                }
            } else if model.hasProvisionedIdentity {
                DashboardView(
                    serverBaseURL: $serverBaseURL,
                    model: model
                )
            } else {
                NavigationStack {
                    CreateAccountView(
                        serverBaseURL: $serverBaseURL,
                        model: model
                    )
                }
            }
        }
        .task {
            await model.start(baseURLString: serverBaseURL)
        }
    }
}

#Preview {
    RootView()
}
