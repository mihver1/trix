import Foundation
import Security

/// Keychain `kSecAttrAccount` prefixes for app-owned workspace encryption keys (see `WorkspaceDatabaseKeyStore` / `MessengerWorkspaceDatabaseKeyStore`).
enum MacUITestWorkspaceKeychainAccountPrefixes {
    static let workspaceCoreStoreKeyV1 = "workspace-core-store-key-v1:"

    static var all: [String] { [workspaceCoreStoreKeyV1] }

    /// Used by unit tests to validate prefix rules without touching the keychain.
    static func accountLabelsMatchingRemovalPrefixes(_ accounts: [String]) -> [String] {
        accounts.filter { account in all.contains { account.hasPrefix($0) } }
    }
}

@MainActor
struct MacUITestAppBootstrap {
    private let clearSession: () throws -> Void
    private let removeVaultKeys: () throws -> Void
    private let removeWorkspacesRoot: () throws -> Void
    private let clearFixtureManifest: () -> Void

    init(
        clearSession: @escaping () throws -> Void,
        removeVaultKeys: @escaping () throws -> Void,
        removeWorkspacesRoot: @escaping () throws -> Void,
        clearFixtureManifest: @escaping () -> Void = { MacUITestFixtureManifestStore.clear() }
    ) {
        self.clearSession = clearSession
        self.removeVaultKeys = removeVaultKeys
        self.removeWorkspacesRoot = removeWorkspacesRoot
        self.clearFixtureManifest = clearFixtureManifest
    }

    /// Production bootstrap using real `SessionStore`, keychain, app workspace tree, and standard fixture manifest defaults.
    static func production(fileManager: FileManager = .default) -> MacUITestAppBootstrap {
        let sessionStore = SessionStore()
        let keychainStore = KeychainStore()
        return MacUITestAppBootstrap(
            clearSession: { try sessionStore.clear() },
            removeVaultKeys: {
                for key in VaultKey.allCases {
                    try keychainStore.removeValue(for: key)
                }
                try keychainStore.removeGenericPasswords(withAccountPrefixes: MacUITestWorkspaceKeychainAccountPrefixes.all)
            },
            removeWorkspacesRoot: {
                let appSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let root = workspacesRootURL(
                    applicationSupportDirectory: appSupport,
                    appDirectoryName: AppIdentity.applicationSupportDirectoryName
                )
                try removeWorkspacesDirectoryIfPresent(at: root, fileManager: fileManager)
            },
            clearFixtureManifest: { MacUITestFixtureManifestStore.clear() }
        )
    }

    func resetLocalState() throws {
        try clearSession()
        try removeVaultKeysToleratingInvalidOwnerEdit()
        try removeWorkspacesRoot()
        clearFixtureManifest()
    }

    func prepareForLaunch(configuration: MacUITestLaunchConfiguration) async throws -> String? {
        guard configuration.isEnabled else {
            return nil
        }
        if configuration.resetLocalState {
            try await resetLocalStateWithYieldsForUITestLaunch()
        }

        if configuration.seedScenario == nil && configuration.conversationScenario == nil {
            MacUITestFixtureManifestStore.clear()
            TrixMacInteropActionBridge.performIfNeeded(configuration: configuration)
            return configuration.baseURLOverride
        }

        guard let baseURLString = configuration.baseURLOverride else {
            throw MacUITestFixtureSeederError.missingBaseURL
        }

        let label = configuration.scenarioLabel ?? "default"
        let sessionStore = SessionStore()
        let keychainStore = KeychainStore()

        if let conversation = configuration.conversationScenario {
            let accountSeed = configuration.seedScenario ?? .approvedAccount
            let manifest = try await MacUITestFixtureSeeder.seedConversationBundle(
                accountSeed: accountSeed,
                conversation: conversation,
                baseURLString: baseURLString,
                scenarioLabel: label,
                sessionStore: sessionStore,
                keychainStore: keychainStore
            )
            try MacUITestFixtureManifestStore.save(manifest)
        } else if let seed = configuration.seedScenario {
            try await MacUITestFixtureSeeder.seedAccountState(
                seed,
                baseURLString: baseURLString,
                scenarioLabel: label,
                sessionStore: sessionStore,
                keychainStore: keychainStore
            )
            MacUITestFixtureManifestStore.clear()
        }

        TrixMacInteropActionBridge.performIfNeeded(configuration: configuration)
        return configuration.baseURLOverride
    }

    nonisolated static func workspacesRootURL(
        applicationSupportDirectory: URL,
        appDirectoryName: String
    ) -> URL {
        applicationSupportDirectory
            .appending(path: appDirectoryName)
            .appending(path: "workspaces")
    }

    nonisolated static func removeWorkspacesDirectoryIfPresent(at url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    /// UI-test launch runs inside SwiftUI `.task` on the main actor. Running the full reset back-to-back without a
    /// suspension point can starve the run loop long enough that macOS XCUITest never completes the accessibility
    /// handshake. Security.framework keychain work must stay on the main thread (off-main reset risks a main-queue
    /// deadlock while the UI task awaits). Yield between steps so the main actor can service AX while preserving
    /// sequential semantics before seeding or interop actions.
    private func resetLocalStateWithYieldsForUITestLaunch() async throws {
        try clearSession()
        await Task.yield()
        try removeVaultKeysToleratingInvalidOwnerEdit()
        await Task.yield()
        try removeWorkspacesRoot()
        await Task.yield()
        clearFixtureManifest()
    }

    private func removeVaultKeysToleratingInvalidOwnerEdit() throws {
        do {
            try removeVaultKeys()
        } catch let KeychainStoreError.unhandledStatus(status) where status == errSecInvalidOwnerEdit {
            // Xcode/macOS test builds can hit stale file-based keychain ACL ownership after re-signing.
            // Later saves use SecItemUpdate, which still works for these test-owned entries.
            return
        }
    }
}
