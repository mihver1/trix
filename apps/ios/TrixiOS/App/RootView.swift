import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ServerConfiguration.baseURLDefaultsKey)
    private var serverBaseURL = ServerConfiguration.defaultBaseURL.absoluteString

    @State private var model = AppModel()

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
            do {
                let launchBaseURL = try await UITestAppBootstrap.prepareForLaunch(
                    fallbackBaseURLString: serverBaseURL
                )
                if launchBaseURL != serverBaseURL {
                    serverBaseURL = launchBaseURL
                }
                await model.start(baseURLString: launchBaseURL)
            } catch {
                if UITestLaunchConfiguration.current.isEnabled {
                    preconditionFailure("UI test bootstrap failed: \(error.localizedDescription)")
                }
                await model.start(baseURLString: serverBaseURL)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await model.handleAppDidBecomeActive(baseURLString: serverBaseURL)
                }
            case .background:
                model.handleAppDidEnterBackground(baseURLString: serverBaseURL)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    RootView()
}
