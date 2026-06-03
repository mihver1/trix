import Foundation

enum TrixClientConfiguration {
    private static let defaultHomeserverURL = URL(string: "https://trix.selfhost.ru")!
    private static let defaultRegistrationAPIBaseURL = URL(string: "https://trix.selfhost.ru")!
    private static let defaultCallControlAPIBaseURL = URL(string: "https://trix.selfhost.ru")!
    private static let defaultDevicePassportAPIBaseURL = URL(string: "https://trix.selfhost.ru")!

    static var homeserverURL: URL {
        homeserverURL(environment: ProcessInfo.processInfo.environment)
    }

    static var registrationAPIBaseURL: URL {
        registrationAPIBaseURL(environment: ProcessInfo.processInfo.environment)
    }

    static var callControlAPIBaseURL: URL {
        callControlAPIBaseURL(environment: ProcessInfo.processInfo.environment)
    }

    static var devicePassportAPIBaseURL: URL {
        devicePassportAPIBaseURL(environment: ProcessInfo.processInfo.environment)
    }

    static let serverName = "trix.selfhost.ru"

    static func homeserverURL(environment: [String: String]) -> URL {
        TrixEnvironmentConfiguration.url(
            environmentKey: "TRIX_HOMESERVER_URL",
            fallback: defaultHomeserverURL,
            environment: environment
        )
    }

    static func registrationAPIBaseURL(environment: [String: String]) -> URL {
        TrixEnvironmentConfiguration.url(
            environmentKey: "TRIX_REGISTRATION_BASE_URL",
            fallback: defaultRegistrationAPIBaseURL,
            environment: environment
        )
    }

    static func callControlAPIBaseURL(environment: [String: String]) -> URL {
        if let infoDictionaryValue = Bundle.main.object(forInfoDictionaryKey: "TrixCallControlBaseURL") as? String {
            let url = TrixEnvironmentConfiguration.url(
                environmentKey: "TRIX_CALL_CONTROL_BASE_URL",
                fallback: defaultCallControlAPIBaseURL,
                environment: ["TRIX_CALL_CONTROL_BASE_URL": infoDictionaryValue]
            )
            if url != defaultCallControlAPIBaseURL {
                return url
            }
        }

        return TrixEnvironmentConfiguration.url(
            environmentKey: "TRIX_CALL_CONTROL_BASE_URL",
            fallback: defaultCallControlAPIBaseURL,
            environment: environment
        )
    }

    static func devicePassportAPIBaseURL(environment: [String: String]) -> URL {
        TrixEnvironmentConfiguration.url(
            environmentKey: "TRIX_DEVICE_PASSPORT_BASE_URL",
            fallback: defaultDevicePassportAPIBaseURL,
            environment: environment
        )
    }
}

enum XMPPClientConfiguration {
    static let serverName = "trix.selfhost.ru"
    private static let defaultConnectionURL = URL(string: "xmpp://trix.selfhost.ru")!
    static var connectionURL: URL {
        TrixEnvironmentConfiguration.url(
            environmentKey: "TRIX_XMPP_URL",
            fallback: defaultConnectionURL
        )
    }
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
