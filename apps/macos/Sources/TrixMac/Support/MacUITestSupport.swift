import Foundation
import SwiftUI

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

    /// Workspace chrome used by UI automation (sidebar list, etc.).
    enum Workspace {
        static let chatList = "mac.workspace.chat-list"
    }

    /// Identifiers for rows that match a loaded `MacUITestFixtureManifest` (UI tests / interop).
    enum Fixture {
        static func chatRow(_ kind: MacUITestFixtureChatKind) -> String {
            "mac.fixture.chat-row.\(kind.rawValue)"
        }

        static func timelineMessage(_ kind: MacUITestFixtureMessageKind) -> String {
            "mac.fixture.timeline-message.\(kind.rawValue)"
        }
    }
}

// MARK: - Fixture-driven accessibility hints (main app UI)

enum MacUITestFixtureViewHints {
    /// Mirrors `MacUITestLaunchConfiguration` gating without referencing types that are not in the UI-test target’s build.
    private static var isUITestLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains(MacUITestLaunchArgument.enableUITesting)
    }

    private static var activeManifest: MacUITestFixtureManifest? {
        guard isUITestLaunch else {
            return nil
        }
        return MacUITestFixtureManifestStore.load()
    }

    /// - Parameter chatTypeRawValue: `ChatType.rawValue` from the main app (`dm`, `group`, `account_sync`).
    static func sidebarChatRowIdentifier(chatId: UUID, chatTypeRawValue: String) -> String? {
        guard let manifest = activeManifest, manifest.conversationScenario == .dmAndGroup else {
            return nil
        }
        guard let record = manifest.chats.first(where: { $0.chatId == chatId.uuidString }) else {
            return nil
        }
        guard record.kind.rawValue == chatTypeRawValue else {
            return nil
        }
        let sameKindCount = manifest.chats.filter { $0.kind == record.kind }.count
        guard sameKindCount == 1 else {
            return nil
        }
        return TrixMacAccessibilityID.Fixture.chatRow(record.kind)
    }

    static func timelineMessageIdentifier(messageId: UUID, selectedChatId: UUID?) -> String? {
        guard let selectedChatId else {
            return nil
        }
        guard let manifest = activeManifest, manifest.conversationScenario == .dmAndGroup else {
            return nil
        }
        guard let record = manifest.messages.first(where: { $0.messageId == messageId.uuidString && $0.chatId == selectedChatId.uuidString }) else {
            return nil
        }
        let sameKindInChat = manifest.messages.filter { $0.chatId == selectedChatId.uuidString && $0.kind == record.kind }
        guard sameKindInChat.count == 1 else {
            return nil
        }
        return TrixMacAccessibilityID.Fixture.timelineMessage(record.kind)
    }

}

struct OptionalAccessibilityIdentifierModifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

extension View {
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        modifier(OptionalAccessibilityIdentifierModifier(identifier: identifier))
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
