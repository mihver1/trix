import Foundation

enum MacUITestLaunchArgument {
    static let enableUITesting = "-trix-ui-testing"
    static let resetState = "-trix-ui-reset-state"
}

enum MacUITestLaunchEnvironment {
    static let baseURL = "TRIX_MACOS_UI_TEST_BASE_URL"
    static let seedScenario = "TRIX_MACOS_UI_TEST_SEED_SCENARIO"
    static let conversationScenario = "TRIX_MACOS_UI_TEST_CONVERSATION_SCENARIO"
    static let scenarioLabel = "TRIX_MACOS_UI_TEST_SCENARIO_LABEL"
}

enum MacUITestSeedScenario: String, Codable, Equatable {
    case approvedAccount = "approved-account"
    case pendingApproval = "pending-approval"
    case restoreSession = "restore-session"
}

enum MacUITestConversationScenario: String, Codable, Equatable {
    case dmAndGroup = "dm-and-group"
}

/// Shared accessibility identifiers for the macOS app and UI tests.
enum TrixMacAccessibilityID {
    enum Root {
        static let onboardingScreen = "mac.root.onboarding.screen"
        static let pendingApprovalScreen = "mac.root.pending-approval.screen"
        static let restoreSessionScreen = "mac.root.restore-session.screen"
        static let workspaceScreen = "mac.root.workspace.screen"
    }

    enum Onboarding {
        static let createModeButton = "mac.onboarding.mode.create"
        static let linkModeButton = "mac.onboarding.mode.link"
        static let profileNameField = "mac.onboarding.field.profile-name"
        static let handleField = "mac.onboarding.field.handle"
        static let bioField = "mac.onboarding.field.bio"
        static let deviceNameField = "mac.onboarding.field.device-name"
        static let linkDeviceNameField = "mac.onboarding.field.link-device-name"
        static let linkCodeField = "mac.onboarding.field.link-code"
        static let serverURLField = "mac.onboarding.server.url"
        static let testConnectionButton = "mac.onboarding.server.test-connection"
        static let primaryActionButton = "mac.onboarding.primary-action"
        static let registerPendingDeviceButton = "mac.onboarding.register-pending-device"
        static let pendingDeviceIDValue = "mac.onboarding.pending-device-id"
        static let reconnectAfterApprovalButton = "mac.onboarding.reconnect-after-approval"
        static let restartLinkButton = "mac.onboarding.restart-link"
    }

    enum Restore {
        static let reconnectButton = "mac.restore.reconnect"
    }
}

// MARK: - Fixture manifest (conversation seeding)

enum MacUITestFixtureChatKind: String, Codable, CaseIterable {
    case dm
    case group
}

enum MacUITestFixtureMessageKind: String, Codable, CaseIterable {
    case dmSeed
    case groupSeed
}

struct MacUITestFixtureChatRecord: Codable, Equatable {
    let kind: MacUITestFixtureChatKind
    let chatId: String
    let title: String
}

struct MacUITestFixtureMessageRecord: Codable, Equatable {
    let kind: MacUITestFixtureMessageKind
    let chatKind: MacUITestFixtureChatKind
    let chatId: String
    let messageId: String
    let text: String
}

struct MacUITestFixtureManifest: Codable, Equatable {
    let conversationScenario: MacUITestConversationScenario
    let chats: [MacUITestFixtureChatRecord]
    let messages: [MacUITestFixtureMessageRecord]
}

enum MacUITestFixtureManifestStore {
    private static let defaultsKey = "ui-test.fixture-manifest"

    static func load() -> MacUITestFixtureManifest? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(MacUITestFixtureManifest.self, from: data)
    }

    static func save(_ manifest: MacUITestFixtureManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
