import Foundation

enum TrixUITestLaunchArgument {
    static let enableUITesting = "-trix-ui-testing"
    static let resetState = "-trix-ui-reset-state"
    static let disableAnimations = "-trix-ui-disable-animations"
}

enum TrixUITestLaunchEnvironment {
    static let baseURL = "TRIX_UI_TEST_BASE_URL"
    static let seedScenario = "TRIX_UI_TEST_SEED_SCENARIO"
    static let conversationScenario = "TRIX_UI_TEST_CONVERSATION_SCENARIO"
    static let scenarioLabel = "TRIX_UI_TEST_SCENARIO_LABEL"
}

enum TrixUITestSeedScenario: String, Codable {
    case approvedAccount = "approved-account"
    case pendingApproval = "pending-approval"
}

enum TrixUITestConversationScenario: String, Codable {
    case dmAndGroup = "dm-and-group"
}

enum UITestFixtureChatKind: String, Codable, CaseIterable {
    case dm
    case group
}

enum UITestFixtureMessageKind: String, Codable, CaseIterable {
    case dmSeed
    case groupSeed
}

enum TrixAccessibilityID {
    enum Root {
        static let onboardingScreen = "root.onboarding.screen"
        static let pendingApprovalScreen = "root.pending-approval.screen"
        static let dashboardScreen = "root.dashboard.screen"
    }

    enum Onboarding {
        static let createModeButton = "onboarding.mode.create"
        static let linkModeButton = "onboarding.mode.link"
        static let profileNameField = "onboarding.field.profile-name"
        static let handleField = "onboarding.field.handle"
        static let bioField = "onboarding.field.bio"
        static let deviceNameField = "onboarding.field.device-name"
        static let linkCodeField = "onboarding.field.link-code"
        static let serverDetailsToggle = "onboarding.server.toggle-details"
        static let serverURLField = "onboarding.server.url"
        static let testConnectionButton = "onboarding.server.test-connection"
        static let primaryActionButton = "onboarding.primary-action"
        static let errorBanner = "onboarding.error-banner"
    }

    enum PendingApproval {
        static let checkApprovalButton = "pending-approval.check-approval"
        static let forgetDeviceButton = "pending-approval.forget-device"
        static let technicalDetailsToggle = "pending-approval.toggle-details"
        static let deviceCard = "pending-approval.device-card"
    }

    enum Dashboard {
        static let chatsTab = "dashboard.tab.chats"
        static let settingsTab = "dashboard.tab.settings"
        static let chatsList = "dashboard.chats.list"
        static let settingsList = "dashboard.settings.list"
        static let composeButton = "dashboard.compose"
        static let createChatSheet = "dashboard.create-chat.sheet"
        static let createChatCancelButton = "dashboard.create-chat.cancel"

        static func chatRow(_ kind: UITestFixtureChatKind) -> String {
            "dashboard.chats.row.\(kind.rawValue)"
        }
    }

    enum ChatDetail {
        static let screen = "chat-detail.screen"
        static let timeline = "chat-detail.timeline"
        static let messageBodyField = "chat-detail.message.body"
        static let sendButton = "chat-detail.message.send"
        static let latestSentMessage = "chat-detail.message.latest-sent"
        static let successBanner = "chat-detail.banner.success"
        static let errorBanner = "chat-detail.banner.error"

        static func message(_ kind: UITestFixtureMessageKind) -> String {
            "chat-detail.message.\(kind.rawValue)"
        }
    }

    enum SystemStatus {
        static let serverURLField = "system-status.server.url"
        static let reloadButton = "system-status.reload"
    }
}
