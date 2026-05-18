import Foundation
import LocalAuthentication

enum TrixAppLockLifecyclePhase {
    case active
    case inactive
    case background
}

enum TrixAppLockIdleTimeout: String, CaseIterable, Codable, Identifiable, Sendable {
    case never
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    var id: String {
        rawValue
    }

    var duration: TimeInterval? {
        switch self {
        case .never:
            return nil
        case .oneMinute:
            return 60
        case .fiveMinutes:
            return 5 * 60
        case .fifteenMinutes:
            return 15 * 60
        }
    }

    var label: String {
        switch self {
        case .never:
            return "Never"
        case .oneMinute:
            return "1 minute"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        }
    }
}

struct TrixAppLockSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var locksOnBackground: Bool
    var idleTimeout: TrixAppLockIdleTimeout

    static let `default` = TrixAppLockSettings(
        isEnabled: false,
        locksOnBackground: true,
        idleTimeout: .never
    )
}

struct TrixAppLockAvailability: Equatable, Sendable {
    let canAuthenticate: Bool
    let authenticationLabel: String
    let unavailableReason: String?

    static let unavailable = TrixAppLockAvailability(
        canAuthenticate: false,
        authenticationLabel: "Unavailable",
        unavailableReason: "System authentication is unavailable on this device."
    )
}

@MainActor
protocol TrixAppLockAuthenticating {
    func availability() -> TrixAppLockAvailability
    func authenticate(reason: String) async throws -> Bool
}

final class TrixAppLockSettingsStore {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "trix.app-lock.settings.v1"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> TrixAppLockSettings {
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(TrixAppLockSettings.self, from: data) else {
            return .default
        }

        return settings
    }

    func save(_ settings: TrixAppLockSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }
}

final class SystemTrixAppLockAuthenticator: TrixAppLockAuthenticating {
    func availability() -> TrixAppLockAvailability {
        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        let label = Self.authenticationLabel(for: context.biometryType, canAuthenticate: canAuthenticate)

        return TrixAppLockAvailability(
            canAuthenticate: canAuthenticate,
            authenticationLabel: label,
            unavailableReason: canAuthenticate ? nil : Self.errorMessage(for: error)
        )
    }

    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: true)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func authenticationLabel(for biometryType: LABiometryType, canAuthenticate: Bool) -> String {
        guard canAuthenticate else {
            return "Unavailable"
        }

        switch biometryType {
        case .faceID:
            return "Face ID or passcode"
        case .opticID:
            return "Optic ID or passcode"
        case .touchID:
            return "Touch ID or password"
        case .none:
            return "Device passcode or password"
        @unknown default:
            return "System authentication"
        }
    }

    private static func errorMessage(for error: NSError?) -> String {
        guard let error else {
            return "System authentication is unavailable on this device."
        }

        guard let code = LAError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }

        switch code {
        case .passcodeNotSet:
            return "Set a device passcode or password before enabling app lock."
        case .biometryNotAvailable:
            return "System authentication is not available on this device."
        case .biometryNotEnrolled:
            return "Enroll Face ID, Touch ID, or device authentication before enabling app lock."
        default:
            return error.localizedDescription
        }
    }
}

@MainActor
final class TrixAppLockViewModel: ObservableObject {
    @Published private(set) var settings: TrixAppLockSettings
    @Published private(set) var availability: TrixAppLockAvailability
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private let settingsStore: TrixAppLockSettingsStore
    private let authenticator: TrixAppLockAuthenticating
    private let now: () -> Date
    private var inactiveSince: Date?
    private var lastUnlockAt: Date?

    init(
        settingsStore: TrixAppLockSettingsStore = TrixAppLockSettingsStore(),
        authenticator: TrixAppLockAuthenticating? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedAuthenticator = authenticator ?? SystemTrixAppLockAuthenticator()
        self.settingsStore = settingsStore
        self.authenticator = resolvedAuthenticator
        self.now = now
        self.settings = settingsStore.load()
        self.availability = resolvedAuthenticator.availability()
    }

    var canLock: Bool {
        settings.isEnabled && availability.canAuthenticate
    }

    func setEnabled(_ isEnabled: Bool) {
        refreshAvailability()

        if isEnabled && !availability.canAuthenticate {
            errorMessage = availability.unavailableReason
            return
        }

        settings.isEnabled = isEnabled
        if isEnabled {
            lastUnlockAt = now()
            errorMessage = nil
        } else {
            isLocked = false
            isAuthenticating = false
            inactiveSince = nil
            lastUnlockAt = nil
            errorMessage = nil
        }
        settingsStore.save(settings)
    }

    func setLocksOnBackground(_ locksOnBackground: Bool) {
        settings.locksOnBackground = locksOnBackground
        settingsStore.save(settings)
    }

    func setIdleTimeout(_ idleTimeout: TrixAppLockIdleTimeout) {
        settings.idleTimeout = idleTimeout
        settingsStore.save(settings)
    }

    func lockNow() {
        lockIfAvailable()
    }

    func unlock() async {
        refreshAvailability()

        guard settings.isEnabled else {
            isLocked = false
            errorMessage = nil
            return
        }

        guard availability.canAuthenticate else {
            errorMessage = availability.unavailableReason
            return
        }

        isAuthenticating = true
        errorMessage = nil
        defer {
            isAuthenticating = false
        }

        do {
            let didAuthenticate = try await authenticator.authenticate(
                reason: "Unlock Trix to view chats and settings."
            )
            if didAuthenticate {
                isLocked = false
                lastUnlockAt = now()
                inactiveSince = nil
            } else {
                errorMessage = "Authentication was not completed."
            }
        } catch {
            errorMessage = Self.userFacingAuthenticationError(error)
        }
    }

    func refreshAvailability() {
        availability = authenticator.availability()
    }

    func handleAuthenticatedSessionRestored() {
        refreshAvailability()
        guard canLock else {
            return
        }

        isLocked = true
        inactiveSince = nil
        errorMessage = nil
    }

    func noteServerLoginCompleted() {
        guard settings.isEnabled else {
            return
        }

        isLocked = false
        lastUnlockAt = now()
        inactiveSince = nil
        errorMessage = nil
    }

    func clearAuthenticatedSession() {
        isLocked = false
        isAuthenticating = false
        inactiveSince = nil
        lastUnlockAt = nil
        errorMessage = nil
    }

    func handleLifecyclePhase(_ phase: TrixAppLockLifecyclePhase, isAuthenticated: Bool) {
        guard isAuthenticated else {
            clearAuthenticatedSession()
            return
        }

        guard !isAuthenticating else {
            return
        }

        switch phase {
        case .active:
            refreshAvailability()
            lockAfterIdleIfNeeded()
            inactiveSince = nil
        case .inactive, .background:
            if inactiveSince == nil {
                inactiveSince = now()
            }
            if settings.locksOnBackground {
                lockIfAvailable()
            }
        }
    }

    private func lockAfterIdleIfNeeded() {
        guard let idleDuration = settings.idleTimeout.duration,
              let inactiveSince,
              now().timeIntervalSince(inactiveSince) >= idleDuration else {
            return
        }

        lockIfAvailable()
    }

    private func lockIfAvailable() {
        refreshAvailability()
        guard canLock else {
            errorMessage = settings.isEnabled ? availability.unavailableReason : nil
            return
        }

        isLocked = true
        errorMessage = nil
    }

    private static func userFacingAuthenticationError(_ error: Error) -> String {
        let nsError = error as NSError
        guard let code = LAError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return "Authentication was canceled."
        case .userFallback:
            return "Use the system password prompt to unlock Trix."
        case .authenticationFailed:
            return "Authentication failed."
        case .passcodeNotSet:
            return "Set a device passcode or password before using app lock."
        case .biometryLockout:
            return "System authentication is locked. Use the device passcode or password."
        case .biometryNotAvailable:
            return "System authentication is not available on this device."
        case .biometryNotEnrolled:
            return "Enroll Face ID, Touch ID, or device authentication before using app lock."
        default:
            return nsError.localizedDescription
        }
    }
}
