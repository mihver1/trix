import XCTest

enum TrixMacUITestApp {
    private static let runnerBaseURLEnvironmentKey = MacUITestLaunchEnvironment.baseURL

    static func configuredBaseURL() -> String {
        let candidate = ProcessInfo.processInfo.environment[runnerBaseURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate?.isEmpty == false ? candidate! : "http://127.0.0.1:8080"
    }

    static func skipUnlessServerReachable() async throws {
        let baseURL = configuredBaseURL()
        let healthURL = try XCTUnwrap(URL(string: "\(baseURL)/v0/system/health"))

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw XCTSkip(
                    "macOS UI smoke skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "macOS UI smoke skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    static func launch(
        resetState: Bool = true,
        seedScenario: MacUITestSeedScenario? = nil,
        conversationScenario: MacUITestConversationScenario? = nil,
        scenarioLabel: String? = nil,
        baseURLOverride: String? = nil,
        interopActionJSON: String? = nil,
        interopActionInputFileName: String? = nil,
        interopResultOutputFileName: String? = nil,
        interopResultPasteboardName: String? = nil,
        interopResultTCPPort: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = [MacUITestLaunchArgument.enableUITesting]
        if resetState {
            launchArguments.append(MacUITestLaunchArgument.resetState)
        }
        app.launchArguments = launchArguments
        let base = baseURLOverride ?? configuredBaseURL()
        app.launchEnvironment[MacUITestLaunchEnvironment.baseURL] = base
        if let seedScenario {
            app.launchEnvironment[MacUITestLaunchEnvironment.seedScenario] = seedScenario.rawValue
        }
        if let conversationScenario {
            app.launchEnvironment[MacUITestLaunchEnvironment.conversationScenario] = conversationScenario.rawValue
        }
        if let scenarioLabel {
            app.launchEnvironment[MacUITestLaunchEnvironment.scenarioLabel] = scenarioLabel
        }
        if let interopActionJSON {
            app.launchEnvironment[TrixMacInteropLaunchEnvironment.actionJSON] = interopActionJSON
        }
        if let interopActionInputFileName {
            app.launchEnvironment[TrixMacInteropLaunchEnvironment.actionPath] = interopActionInputFileName
        }
        if let interopResultOutputFileName {
            app.launchEnvironment[TrixMacInteropLaunchEnvironment.resultPath] = interopResultOutputFileName
        }
        if let interopResultPasteboardName {
            app.launchEnvironment[TrixMacInteropLaunchEnvironment.resultPasteboard] = interopResultPasteboardName
        }
        if let interopResultTCPPort {
            app.launchEnvironment[TrixMacInteropLaunchEnvironment.resultTCPPort] = interopResultTCPPort
        }
        app.launch()
        return app
    }
}
