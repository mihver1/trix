import Foundation

enum MatrixClientConfiguration {
    static let homeserverURL = URL(string: "https://trix.selfhost.ru")!
    static let serverName = "trix.selfhost.ru"
}

enum XMPPClientConfiguration {
    static let serverName = "trix.selfhost.ru"
    static let connectionURL = URL(string: "xmpp://trix.selfhost.ru")!
    static let conferenceServerName = "conference.trix.selfhost.ru"
    static let directoryServerName = "vjud.trix.selfhost.ru"
    static let defaultResourcePrefix = "trix-apple"
}
