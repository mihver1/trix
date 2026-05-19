import Foundation

enum TrixEnvironmentConfiguration {
    static func url(
        environmentKey: String,
        fallback: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme != nil else {
            return fallback
        }

        return url
    }
}

struct TrixLocalProfileConfiguration: Equatable, Sendable {
    static let environmentKey = "TRIX_LOCAL_PROFILE"

    let name: String

    init?(rawName: String?) {
        guard let rawName else {
            return nil
        }

        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return nil
        }

        let sanitizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            if Self.isAllowedProfileScalar(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(sanitizedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard !collapsed.isEmpty else {
            return nil
        }

        self.name = String(collapsed.prefix(48))
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionaryProfile: String? = Bundle.main.object(forInfoDictionaryKey: "TrixLocalProfile") as? String
    ) -> TrixLocalProfileConfiguration? {
        if let profile = TrixLocalProfileConfiguration(rawName: environment[environmentKey]) {
            return profile
        }

        if let profile = TrixLocalProfileConfiguration(rawName: infoDictionaryProfile) {
            return profile
        }

        let prefix = "com.softgrid.trixapp.local."
        if let bundleIdentifier,
           bundleIdentifier.hasPrefix(prefix) {
            return TrixLocalProfileConfiguration(rawName: String(bundleIdentifier.dropFirst(prefix.count)))
        }

        return nil
    }

    func keychainService(_ base: String) -> String {
        "\(base).local.\(name)"
    }

    func directoryName(_ base: String) -> String {
        "\(base)-Local-\(name)"
    }

    func userDefaultsSuiteName(_ base: String) -> String {
        "\(base).local.\(name)"
    }

    func userDefaults(suiteName base: String) -> UserDefaults {
        UserDefaults(suiteName: userDefaultsSuiteName(base)) ?? .standard
    }

    private static func isAllowedProfileScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        case 45, 95:
            return true
        default:
            return false
        }
    }
}
