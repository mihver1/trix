# macOS UI Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real server-backed macOS UI testing lane with deterministic launch/bootstrap, stable accessibility anchors, and a first-wave `full_bundle` of onboarding, restore, and seeded chat flows.

**Architecture:** Keep `apps/macos` as the source of truth for app code, but add a committed Xcode project for reproducible UI automation. Launch-time UI-test bootstrap prepares local state and optional server fixtures before `AppModel.start()`, while app-owned accessibility identifiers give the UI suite durable anchors. The existing SwiftPM `macos` suite remains the fast non-UI lane; a new `macos-ui` suite runs XCUITest via `xcodebuild`.

**Tech Stack:** SwiftPM, XcodeGen, XCTest/XCUITest, SwiftUI, `xcodebuild`, local dev backend via Podman/Docker, existing macOS support types (`SessionStore`, `KeychainStore`, `WorkspaceStorePaths`), `trix-core` UniFFI bridges.

---

## File Structure

### Existing files to modify

- `apps/macos/Sources/TrixMac/App/TrixMacApp.swift`
  - Insert launch-time UI-test bootstrap before `model.start()`.
- `apps/macos/Sources/TrixMac/Features/Shared/RootView.swift`
  - Add root/workspace screen accessibility IDs and any restore-state surface anchors.
- `apps/macos/Sources/TrixMac/Features/Onboarding/OnboardingView.swift`
  - Add onboarding, pending approval, and pending-device-ID accessibility IDs.
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
  - Add workspace/sidebar/detail/timeline/composer/send/success/error anchors.
- `scripts/client-smoke-harness.sh`
  - Add `macos-ui` suite, backend preflight, and `xcodebuild` invocation.
- `docs/client-smoke-harness.md`
  - Document `macos-ui`, its coverage, backend dependency, and opt-in status.

### New files to create

- `apps/macos/project.yml`
  - XcodeGen project definition for `TrixMac`, `TrixMacTests`, and `TrixMacUITests`.
- `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
  - Shared launch-argument/env enums and `TrixMacAccessibilityID` namespace. This file should be compiled into both app and UI-test targets.
- `apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift`
  - Parse launch arguments/environment and expose the current configuration.
- `apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift`
  - Reset local test-owned state and perform pre-start bootstrap.
- `apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift`
  - Server-backed account-state and conversation fixture creation plus manifest persistence.
- `apps/macos/Tests/TrixMacTests/MacUITestLaunchConfigurationTests.swift`
  - Local parsing tests for launch configuration.
- `apps/macos/Tests/TrixMacTests/MacUITestAppBootstrapTests.swift`
  - Local reset/bootstrap tests that do not require a live backend.
- `apps/macos/Tests/TrixMacTests/MacUITestConversationSeedStateTests.swift`
  - Direct seed/bootstrap contract tests for manifest save/clear and conversation-scenario preconditions.
- `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
  - macOS UI-test app launcher helper.
- `apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift`
  - First-wave `full_bundle` UI smoke tests.

### Generated files to commit

- `apps/macos/TrixMac.xcodeproj/project.pbxproj`
- `apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme`

### Responsibility boundaries

- Keep launch parsing/bootstrap in `App/`.
- Keep identifiers and launch constants in one shared support file, not scattered through feature views.
- Keep server seeding and manifest logic together in one macOS-local seeder file for wave 1.
- Keep UI-test helper logic in `TrixMacUITests/TrixMacUITestApp.swift`; keep scenario assertions in `TrixMacSmokeUITests.swift`.
- Do not extract a shared Apple-platform seeding layer in this wave.

## Task 1: Launch Constants And Configuration Parsing

**Files:**
- Create: `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
- Create: `apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift`
- Test: `apps/macos/Tests/TrixMacTests/MacUITestLaunchConfigurationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TrixMac

final class MacUITestLaunchConfigurationTests: XCTestCase {
    func testMakeParsesArgumentsAndEnvironment() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [
                MacUITestLaunchArgument.enableUITesting,
                MacUITestLaunchArgument.resetState,
            ],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://127.0.0.1:8080",
                MacUITestLaunchEnvironment.seedScenario: MacUITestSeedScenario.pendingApproval.rawValue,
                MacUITestLaunchEnvironment.scenarioLabel: "pending-mac",
            ]
        )

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertTrue(configuration.resetLocalState)
        XCTAssertEqual(configuration.baseURLOverride, "http://127.0.0.1:8080")
        XCTAssertEqual(configuration.seedScenario, .pendingApproval)
        XCTAssertEqual(configuration.scenarioLabel, "pending-mac")
    }

    func testMakeParsesConversationScenarioEnvironment() {
        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [
                MacUITestLaunchEnvironment.conversationScenario: MacUITestConversationScenario.dmAndGroup.rawValue,
            ]
        )

        XCTAssertEqual(configuration.conversationScenario, .dmAndGroup)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path apps/macos --filter MacUITestLaunchConfigurationTests`

Expected: FAIL with missing `MacUITestLaunchConfiguration`, launch-argument/env symbols, or missing scenario enums.

- [ ] **Step 3: Write the minimal implementation**

Add:

- `MacUITestLaunchArgument` with at least `-trix-ui-testing` and `-trix-ui-reset-state`
- `MacUITestLaunchEnvironment` with:
  - `TRIX_MACOS_UI_TEST_BASE_URL`
  - `TRIX_MACOS_UI_TEST_SEED_SCENARIO`
  - `TRIX_MACOS_UI_TEST_CONVERSATION_SCENARIO`
  - `TRIX_MACOS_UI_TEST_SCENARIO_LABEL`
- `MacUITestSeedScenario`
  - `.approvedAccount`
  - `.pendingApproval`
  - `.restoreSession`
- `MacUITestConversationScenario`
  - `.dmAndGroup`
- `MacUITestLaunchConfiguration.make(arguments:environment:)`

Keep the parser small and deterministic:

```swift
struct MacUITestLaunchConfiguration {
    let isEnabled: Bool
    let resetLocalState: Bool
    let baseURLOverride: String?
    let seedScenario: MacUITestSeedScenario?
    let conversationScenario: MacUITestConversationScenario?
    let scenarioLabel: String?
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path apps/macos --filter MacUITestLaunchConfigurationTests`

Expected: PASS for both parsing tests.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift \
  apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift \
  apps/macos/Tests/TrixMacTests/MacUITestLaunchConfigurationTests.swift
git commit -m "test: add macos ui launch configuration"
```

## Task 2: Xcode Project And UI-Test Bundle Skeleton

**Files:**
- Create: `apps/macos/project.yml`
- Create: `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
- Create: `apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift`
- Generate: `apps/macos/TrixMac.xcodeproj/project.pbxproj`
- Generate: `apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme`

- [ ] **Step 1: Write the failing UI-test skeleton**

```swift
import XCTest

final class TrixMacSmokeUITests: XCTestCase {
    func testAppLaunches() {
        let app = TrixMacUITestApp.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testAppLaunches \
  test
```

Expected: FAIL because the Xcode project / UI-test target does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `apps/macos/project.yml` with:

- `TrixMac` app target
- `TrixMacTests` unit-test target using `Tests/TrixMacTests`
- `TrixMacUITests` UI-test target using `TrixMacUITests`
- shared inclusion of `Sources/TrixMac/Support/MacUITestSupport.swift` in both app and UI-test bundle

Create `TrixMacUITestApp.swift`:

```swift
import XCTest

enum TrixMacUITestApp {
    static func launch(
        resetState: Bool = true,
        seedScenario: MacUITestSeedScenario? = nil,
        conversationScenario: MacUITestConversationScenario? = nil,
        scenarioLabel: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [MacUITestLaunchArgument.enableUITesting]
        if resetState {
            app.launchArguments.append(MacUITestLaunchArgument.resetState)
        }
        if let seedScenario {
            app.launchEnvironment[MacUITestLaunchEnvironment.seedScenario] = seedScenario.rawValue
        }
        if let conversationScenario {
            app.launchEnvironment[MacUITestLaunchEnvironment.conversationScenario] = conversationScenario.rawValue
        }
        if let scenarioLabel {
            app.launchEnvironment[MacUITestLaunchEnvironment.scenarioLabel] = scenarioLabel
        }
        app.launch()
        return app
    }
}
```

Generate the project:

Run: `cd apps/macos && xcodegen generate`

- [ ] **Step 4: Run the test to verify it passes**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for `testAppLaunches`.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/project.yml \
  apps/macos/TrixMacUITests/TrixMacUITestApp.swift \
  apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift \
  apps/macos/TrixMac.xcodeproj/project.pbxproj \
  apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme
git commit -m "build: add macos xcode ui test project"
```

## Task 3: Pre-Start Bootstrap And Local Reset

**Files:**
- Create: `apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift`
- Modify: `apps/macos/Sources/TrixMac/App/TrixMacApp.swift`
- Test: `apps/macos/Tests/TrixMacTests/MacUITestAppBootstrapTests.swift`

- [ ] **Step 1: Write the failing local reset/bootstrap tests**

```swift
import XCTest
@testable import TrixMac

final class MacUITestAppBootstrapTests: XCTestCase {
    func testResetLocalStateClearsSessionAndKeychain() throws {
        let sessionStore = SessionStore(directoryName: "test-macos-ui", fileName: "session.json")
        let keychain = KeychainStore()

        try sessionStore.save(
            PersistedSession(
                baseURLString: "http://127.0.0.1:8080",
                accountId: UUID(),
                deviceId: UUID(),
                accountSyncChatId: nil,
                profileName: "UI Test",
                handle: "ui-test",
                deviceDisplayName: "This Mac",
                deviceStatus: .active
            )
        )
        try keychain.save(Data("token".utf8), for: .accessToken)

        try MacUITestAppBootstrap.resetLocalState(
            sessionStore: sessionStore,
            keychainStore: keychain
        )

        XCTAssertNil(try sessionStore.load())
        XCTAssertNil(try keychain.loadData(for: .accessToken))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path apps/macos --filter MacUITestAppBootstrapTests`

Expected: FAIL with missing `MacUITestAppBootstrap` or missing `resetLocalState`.

- [ ] **Step 3: Write the minimal implementation**

Create `MacUITestAppBootstrap` with:

- `prepareForLaunch(configuration:) async throws -> String?`
- `resetLocalState(...)`

Reset logic must clear:

- `SessionStore`
- all `VaultKey` keychain entries
- app-owned workspace directory under `Application Support/com.softgrid.trixapp/workspaces`
- any persisted UI-test fixture manifest state

Wire it into `TrixMacApp` before `model.start()`:

```swift
.task {
    do {
        let resolvedBaseURL = try await MacUITestAppBootstrap.prepareForLaunch(
            configuration: .current
        )
        if let resolvedBaseURL {
            model.serverBaseURLString = resolvedBaseURL
        }
        await model.start()
    } catch {
        if MacUITestLaunchConfiguration.current.isEnabled {
            preconditionFailure("macOS UI test bootstrap failed: \(error.localizedDescription)")
        }
        await model.start()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path apps/macos --filter MacUITestAppBootstrapTests`

Expected: PASS for the reset/bootstrap tests.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift \
  apps/macos/Sources/TrixMac/App/TrixMacApp.swift \
  apps/macos/Tests/TrixMacTests/MacUITestAppBootstrapTests.swift
git commit -m "test: add macos ui bootstrap reset path"
```

## Task 4: Account-State Seeding Plus Onboarding / Pending / Restore UI Flows

**Files:**
- Create: `apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift`
- Modify: `apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift`
- Modify: `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Shared/RootView.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Onboarding/OnboardingView.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift`

- [ ] **Step 1: Write the failing UI tests for the first three flows**

```swift
func testCreateAccountFlowShowsWorkspace() {
    let app = TrixMacUITestApp.launch(resetState: true, scenarioLabel: "mac-create")
    XCTAssertTrue(app.textFields[TrixMacAccessibilityID.Onboarding.profileNameField].waitForExistence(timeout: 10))
    app.textFields[TrixMacAccessibilityID.Onboarding.profileNameField].click()
    app.typeText("UI Mac Account")
    app.buttons[TrixMacAccessibilityID.Onboarding.createAccountButton].click()
    XCTAssertTrue(app.otherElements[TrixMacAccessibilityID.Root.workspaceScreen].waitForExistence(timeout: 20))
}

func testPendingApprovalSeedShowsWaitingPanel() {
    let app = TrixMacUITestApp.launch(
        resetState: true,
        seedScenario: .pendingApproval,
        scenarioLabel: "mac-pending"
    )
    XCTAssertTrue(app.otherElements[TrixMacAccessibilityID.Root.pendingApprovalScreen].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts[TrixMacAccessibilityID.Onboarding.pendingDeviceIDValue].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons[TrixMacAccessibilityID.Onboarding.reconnectAfterApprovalButton].waitForExistence(timeout: 10))
}

func testRestoreSeedLaunchesWorkspace() {
    let app = TrixMacUITestApp.launch(
        resetState: true,
        seedScenario: .restoreSession,
        scenarioLabel: "mac-restore"
    )
    XCTAssertTrue(app.otherElements[TrixMacAccessibilityID.Root.restoreSessionScreen].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons[TrixMacAccessibilityID.Restore.reconnectButton].waitForExistence(timeout: 10))
    XCTAssertTrue(app.otherElements[TrixMacAccessibilityID.Root.workspaceScreen].waitForExistence(timeout: 20))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testCreateAccountFlowShowsWorkspace \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testPendingApprovalSeedShowsWaitingPanel \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testRestoreSeedLaunchesWorkspace \
  test
```

Expected: FAIL because seeding, launch bootstrap integration, and accessibility anchors are not implemented yet.

- [ ] **Step 3: Write the minimal implementation**

Implement account-state seeding in `MacUITestFixtureSeeder.swift`:

- `approved-account`
- `pending-approval`
- `restore-session`

Use `scenarioLabel` to derive unique handles/device names. Persist whatever the app really expects:

- `SessionStore` session data
- `KeychainStore` key material
- workspace directory state only when required

Update `MacUITestAppBootstrap.prepareForLaunch(...)` so it:

- invokes the seeder for `seedScenario` / `conversationScenario`
- persists any returned manifest
- clears the manifest when the active scenario does not need one
- continues clearing manifest state during `resetLocalState`

Add app identifiers:

- `TrixMacAccessibilityID.Root.onboardingScreen`
- `TrixMacAccessibilityID.Root.pendingApprovalScreen`
- `TrixMacAccessibilityID.Root.restoreSessionScreen`
- `TrixMacAccessibilityID.Root.workspaceScreen`
- onboarding field/action IDs
- `TrixMacAccessibilityID.Onboarding.pendingDeviceIDValue`

Update `TrixMacUITestApp.launch(...)` to always pass `TRIX_MACOS_UI_TEST_BASE_URL` and the chosen scenario env vars.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for the create-account, pending-approval, and restore-session UI tests.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift \
  apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift \
  apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift \
  apps/macos/Sources/TrixMac/Features/Shared/RootView.swift \
  apps/macos/Sources/TrixMac/Features/Onboarding/OnboardingView.swift \
  apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift \
  apps/macos/TrixMacUITests/TrixMacUITestApp.swift \
  apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift
git commit -m "feat: add macos onboarding and restore ui flows"
```

## Task 5: Seed-State Contract Tests

**Files:**
- Create: `apps/macos/Tests/TrixMacTests/MacUITestConversationSeedStateTests.swift`
- Modify: `apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift`
- Modify: `apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift`

- [ ] **Step 1: Write the failing seed-state tests**

```swift
import XCTest
@testable import TrixMac

final class MacUITestConversationSeedStateTests: XCTestCase {
    func testConversationScenarioRequiresAccountStateSeed() async throws {
        guard ProcessInfo.processInfo.environment[MacUITestLaunchEnvironment.baseURL] != nil else {
            throw XCTSkip("Set TRIX_MACOS_UI_TEST_BASE_URL to run server-backed macOS seed-state tests.")
        }
        do {
            _ = try await MacUITestAppBootstrap.prepareForLaunch(
                configuration: MacUITestLaunchConfiguration(
                    isEnabled: true,
                    resetLocalState: true,
                    baseURLOverride: "http://127.0.0.1:8080",
                    seedScenario: nil,
                    conversationScenario: .dmAndGroup,
                    scenarioLabel: "missing-account-seed"
                )
            )
            XCTFail("Expected dm-and-group without an account-state seed to be rejected.")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testConversationScenarioRequiresApprovedOrRestoreAccountState() async throws {
        guard ProcessInfo.processInfo.environment[MacUITestLaunchEnvironment.baseURL] != nil else {
            throw XCTSkip("Set TRIX_MACOS_UI_TEST_BASE_URL to run server-backed macOS seed-state tests.")
        }
        do {
            _ = try await MacUITestAppBootstrap.prepareForLaunch(
                configuration: MacUITestLaunchConfiguration(
                    isEnabled: true,
                    resetLocalState: true,
                    baseURLOverride: "http://127.0.0.1:8080",
                    seedScenario: .pendingApproval,
                    conversationScenario: .dmAndGroup,
                    scenarioLabel: "invalid-chat-seed"
                )
            )
            XCTFail("Expected pending-approval + dm-and-group to be rejected.")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testPrepareForLaunchPersistsAndClearsFixtureManifest() async throws {
        guard ProcessInfo.processInfo.environment[MacUITestLaunchEnvironment.baseURL] != nil else {
            throw XCTSkip("Set TRIX_MACOS_UI_TEST_BASE_URL to run server-backed macOS seed-state tests.")
        }
        let seeded = try await MacUITestAppBootstrap.prepareForLaunch(
            configuration: MacUITestLaunchConfiguration(
                isEnabled: true,
                resetLocalState: true,
                baseURLOverride: "http://127.0.0.1:8080",
                seedScenario: .approvedAccount,
                conversationScenario: .dmAndGroup,
                scenarioLabel: "manifest-chat-seed"
            )
        )
        XCTAssertEqual(seeded, "http://127.0.0.1:8080")
        XCTAssertNotNil(MacUITestFixtureManifestStore.load())

        _ = try await MacUITestAppBootstrap.prepareForLaunch(
            configuration: MacUITestLaunchConfiguration(
                isEnabled: true,
                resetLocalState: true,
                baseURLOverride: "http://127.0.0.1:8080",
                seedScenario: .approvedAccount,
                conversationScenario: nil,
                scenarioLabel: "manifest-clear"
            )
        )
        XCTAssertNil(MacUITestFixtureManifestStore.load())
    }

    func testRestoreSessionPlusConversationScenarioPersistsFixtureManifest() async throws {
        guard ProcessInfo.processInfo.environment[MacUITestLaunchEnvironment.baseURL] != nil else {
            throw XCTSkip("Set TRIX_MACOS_UI_TEST_BASE_URL to run server-backed macOS seed-state tests.")
        }
        _ = try await MacUITestAppBootstrap.prepareForLaunch(
            configuration: MacUITestLaunchConfiguration(
                isEnabled: true,
                resetLocalState: true,
                baseURLOverride: "http://127.0.0.1:8080",
                seedScenario: .restoreSession,
                conversationScenario: .dmAndGroup,
                scenarioLabel: "restore-chat-seed"
            )
        )
        XCTAssertNotNil(MacUITestFixtureManifestStore.load())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
swift test --package-path apps/macos --filter MacUITestConversationSeedStateTests
```

Expected: FAIL because manifest persistence/clear behavior or the conversation-scenario precondition is not fully implemented yet.

- [ ] **Step 3: Write the minimal implementation**

Complete the seeder/bootstrap contract:

- implement `dmAndGroup` seeding and manifest population in the seeder itself
- make `conversationScenario` valid only when paired with `approved-account` or `restore-session`
- reject `conversationScenario` for `nil` account-state seed and for `pending-approval`
- keep `conversationScenario` additive: it augments the already-seeded account state and never silently creates its own primary account
- save the fixture manifest for valid `approved-account` / `restore-session` + `dm-and-group` launches
- clear the manifest for non-conversation launches
- keep the code path callable directly from tests, not only through app launch
- skip these tests cleanly when `TRIX_MACOS_UI_TEST_BASE_URL` is absent so the default `macos` SwiftPM lane stays local-first

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `swift test` command from Step 2.

Expected: PASS for the direct seed-state contract tests.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Tests/TrixMacTests/MacUITestConversationSeedStateTests.swift \
  apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift \
  apps/macos/Sources/TrixMac/App/MacUITestAppBootstrap.swift
git commit -m "test: add macos seed state contract coverage"
```

## Task 6: Seeded Conversation Fixtures And Read-Only Workspace Coverage

**Files:**
- Modify: `apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift`
- Modify: `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Shared/RootView.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift`

- [ ] **Step 1: Write the failing seeded chat-list and detail tests**

```swift
func testSeededConversationBundleShowsDMAndGroupRows() {
    let app = TrixMacUITestApp.launch(
        resetState: true,
        seedScenario: .approvedAccount,
        conversationScenario: .dmAndGroup,
        scenarioLabel: "mac-chat-list"
    )
    XCTAssertTrue(app.buttons[TrixMacAccessibilityID.Workspace.chatRow(.dm)].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons[TrixMacAccessibilityID.Workspace.chatRow(.group)].waitForExistence(timeout: 20))
}

func testSeededGroupDetailShowsTimeline() {
    let app = TrixMacUITestApp.launch(
        resetState: true,
        seedScenario: .approvedAccount,
        conversationScenario: .dmAndGroup,
        scenarioLabel: "mac-group-detail"
    )
    app.buttons[TrixMacAccessibilityID.Workspace.chatRow(.group)].click()
    XCTAssertTrue(app.otherElements[TrixMacAccessibilityID.Workspace.detailScreen].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts[TrixMacAccessibilityID.Workspace.message(.groupSeed)].waitForExistence(timeout: 10))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testSeededConversationBundleShowsDMAndGroupRows \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testSeededGroupDetailShowsTimeline \
  test
```

Expected: FAIL because conversation seeding, manifest-backed row IDs, or detail/timeline message anchors are missing.

- [ ] **Step 3: Write the minimal implementation**

Extend the seeder with:

- `MacUITestConversationScenario.dmAndGroup`
- manifest persistence for seeded chat IDs and seeded message IDs

Add anchored workspace IDs:

- `sidebarChatList`
- `detailScreen`
- `timeline`
- `chatRow(.dm)` / `chatRow(.group)`
- `message(.dmSeed)` / `message(.groupSeed)`

Use manifest-derived identifiers for the concrete seeded rows and message anchors instead of rendered titles.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for sidebar row assertions and seeded group detail timeline assertion.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/App/MacUITestFixtureSeeder.swift \
  apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift \
  apps/macos/Sources/TrixMac/Features/Shared/RootView.swift \
  apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift \
  apps/macos/TrixMacUITests/TrixMacUITestApp.swift \
  apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift
git commit -m "feat: add macos seeded workspace ui coverage"
```

## Task 7: Seeded DM Send Flow

**Files:**
- Modify: `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- Modify: `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift`

- [ ] **Step 1: Write the failing DM send-flow test**

```swift
private func composerInput(in app: XCUIApplication) -> XCUIElement {
    let identified = app.descendants(matching: .any)[TrixMacAccessibilityID.Workspace.composerField]
    if identified.waitForExistence(timeout: 2) {
        return identified
    }
    return app.textViews.firstMatch
}

func testSeededDMDetailShowsTimelineAndSupportsSendFlow() {
    let app = TrixMacUITestApp.launch(
        resetState: true,
        seedScenario: .approvedAccount,
        conversationScenario: .dmAndGroup,
        scenarioLabel: "mac-dm-send"
    )
    app.buttons[TrixMacAccessibilityID.Workspace.chatRow(.dm)].click()
    XCTAssertTrue(app.staticTexts[TrixMacAccessibilityID.Workspace.message(.dmSeed)].waitForExistence(timeout: 10))

    let composer = composerInput(in: app)
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.click()
    app.typeText("mac-ui-send")

    app.buttons[TrixMacAccessibilityID.Workspace.sendButton].click()

    XCTAssertTrue(
        app.staticTexts[TrixMacAccessibilityID.Workspace.latestSentMessage].waitForExistence(timeout: 10)
        || app.staticTexts["mac-ui-send"].waitForExistence(timeout: 10)
        || app.otherElements[TrixMacAccessibilityID.Workspace.successBanner].waitForExistence(timeout: 10)
    )
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests/testSeededDMDetailShowsTimelineAndSupportsSendFlow \
  test
```

Expected: FAIL because the composer/send/success anchors are missing or the outgoing success signal is not yet exposed.

- [ ] **Step 3: Write the minimal implementation**

In `WorkspaceView.swift`, add anchors for:

- composer field
- send button
- success banner
- error banner
- latest sent message anchor

If the send button remains hard to surface in the accessibility tree, fix it app-side first. Only add a coordinate fallback in the UI test helper if the app-side identifier still does not materialize after a deliberate attempt to make it accessible.

- [ ] **Step 4: Run the test to verify it passes**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for the seeded DM send-flow UI test.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift \
  apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift \
  apps/macos/TrixMacUITests/TrixMacSmokeUITests.swift
git commit -m "feat: add macos dm send ui smoke"
```

## Task 8: Harness And Documentation Integration

**Files:**
- Modify: `scripts/client-smoke-harness.sh`
- Modify: `docs/client-smoke-harness.md`

- [ ] **Step 1: Write the failing harness expectation**

Run:

```bash
./scripts/client-smoke-harness.sh --list-suites | rg '^macos-ui$'
```

Expected: FAIL because `macos-ui` is not listed yet.

- [ ] **Step 2: Add the minimal implementation**

In `scripts/client-smoke-harness.sh`:

- add `macos-ui` to `--list-suites`
- add `TRIX_MACOS_UI_TEST_BASE_URL` support
- add backend preflight that fails when the backend is unavailable
- keep `macos-ui` opt-in only; do not add it to the default suite pack
- treat `macos-ui` as a server-backed suite in suite selection, startup, health-wait, and teardown branching
- resolve health readiness from `TRIX_MACOS_UI_TEST_BASE_URL` rather than the iOS-only env
- run:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL="${TRIX_MACOS_UI_TEST_BASE_URL:-http://localhost:8080}" \
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests \
  test
```

In `docs/client-smoke-harness.md`, document:

- what `macos-ui` runs
- that it is server-backed
- that it is opt-in in wave 1
- the difference between `macos` and `macos-ui`

- [ ] **Step 3: Verify the list command now passes**

Run:

```bash
./scripts/client-smoke-harness.sh --list-suites | rg '^macos-ui$'
```

Expected: PASS with `macos-ui` in the output.

- [ ] **Step 4: Run the real harness verification**

Run:

```bash
./scripts/client-smoke-harness.sh --suite macos-ui --suite macos --stop-postgres
```

Expected:

- `macos-ui` passes through `xcodebuild`
- `macos` still passes through `swift test`
- harness exits 0

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/client-smoke-harness.sh \
  docs/client-smoke-harness.md
git commit -m "docs: add macos ui smoke harness"
```

## Final Verification

- [ ] Run local non-UI tests:

```bash
swift test --package-path apps/macos
```

Expected: PASS for existing macOS package tests plus new local UI-test bootstrap/config tests.

- [ ] Run direct seed-state contract tests:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
swift test --package-path apps/macos --filter MacUITestConversationSeedStateTests
```

Expected: PASS for manifest and conversation-scenario contract coverage.

- [ ] Run focused macOS UI tests directly:

```bash
env TRIX_MACOS_UI_TEST_BASE_URL=http://127.0.0.1:8080 \
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests \
  test
```

Expected: PASS for all six `full_bundle` UI tests.

- [ ] Run smoke harness verification:

```bash
./scripts/client-smoke-harness.sh --suite macos-ui --suite macos --stop-postgres
```

Expected: PASS with both lanes green.

- [ ] Run `@superpowers:verification-before-completion` before claiming the rollout is done.

## Notes For Execution

- Use `@superpowers:test-driven-development` for each task. Do not skip the red step just because the task is “infrastructure.”
- Use `@superpowers:systematic-debugging` if XCUITest finds the wrong control, misses the send button, or behaves inconsistently under macOS accessibility.
- Regenerate `apps/macos/TrixMac.xcodeproj` only from `apps/macos/project.yml`; do not hand-edit generated Xcode project files unless generation cannot express the needed setting.
- Keep `macos-ui` opt-in until at least two consecutive full harness runs are green.
