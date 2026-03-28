import XCTest

enum TrixUITestApp {
    private static let runnerBaseURLEnvironmentKey = "TRIX_IOS_UI_TEST_BASE_URL"
    private static let unitSmokeBaseURLEnvironmentKey = "TRIX_IOS_SERVER_SMOKE_BASE_URL"

    static func configuredBaseURL() -> String {
        let candidate = ProcessInfo.processInfo.environment[runnerBaseURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate?.isEmpty == false {
            return candidate!
        }

        let fallback = ProcessInfo.processInfo.environment[unitSmokeBaseURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback! : "http://localhost:8080"
    }

    static func skipUnlessServerReachable(baseURL: String? = nil) async throws {
        let resolvedBaseURL = baseURL ?? configuredBaseURL()
        let healthURL = try XCTUnwrap(URL(string: "\(resolvedBaseURL)/v0/system/health"))

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw XCTSkip(
                    "iOS UI smoke skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "iOS UI smoke skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    static func launch(
        resetState: Bool = true,
        seedScenario: TrixUITestSeedScenario? = nil,
        conversationScenario: TrixUITestConversationScenario? = nil,
        scenarioLabel: String? = nil,
        interfaceStyle: TrixUITestInterfaceStyle? = nil,
        baseURLOverride: String? = nil,
        interopActionJSON: String? = nil,
        interopActionInputFileName: String? = nil,
        interopResultOutputFileName: String? = nil,
        interopResultPasteboardName: String? = nil,
        interopResultTCPPort: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = [
            TrixUITestLaunchArgument.enableUITesting,
            TrixUITestLaunchArgument.disableAnimations,
        ]
        if resetState {
            launchArguments.append(TrixUITestLaunchArgument.resetState)
        }
        app.launchArguments = launchArguments
        app.launchEnvironment[TrixUITestLaunchEnvironment.baseURL] = baseURLOverride ?? configuredBaseURL()
        if let seedScenario {
            app.launchEnvironment[TrixUITestLaunchEnvironment.seedScenario] = seedScenario.rawValue
        }
        if let conversationScenario {
            app.launchEnvironment[TrixUITestLaunchEnvironment.conversationScenario] = conversationScenario.rawValue
        }
        if let scenarioLabel {
            app.launchEnvironment[TrixUITestLaunchEnvironment.scenarioLabel] = scenarioLabel
        }
        if let interfaceStyle {
            app.launchEnvironment[TrixUITestLaunchEnvironment.interfaceStyle] = interfaceStyle.rawValue
        }
        if let interopActionJSON {
            app.launchEnvironment[TrixInteropLaunchEnvironment.actionJSON] = interopActionJSON
        }
        if let interopActionInputFileName {
            app.launchEnvironment[TrixInteropLaunchEnvironment.actionPath] = interopActionInputFileName
        }
        if let interopResultOutputFileName {
            app.launchEnvironment[TrixInteropLaunchEnvironment.resultPath] = interopResultOutputFileName
        }
        if let interopResultPasteboardName {
            app.launchEnvironment[TrixInteropLaunchEnvironment.resultPasteboard] = interopResultPasteboardName
        }
        if let interopResultTCPPort {
            app.launchEnvironment[TrixInteropLaunchEnvironment.resultTCPPort] = interopResultTCPPort
        }
        app.launch()
        return app
    }
}
