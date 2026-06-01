import Foundation
import SwiftUI

@MainActor
final class TrixAdminAppModel: ObservableObject {
    @Published var serverURLString: String {
        didSet {
            UserDefaults.standard.set(serverURLString, forKey: Self.serverURLDefaultsKey)
        }
    }

    @Published var token: String
    @Published var selectedSection: TrixAdminSection? = .dashboard
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastResult: String?

    @Published var session: TrixAdminSession?
    @Published var opsStatus: TrixAdminOpsStatus?
    @Published var metrics: TrixAdminMetricsSummary?
    @Published var media: TrixAdminMediaStorage?
    @Published var users: [TrixAdminUser] = []
    @Published var featureFlags: [TrixFeatureFlag] = []
    @Published var recentLogs = TrixAdminRecentLogs(service: "trix-admin-api", status: "unavailable", lines: [])
    @Published var recentAudit = TrixAdminRecentAudit(status: "empty", events: [])

    @Published var userQuery = ""
    @Published var newUserLocalpart = ""
    @Published var userPassword = ""
    @Published var disableReason = "disabled by Trix operator"
    @Published var selectedUser: TrixAdminUser?

    @Published var wakeTokenHex = ""
    @Published var wakeEnvironment = "sandbox"
    @Published var wakeAccount = ""
    @Published var wakeRoom = ""
    @Published var wakeBadge = "1"
    @Published var voipAccount = ""
    @Published var voipCallID = ""

    @Published var logsService = "trix-admin-api"
    @Published var logsLimit = 200.0

    @Published var newFlagKey = ""

    private let credentials = TrixAdminCredentialStore()
    private static let serverURLDefaultsKey = "trix.admin.serverURL"

    init() {
        self.token = credentials.loadToken()
        self.serverURLString = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey)
            ?? "http://127.0.0.1:8093"
    }

    var currentSection: TrixAdminSection {
        selectedSection ?? .dashboard
    }

    var client: TrixAdminAPIClient? {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TrixAdminAPIClient(baseURL: url, bearerToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func connect() async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            credentials.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            session = try await client.sessionInfo()
            isConnected = true
            let refreshFailures = await refreshAllBestEffort(using: client)
            if refreshFailures.isEmpty {
                lastResult = "connected"
            } else {
                lastResult = "connected; partial refresh failed: \(refreshFailures.joined(separator: ", "))"
            }
        }
    }

    func disconnect() {
        isConnected = false
        session = nil
        opsStatus = nil
        metrics = nil
        media = nil
        users = []
        featureFlags = []
        recentLogs = TrixAdminRecentLogs(service: logsService, status: "unavailable", lines: [])
        recentAudit = TrixAdminRecentAudit(status: "empty", events: [])
        credentials.deleteToken()
    }

    func refreshSelected() async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            switch currentSection {
            case .dashboard:
                try await refreshDashboard(using: client)
            case .users:
                users = try await client.searchUsers(query: userQuery)
            case .pushes:
                try await refreshDashboard(using: client)
            case .media:
                media = try await client.mediaStorage()
            case .flags:
                try await refreshFeatureFlags(using: client)
            case .logs:
                recentLogs = try await client.recentLogs(service: logsService, limit: Int(logsLimit))
                recentAudit = try await client.recentAudit(limit: Int(logsLimit))
            }
            lastResult = "refreshed"
        }
    }

    func provisionUser() async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            let response = try await client.provisionUser(localpart: newUserLocalpart, password: userPassword)
            lastResult = "created \(response.jid)"
            userPassword = ""
            users = try await client.searchUsers(query: userQuery)
        }
    }

    func resetSelectedUserPassword() async {
        await run {
            guard let client, let selectedUser else {
                throw TrixAdminModelError.noUserSelected
            }
            let response = try await client.resetPassword(localpart: selectedUser.localpart, password: userPassword)
            lastResult = "password reset for \(response.jid)"
            userPassword = ""
        }
    }

    func disableSelectedUser() async {
        await run {
            guard let client, let selectedUser else {
                throw TrixAdminModelError.noUserSelected
            }
            let response = try await client.disableUser(localpart: selectedUser.localpart, reason: disableReason)
            lastResult = "disabled \(response.jid)"
            users = try await client.searchUsers(query: userQuery)
        }
    }

    func enableSelectedUser() async {
        await run {
            guard let client, let selectedUser else {
                throw TrixAdminModelError.noUserSelected
            }
            let response = try await client.enableUser(localpart: selectedUser.localpart)
            lastResult = "enabled \(response.jid)"
            users = try await client.searchUsers(query: userQuery)
        }
    }

    func sendWakePush() async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            let response = try await client.sendWakePush(
                TrixAdminWakePushRequest(
                    tokenHex: wakeTokenHex,
                    environment: wakeEnvironment,
                    account: nilIfEmpty(wakeAccount),
                    room: nilIfEmpty(wakeRoom),
                    badge: UInt32(wakeBadge)
                )
            )
            lastResult = response.values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        }
    }

    func sendVoIPPush() async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            let response = try await client.sendVoIPPush(
                TrixAdminVoIPPushRequest(account: voipAccount, callID: voipCallID)
            )
            lastResult = response.values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        }
    }

    func saveFeatureFlag(_ flag: TrixFeatureFlag) async {
        await run {
            guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            let client = TrixFeatureFlagHTTPClient(baseURL: url, bearerToken: token)
            let snapshot = try await client.saveAdminFlag(flag)
            featureFlags = snapshot.flags
            lastResult = "saved \(flag.key)"
        }
    }

    func createFeatureFlag() async {
        let key = newFlagKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else {
            errorMessage = "Feature flag key is required."
            return
        }
        await saveFeatureFlag(
            TrixFeatureFlag(
                key: key,
                enabled: false,
                rolloutPercentage: 0,
                clientVisible: false,
                description: "",
                updatedAtUnix: 0
            )
        )
        newFlagKey = ""
    }

    func deleteFeatureFlag(_ key: String) async {
        await run {
            guard let client else {
                throw TrixAdminModelError.missingConnectionSettings
            }
            let snapshot = try await client.deleteFeatureFlag(key: key)
            featureFlags = snapshot.flags
            lastResult = "deleted \(key)"
        }
    }

    private func refreshAll(using client: TrixAdminAPIClient) async throws {
        try await refreshDashboard(using: client)
        users = try await client.searchUsers(query: userQuery)
        media = try await client.mediaStorage()
        try await refreshFeatureFlags(using: client)
        recentLogs = try await client.recentLogs(service: logsService, limit: Int(logsLimit))
        recentAudit = try await client.recentAudit(limit: Int(logsLimit))
    }

    private func refreshAllBestEffort(using client: TrixAdminAPIClient) async -> [String] {
        var failures: [String] = []

        do {
            try await refreshDashboard(using: client)
        } catch {
            failures.append("dashboard")
        }

        do {
            users = try await client.searchUsers(query: userQuery)
        } catch {
            failures.append("users")
        }

        do {
            media = try await client.mediaStorage()
        } catch {
            failures.append("media")
        }

        do {
            try await refreshFeatureFlags(using: client)
        } catch {
            failures.append("feature flags")
        }

        do {
            recentLogs = try await client.recentLogs(service: logsService, limit: Int(logsLimit))
        } catch {
            failures.append("logs")
        }

        do {
            recentAudit = try await client.recentAudit(limit: Int(logsLimit))
        } catch {
            failures.append("audit")
        }

        return failures
    }

    private func refreshDashboard(using client: TrixAdminAPIClient) async throws {
        opsStatus = try await client.opsStatus()
        metrics = try await client.metricsSummary()
    }

    private func refreshFeatureFlags(using client: TrixAdminAPIClient) async throws {
        let flagClient = TrixFeatureFlagHTTPClient(baseURL: client.baseURL, bearerToken: client.bearerToken)
        featureFlags = try await flagClient.fetchAdminSnapshot().flags
    }

    private func run(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TrixAdminSection: String, CaseIterable, Identifiable {
    case dashboard
    case users
    case pushes
    case media
    case flags
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "Dashboard"
        case .users:
            "Users"
        case .pushes:
            "Pushes"
        case .media:
            "Media"
        case .flags:
            "Feature Flags"
        case .logs:
            "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.bottom.50percent"
        case .users:
            "person.2"
        case .pushes:
            "bell.badge"
        case .media:
            "internaldrive"
        case .flags:
            "flag"
        case .logs:
            "doc.text.magnifyingglass"
        }
    }
}

enum TrixAdminModelError: LocalizedError {
    case missingConnectionSettings
    case noUserSelected

    var errorDescription: String? {
        switch self {
        case .missingConnectionSettings:
            "Server URL and admin token are required."
        case .noUserSelected:
            "Select a user first."
        }
    }
}
