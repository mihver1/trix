import Foundation

struct UITestLaunchConfiguration {
    let isEnabled: Bool
    let resetLocalState: Bool
    let disableAnimations: Bool
    let baseURLOverride: String?
    let seedScenario: TrixUITestSeedScenario?
    let conversationScenario: TrixUITestConversationScenario?
    let scenarioLabel: String?
    /// Inline UTF-8 JSON for `TrixInteropAction` (used by UI tests; avoids `simctl` file staging).
    let interopActionJSON: String?
    /// Filename within the app `Documents` directory; optional host-staged action JSON.
    let interopActionInputFileName: String?
    /// Filename within the app `Documents` directory; optional file sink for interop JSON results.
    let interopResultOutputFileName: String?
    /// `UIPasteboard.Name` raw value for UTF-8 JSON interop results (required for UI-test bundles).
    let interopResultPasteboardName: String?
    /// Decimal port string for framed TCP JSON delivery to `127.0.0.1` (UI-test driver).
    let interopResultTCPPort: String?

    /// Re-parsed on each read so XCTest `launchEnvironment` values are visible even if accessed after process start.
    static var current: UITestLaunchConfiguration {
        make(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func make(
        arguments: [String],
        environment: [String: String]
    ) -> UITestLaunchConfiguration {
        let isEnabled = arguments.contains(TrixUITestLaunchArgument.enableUITesting)
        guard isEnabled else {
            return UITestLaunchConfiguration(
                isEnabled: false,
                resetLocalState: false,
                disableAnimations: false,
                baseURLOverride: nil,
                seedScenario: nil,
                conversationScenario: nil,
                scenarioLabel: nil,
                interopActionJSON: nil,
                interopActionInputFileName: nil,
                interopResultOutputFileName: nil,
                interopResultPasteboardName: nil,
                interopResultTCPPort: nil
            )
        }

        return UITestLaunchConfiguration(
            isEnabled: true,
            resetLocalState: arguments.contains(TrixUITestLaunchArgument.resetState),
            disableAnimations: arguments.contains(TrixUITestLaunchArgument.disableAnimations),
            baseURLOverride: normalized(environment[TrixUITestLaunchEnvironment.baseURL]),
            seedScenario: normalized(environment[TrixUITestLaunchEnvironment.seedScenario])
                .flatMap(TrixUITestSeedScenario.init(rawValue:)),
            conversationScenario: normalized(environment[TrixUITestLaunchEnvironment.conversationScenario])
                .flatMap(TrixUITestConversationScenario.init(rawValue:)),
            scenarioLabel: normalized(environment[TrixUITestLaunchEnvironment.scenarioLabel]),
            interopActionJSON: normalized(environment[TrixInteropLaunchEnvironment.actionJSON]),
            interopActionInputFileName: normalized(environment[TrixInteropLaunchEnvironment.actionPath]),
            interopResultOutputFileName: normalized(environment[TrixInteropLaunchEnvironment.resultPath]),
            interopResultPasteboardName: normalized(environment[TrixInteropLaunchEnvironment.resultPasteboard]),
            interopResultTCPPort: normalized(environment[TrixInteropLaunchEnvironment.resultTCPPort])
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

@MainActor
enum UITestAppBootstrap {
    private static var didPrepare = false

    static func resetForTesting() {
        didPrepare = false
    }

    static func resetLocalStateForTesting() throws {
        didPrepare = false
        try resetLocalState()
    }

    static func prepareForLaunch(
        fallbackBaseURLString: String
    ) async throws -> String {
        try await prepareForLaunch(
            fallbackBaseURLString: fallbackBaseURLString,
            configuration: UITestLaunchConfiguration.current
        )
    }

    static func prepareForLaunch(
        fallbackBaseURLString: String,
        configuration: UITestLaunchConfiguration
    ) async throws -> String {
        let resolvedBaseURL = configuration.baseURLOverride ?? fallbackBaseURLString

        guard configuration.isEnabled else {
            return resolvedBaseURL
        }

        if configuration.resetLocalState, !didPrepare {
            try resetLocalState()
        }

        UserDefaults.standard.set(resolvedBaseURL, forKey: ServerConfiguration.baseURLDefaultsKey)

        if !didPrepare,
           configuration.seedScenario != nil || configuration.conversationScenario != nil {
            let seedLabel = configuration.scenarioLabel ?? "ios-ui-smoke"
            let seededState = try await UITestFixtureSeeder.seedLaunchState(
                seedScenario: configuration.seedScenario,
                conversationScenario: configuration.conversationScenario,
                baseURLString: resolvedBaseURL,
                scenarioLabel: seedLabel
            )
            try LocalDeviceIdentityStore().save(seededState.identity)
            if let fixtureManifest = seededState.fixtureManifest {
                try UITestFixtureManifestStore.save(fixtureManifest)
            } else {
                UITestFixtureManifestStore.clear()
            }
        } else if configuration.resetLocalState {
            UITestFixtureManifestStore.clear()
        }

        didPrepare = true

        TrixInteropActionBridge.performIfNeeded(configuration: configuration)

        return resolvedBaseURL
    }

    private static func resetLocalState() throws {
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        UserDefaults.standard.removeObject(forKey: ServerConfiguration.baseURLDefaultsKey)
        UITestFixtureManifestStore.clear()
        try? LocalDeviceIdentityStore().delete()
        SafeDiagnosticLogStore.shared.clear()

        let appSupportRoot = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let trixDirectory = appSupportRoot.appendingPathComponent("TrixiOS", isDirectory: true)
        try removeDirectoryIfPresent(
            trixDirectory.appendingPathComponent("CoreState", isDirectory: true)
        )
        try removeDirectoryIfPresent(
            trixDirectory.appendingPathComponent("SimulatorKeychainFallback", isDirectory: true)
        )
    }

    private static func removeDirectoryIfPresent(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }
}
