import Foundation

enum TrixClientConfiguration {
    static let homeserverURL = URL(string: "https://trix.selfhost.ru")!
    static let registrationAPIBaseURL = URL(string: "https://trix.selfhost.ru")!
    static let callControlAPIBaseURL = URL(string: "https://trix.selfhost.ru")!
    static let serverName = "trix.selfhost.ru"
}

enum XMPPClientConfiguration {
    static let serverName = "trix.selfhost.ru"
    static let connectionURL = URL(string: "xmpp://trix.selfhost.ru")!
    static let conferenceServerName = "conference.trix.selfhost.ru"
    static let directoryServerName = "vjud.trix.selfhost.ru"
    static let defaultResourcePrefix = "trix-apple"
}

enum XMPPPushConfiguration {
    static let apnsSandboxProvider = "apns-sandbox"
    static let apnsProductionProvider = "apns-production"
    static let apnsVoIPSandboxProvider = "apns-voip-sandbox"
    static let apnsVoIPProductionProvider = "apns-voip-production"
    static let payloadContract = "com.softgrid.trix.apns.sync.v2"
    static let voipPayloadContract = "com.softgrid.trix.apns.voip-call.v1"
}
