import Foundation
import Security

struct KeychainStore {
    private let service: String

    init(service: String = "dev.trix.ios") {
        self.service = service
    }

    func save(_ data: Data, account: String) throws {
        try delete(account: account)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if shouldUseSimulatorFallback(for: status) {
                try fallbackStore.save(data, account: account)
                return
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.invalidPayload
            }
            return data
        case errSecItemNotFound:
            return try fallbackStore.load(account: account)
        default:
            if shouldUseSimulatorFallback(for: status) {
                return try fallbackStore.load(account: account)
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            try? fallbackStore.delete(account: account)
            return
        }

        if shouldUseSimulatorFallback(for: status) {
            try fallbackStore.delete(account: account)
            return
        }

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private var fallbackStore: SimulatorFallbackStore {
        SimulatorFallbackStore(service: service)
    }

    private func shouldUseSimulatorFallback(for status: OSStatus) -> Bool {
        #if targetEnvironment(simulator)
        return status == errSecMissingEntitlement
        #else
        return false
        #endif
    }
}

enum KeychainStoreError: LocalizedError {
    case invalidPayload
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Keychain returned an unexpected payload."
        case let .unexpectedStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            }
            return "Keychain error (\(status))."
        }
    }
}

private struct SimulatorFallbackStore {
    let service: String

    func save(_ data: Data, account: String) throws {
        let url = try fileURL(account: account)
        try createParentDirectory(for: url)
        try data.write(to: url, options: .atomic)
    }

    func load(account: String) throws -> Data? {
        let url = try fileURL(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func delete(account: String) throws {
        let url = try fileURL(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(account: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("TrixiOS", isDirectory: true)
            .appendingPathComponent("SimulatorKeychainFallback", isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
            .appendingPathComponent(account)
            .appendingPathExtension("bin")
    }

    private func createParentDirectory(for fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }
}
