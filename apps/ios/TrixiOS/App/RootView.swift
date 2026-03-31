import SwiftUI

enum RootStartupBehavior {
    case live
    case preview
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ServerConfiguration.baseURLDefaultsKey)
    private var serverBaseURL = ServerConfiguration.defaultBaseURL.absoluteString

    @State private var model = AppModel()
    private let startupBehavior: RootStartupBehavior

    init(
        model: AppModel = AppModel(),
        startupBehavior: RootStartupBehavior = .live
    ) {
        _model = State(initialValue: model)
        self.startupBehavior = startupBehavior
    }

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
            guard startupBehavior == .live else {
                return
            }

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
            guard startupBehavior == .live else {
                return
            }

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
    RootView(startupBehavior: .preview)
}
