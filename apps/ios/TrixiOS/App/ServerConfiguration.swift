import Foundation

enum ServerConfiguration {
    static let defaultBaseURL: URL = {
        let override = ProcessInfo.processInfo.environment[TrixUITestLaunchEnvironment.baseURL]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (override?.isEmpty == false ? override : nil) ?? "http://127.0.0.1:8080"
        return URL(string: baseURL) ?? URL(string: "http://127.0.0.1:8080")!
    }()
    static let baseURLDefaultsKey = "server.baseURL"
}
