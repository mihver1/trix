# macOS UI Testing Design

## Summary

This design introduces a real macOS UI testing harness for `apps/macos` that mirrors the iOS approach: an Xcode-driven app target plus a separate UI-test bundle, deterministic launch-time bootstrap, server-backed fixture seeding, and stable accessibility anchors for the main user journeys.

The first rollout intentionally targets one coherent `full_bundle`:

- onboarding create-account flow
- pending-approval flow
- restore-session flow
- seeded workspace chat-list flow
- seeded DM detail and send flow
- seeded group detail flow

The goal is to make macOS UI tests trustworthy enough to run via `xcodebuild` and a future `macos-ui` smoke-harness suite, without replacing the existing fast `swift test` path for the macOS package.

## Context

The macOS client currently lives as a SwiftPM app in `apps/macos` and can be run from Xcode by opening `Package.swift`, but it does not yet have:

- a committed Xcode project for reproducible UI automation
- a UI-test bundle
- a launch contract for deterministic test-mode startup
- server-backed fixture seeding for workspace/chat scenarios
- stable accessibility identifiers for core UI surfaces

The app lifecycle already gives us a clean bootstrap seam: `TrixMacApp` creates `AppModel` and then calls `await model.start()`. `AppModel.start()` already restores session state from `SessionStore`, refreshes server status, and attempts `restoreSession()` when persisted session data exists. This makes launch-time state injection practical as long as it runs before `model.start()`.

## Goals

- Add a reproducible Xcode-based macOS UI-test harness.
- Keep the existing SwiftPM package and `swift test` workflow working.
- Support deterministic server-backed launch scenarios for macOS UI tests.
- Cover the first high-value end-to-end macOS UI bundle through real app surfaces.
- Add stable accessibility identifiers so tests do not rely on labels, SF Symbols, or brittle hierarchy assumptions.
- Integrate the resulting UI-test suite into the smoke harness as `macos-ui`.

## Non-Goals

- No attachment send/download UI coverage in the first wave.
- No first-wave coverage for settings mutations, device administration, or advanced tooling panels.
- No attempt to unify iOS and macOS UI fixture seeding into a cross-platform shared module yet.
- No replacement of the current `macos` suite; `swift test` remains the fast non-UI path.

## Decision Summary

The chosen direction is:

1. Create a committed Xcode project for the macOS app instead of relying on ad hoc local Xcode package state.
2. Add a real `TrixMacUITests` UI-test bundle using XCTest/XCUITest.
3. Introduce a deterministic macOS launch contract and bootstrap layer that executes before `model.start()`.
4. Use live local backend seeding for pending, restore, and seeded workspace/chat scenarios.
5. Add stable accessibility identifiers for onboarding, restore, workspace, sidebar, detail timeline, composer, and send outcomes.
6. Keep the rollout deliberately narrow enough to green a real `full_bundle` without pulling in every macOS screen.

## Architecture

### 1. Xcode Project Layer

Add `apps/macos/project.yml` and generate a committed `apps/macos/TrixMac.xcodeproj` with:

- `TrixMac` app target
- `TrixMacTests` unit-test target
- `TrixMacUITests` UI-test target

This project exists alongside `Package.swift`, not instead of it. The Xcode project is the reproducible automation entrypoint for UI tests; SwiftPM remains the fast build/test entrypoint for package-local development and the current `macos` harness suite.

The Xcode project should share the same source tree under `Sources/TrixMac` and the same existing unit tests under `Tests/TrixMacTests`. The UI-test bundle is a new target layered on top.

### 2. Launch Contract

Add a macOS launch contract parallel to iOS:

- `MacUITestLaunchArgument`
- `MacUITestLaunchEnvironment`
- `MacUITestLaunchConfiguration`
- `MacUITestAppBootstrap`

Responsibilities:

- detect whether UI testing is enabled
- optionally reset local app state
- accept a base URL override
- accept `seedScenario` and `conversationScenario` selectors for seeding
- accept a `scenarioLabel` / run identifier for unique server-side fixture naming
- run deterministic bootstrap before `await model.start()`

`TrixMacApp` should resolve the launch configuration first and then:

1. fail fast in UI-test mode if bootstrap fails
2. update the model/bootstrap state as needed
3. call `model.start()` only after local and server state are prepared

### 3. Local State Reset

`resetState` must wipe only test-owned macOS state:

- `SessionStore` session file
- app-owned `KeychainStore` entries
- local workspace/application-support state under the app namespace
- any UI-test fixture manifest store

The reset path must stay scoped to the macOS app namespace to avoid deleting unrelated developer state.

### 4. Server-Backed Fixture Seeding

Add a macOS fixture seeding layer:

- `MacUITestFixtureSeeder`
- `MacUITestSeedScenario`
- `MacUITestConversationScenario`
- `MacUITestFixtureManifest`
- `MacUITestFixtureManifestStore`

The seeding concepts should mirror iOS naming and behavior where practical, but the implementation may stay macOS-local in the first wave.

The launch contract should treat account-state seeding and conversation seeding as separate inputs.

Supported first-wave account-state scenarios:

- `approved-account`
- `pending-approval`
- `restore-session`

Supported first-wave conversation scenarios:

- `dm-and-group`

`dm-and-group` must not be ambiguous: it requires an already-seeded active signed-in account state and should be launched together with either `approved-account` or `restore-session`. It only adds seeded chats/messages on top of that account state and does not silently replace the account-state scenario.

The restore-session scenario should prepare local persisted session/key material so the app naturally follows the existing `AppModel.start()` -> `restoreSession()` path instead of a fake shortcut.

The combined `approved-account` + `dm-and-group` bundle should create:

- one approved primary device/account for the Mac app
- one seeded DM
- one seeded group
- one seeded incoming message in each target chat
- enough manifest metadata to identify seeded rows/messages in UI

The seeder must incorporate `scenarioLabel` into created handles, device names, and other server-visible test fixtures so repeated local runs and future parallel execution do not collide on a shared dev backend.

### 5. Accessibility Namespace

Introduce a shared accessibility namespace such as `TrixMacAccessibilityID` in app code and use it consistently across onboarding, restore, workspace, and seeded chat surfaces.

Required first-wave anchors:

- `Root`
  - onboarding screen
  - pending approval screen
  - restore session screen
  - workspace screen
- `Onboarding`
  - create/link mode buttons
  - server URL field
  - profile name field
  - handle field
  - bio field
  - device name field
  - link payload field
  - check-server button
  - create-account button
  - register-pending-device button
  - reconnect-after-approval button
  - restart-link button
  - pending device ID value
- `Workspace`
  - sidebar chat list
  - manifest-derived seeded DM/group chat rows
  - detail screen
  - timeline
  - manifest-derived seeded message rows
  - composer input
  - send button
  - success banner
  - error banner
- `Restore`
  - restore panel
  - reconnect button

Tests should treat explicit identifiers as the primary path. Label- or coordinate-based fallback should be exceptional and justified only for controls that remain inaccessible despite app-side work.

For seeded scenarios, tests should prefer manifest-derived IDs for the specific DM row, group row, and seeded message rows rather than asserting only on rendered titles or message text.

## Scenario Bundle

The first `full_bundle` should contain these UI tests:

### 1. `testCreateAccountFlowShowsWorkspace`

- reset local state
- launch into clean onboarding
- fill create-account form
- submit create-account
- assert workspace screen appears

### 2. `testPendingApprovalSeedShowsWaitingPanel`

- reset and seed pending-approval state
- launch app
- assert pending-approval screen
- assert pending device ID and reconnect action are visible

### 3. `testRestoreSeedLaunchesWorkspace`

- reset and seed restore-session state
- launch app
- allow `model.start()` to restore through the real persisted-session path
- assert workspace screen appears without manual onboarding

### 4. `testSeededConversationBundleShowsDMAndGroupRows`

- reset and seed `approved-account` plus `dm-and-group`
- launch into workspace
- assert both seeded chat rows exist in sidebar

### 5. `testSeededDMDetailShowsTimelineAndSupportsSendFlow`

- open seeded DM
- assert seeded DM message/timeline row
- type via real composer
- send through the production UI
- assert success via app-side send anchor and/or rendered outgoing content

### 6. `testSeededGroupDetailShowsTimeline`

- open seeded group
- assert seeded group message/timeline row

## Error Handling And Determinism

- UI-test bootstrap failures must fail fast in UI-test mode rather than silently falling back to onboarding.
- Backend-dependent tests may skip early for ad hoc local direct runs, but the harness path must fail preflight when the backend health endpoint is unavailable so `macos-ui` cannot go green with zero exercised coverage.
- The send-flow assertion should rely on explicit app-owned success signals, not only visual timing assumptions.
- The fixture manifest should be cleared whenever a scenario does not need it.
- The app must not keep stale UI-test state across launches when `resetState` is requested.

## Verification Strategy

Before calling the rollout complete, verification should include:

- targeted bootstrap/config unit tests for launch parsing and reset/seeding behavior
- direct `xcodebuild` execution of the new macOS UI suite
- smoke-harness execution through a new `macos-ui` suite
- regression confirmation that the existing `macos` SwiftPM suite still passes

Expected verification split:

- `macos`: fast local `swift test`
- `macos-ui`: server-backed XCUITest automation via `xcodebuild`

## Harness Integration

Add a `macos-ui` suite to `scripts/client-smoke-harness.sh` that:

- resolves a macOS destination
- uses the committed Xcode project
- launches `xcodebuild test` for `TrixMacUITests`
- accepts a base-URL override similar to the iOS suites
- performs backend preflight and fails the suite if the backend is unavailable

In wave 1, `macos-ui` should be opt-in and must not join the default smoke pack until the lane is stable.

Update `docs/client-smoke-harness.md` to document:

- the new `macos-ui` suite
- its backend dependency
- its first-wave coverage
- the distinction between `macos` and `macos-ui`

## Rollout Plan

### Wave 1

- add project generation and committed Xcode project
- add launch contract/bootstrap
- add fixture seeding and manifest store
- add accessibility identifiers for the first bundle
- add `TrixMacUITests` helpers and the six agreed smoke tests
- add `macos-ui` harness integration

### Wave 2

- attachment send/download UI coverage
- richer settings/device-management coverage
- app lifecycle/background/resume assertions

## Risks

- Maintaining both SwiftPM and Xcode project metadata adds some overhead, but it is the cleanest path to real UI automation.
- macOS accessibility can be less predictable than iOS; missing identifiers on image-only controls will create flakiness unless fixed app-side.
- Restore-session seeding must respect real session/keychain semantics or the tests will validate an artificial path.
- Trying to deduplicate macOS and iOS UI-test infrastructure too early would slow down the first useful rollout.

## Recommendation

Proceed with a macOS-specific first implementation wave that mirrors the successful iOS UI-testing architecture, but keeps the seeding/bootstrap code local to `apps/macos` for now. That gives the project a real `macos-ui` lane quickly, keeps the existing SwiftPM path intact, and avoids over-abstracting before the macOS harness proves itself.
