import Foundation
import XCTest
@testable import Trix

@MainActor
final class TrixAppLockTests: XCTestCase {
    func testSettingsStorePersistsNonSecretPreferences() throws {
        let suiteName = "com.softgrid.trix.tests.app-lock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = TrixAppLockSettingsStore(userDefaults: defaults, key: "settings")
        let settings = TrixAppLockSettings(
            isEnabled: true,
            locksOnBackground: false,
            idleTimeout: .fiveMinutes
        )

        store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testUnavailableSystemAuthenticationCannotEnableLock() {
        let authenticator = TestAppLockAuthenticator(
            availability: TrixAppLockAvailability(
                canAuthenticate: false,
                authenticationLabel: "Unavailable",
                unavailableReason: "Unavailable in test"
            )
        )
        let viewModel = makeViewModel(authenticator: authenticator)

        viewModel.setEnabled(true)

        XCTAssertFalse(viewModel.settings.isEnabled)
        XCTAssertFalse(viewModel.isLocked)
        XCTAssertEqual(viewModel.errorMessage, "Unavailable in test")
    }

    func testRestoredSessionStartsLockedAndUnlockUsesAuthenticator() async {
        let authenticator = TestAppLockAuthenticator()
        let viewModel = makeViewModel(authenticator: authenticator)

        viewModel.setEnabled(true)
        viewModel.handleAuthenticatedSessionRestored()

        XCTAssertTrue(viewModel.isLocked)

        await viewModel.unlock()

        XCTAssertFalse(viewModel.isLocked)
        XCTAssertEqual(authenticator.authenticateCallCount, 1)
    }

    func testLifecycleChangesDuringSystemAuthenticationDoNotRelockAfterUnlock() async {
        let authenticator = TestAppLockAuthenticator(waitsForManualCompletion: true)
        let viewModel = makeViewModel(authenticator: authenticator)

        viewModel.setEnabled(true)
        viewModel.handleAuthenticatedSessionRestored()

        let unlockTask = Task {
            await viewModel.unlock()
        }
        while !viewModel.isAuthenticating {
            await Task.yield()
        }

        viewModel.handleLifecyclePhase(.inactive, isAuthenticated: true)
        authenticator.completeAuthentication()
        await unlockTask.value

        XCTAssertFalse(viewModel.isLocked)
    }

    func testBackgroundLocksVisibleContentWhenEnabled() {
        let viewModel = makeViewModel()

        viewModel.setEnabled(true)
        viewModel.noteServerLoginCompleted()
        viewModel.handleLifecyclePhase(.inactive, isAuthenticated: true)

        XCTAssertTrue(viewModel.isLocked)
    }

    func testIdleTimeoutLocksOnlyAfterConfiguredBackgroundInterval() {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let viewModel = makeViewModel(now: { currentDate })

        viewModel.setEnabled(true)
        viewModel.setLocksOnBackground(false)
        viewModel.setIdleTimeout(.oneMinute)
        viewModel.noteServerLoginCompleted()

        viewModel.handleLifecyclePhase(.background, isAuthenticated: true)
        currentDate = Date(timeIntervalSince1970: 1_030)
        viewModel.handleLifecyclePhase(.active, isAuthenticated: true)
        XCTAssertFalse(viewModel.isLocked)

        viewModel.handleLifecyclePhase(.background, isAuthenticated: true)
        currentDate = Date(timeIntervalSince1970: 1_091)
        viewModel.handleLifecyclePhase(.active, isAuthenticated: true)
        XCTAssertTrue(viewModel.isLocked)
    }

    private func makeViewModel(
        authenticator: TestAppLockAuthenticator = TestAppLockAuthenticator(),
        now: @escaping () -> Date = Date.init
    ) -> TrixAppLockViewModel {
        let suiteName = "com.softgrid.trix.tests.app-lock.vm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = TrixAppLockSettingsStore(userDefaults: defaults, key: "settings")
        return TrixAppLockViewModel(
            settingsStore: store,
            authenticator: authenticator,
            now: now
        )
    }
}

private final class TestAppLockAuthenticator: TrixAppLockAuthenticating {
    private let availabilityValue: TrixAppLockAvailability
    private let authenticateResult: Bool
    private let waitsForManualCompletion: Bool
    private var continuation: CheckedContinuation<Bool, Error>?
    private(set) var authenticateCallCount = 0

    init(
        availability: TrixAppLockAvailability = TrixAppLockAvailability(
            canAuthenticate: true,
            authenticationLabel: "Test Auth",
            unavailableReason: nil
        ),
        authenticateResult: Bool = true,
        waitsForManualCompletion: Bool = false
    ) {
        self.availabilityValue = availability
        self.authenticateResult = authenticateResult
        self.waitsForManualCompletion = waitsForManualCompletion
    }

    func availability() -> TrixAppLockAvailability {
        availabilityValue
    }

    func authenticate(reason: String) async throws -> Bool {
        authenticateCallCount += 1
        guard waitsForManualCompletion else {
            return authenticateResult
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeAuthentication() {
        continuation?.resume(returning: authenticateResult)
        continuation = nil
    }
}
