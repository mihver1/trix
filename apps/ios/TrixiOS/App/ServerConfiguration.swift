import Foundation

enum ServerConfiguration {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!
    static let baseURLDefaultsKey = "server.baseURL"
}
