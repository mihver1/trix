import Foundation

enum TrixUserIdentity {
    static func normalizedXMPPUserID(
        _ value: String,
        serverName: String = XMPPClientConfiguration.serverName
    ) throws -> String {
        let localpart = try normalizedLocalpart(value, serverName: serverName)
        return "\(localpart)@\(serverName)"
    }

    static func normalizedMatrixUserID(
        _ value: String,
        serverName: String = XMPPClientConfiguration.serverName
    ) throws -> String {
        let localpart = try normalizedLocalpart(value, serverName: serverName)
        return "@\(localpart):\(serverName)"
    }

    static func handle(
        from value: String,
        serverName: String = XMPPClientConfiguration.serverName
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        if let localpart = localpartFromMatrixID(trimmed, serverName: serverName) {
            return localpart
        }

        if let localpart = localpartFromXMPPJID(trimmed, serverName: serverName) {
            return localpart
        }

        return trimmed
    }

    static func displayName(
        from value: String,
        serverName: String = XMPPClientConfiguration.serverName
    ) -> String {
        let handle = handle(from: value, serverName: serverName)
        guard !handle.isEmpty else {
            return value
        }

        return handle.capitalized
    }

    private static func normalizedLocalpart(_ value: String, serverName: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TrixClientError.invalidTrixUserID
        }

        if let localpart = localpartFromMatrixID(trimmed, serverName: serverName) {
            return localpart
        }

        if let localpart = localpartFromXMPPJID(trimmed, serverName: serverName) {
            return localpart
        }

        guard isBareLocalpart(trimmed) else {
            throw TrixClientError.invalidTrixUserID
        }

        return trimmed
    }

    private static func localpartFromMatrixID(_ value: String, serverName: String) -> String? {
        guard value.hasPrefix("@"),
              let separator = value.firstIndex(of: ":") else {
            return nil
        }

        let localpart = String(value[value.index(after: value.startIndex)..<separator])
        let server = String(value[value.index(after: separator)...])
        guard !localpart.isEmpty,
              server.lowercased() == serverName.lowercased(),
              isBareLocalpart(localpart) else {
            return nil
        }

        return localpart
    }

    private static func localpartFromXMPPJID(_ value: String, serverName: String) -> String? {
        let bareJID = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let parts = bareJID.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first.map(String.init),
              let server = parts.last.map(String.init),
              !localpart.isEmpty,
              server.lowercased() == serverName.lowercased(),
              isBareLocalpart(localpart) else {
            return nil
        }

        return localpart
    }

    private static func isBareLocalpart(_ value: String) -> Bool {
        !value.isEmpty &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !value.contains("@") &&
            !value.contains(":") &&
            !value.contains("/")
    }
}
