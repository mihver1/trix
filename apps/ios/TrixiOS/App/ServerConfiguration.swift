import Foundation

enum ServerConfiguration {
    static let defaultBaseURL: URL = {
        let override = ProcessInfo.processInfo.environment[TrixUITestLaunchEnvironment.baseURL]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (override?.isEmpty == false ? override : nil) ?? "https://trix.artelproject.tech"
        return URL(string: baseURL) ?? URL(string: "https://trix.artelproject.tech")!
    }()
    static let baseURLDefaultsKey = "server.baseURL"
}
