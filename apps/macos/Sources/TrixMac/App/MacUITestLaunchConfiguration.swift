import Foundation

struct MacUITestLaunchConfiguration: Equatable {
    let isEnabled: Bool
    let resetLocalState: Bool
    let baseURLOverride: String?
    let seedScenario: MacUITestSeedScenario?
    let conversationScenario: MacUITestConversationScenario?
    let scenarioLabel: String?
    let interopActionJSON: String?
    let interopActionInputFileName: String?
    let interopResultOutputFileName: String?
    let interopResultPasteboardName: String?
    let interopResultTCPPort: String?

    static let current = make(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    static func make(
        arguments: [String],
        environment: [String: String]
    ) -> MacUITestLaunchConfiguration {
        let isEnabled = arguments.contains(MacUITestLaunchArgument.enableUITesting)
        guard isEnabled else {
            return MacUITestLaunchConfiguration(
                isEnabled: false,
                resetLocalState: false,
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

        return MacUITestLaunchConfiguration(
            isEnabled: true,
            resetLocalState: arguments.contains(MacUITestLaunchArgument.resetState),
            baseURLOverride: normalized(environment[MacUITestLaunchEnvironment.baseURL]),
            seedScenario: normalized(environment[MacUITestLaunchEnvironment.seedScenario])
                .flatMap(MacUITestSeedScenario.init(rawValue:)),
            conversationScenario: normalized(environment[MacUITestLaunchEnvironment.conversationScenario])
                .flatMap(MacUITestConversationScenario.init(rawValue:)),
            scenarioLabel: normalized(environment[MacUITestLaunchEnvironment.scenarioLabel]),
            interopActionJSON: normalized(environment[TrixMacInteropLaunchEnvironment.actionJSON]),
            interopActionInputFileName: normalized(environment[TrixMacInteropLaunchEnvironment.actionPath]),
            interopResultOutputFileName: normalized(environment[TrixMacInteropLaunchEnvironment.resultPath]),
            interopResultPasteboardName: normalized(environment[TrixMacInteropLaunchEnvironment.resultPasteboard]),
            interopResultTCPPort: normalized(environment[TrixMacInteropLaunchEnvironment.resultTCPPort])
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
