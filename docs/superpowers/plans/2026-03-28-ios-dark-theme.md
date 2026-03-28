# iOS Dark Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix missing dark-theme support in the iOS onboarding and consumer chat flows by introducing a small shared theme layer, migrating user-facing surfaces to it, and adding focused dark-mode verification.

**Architecture:** Add a narrow semantic theme palette in `apps/ios/TrixiOS/Support/`, then migrate the affected SwiftUI views away from light-only hardcoded colors. Extend the UI-test launch contract so smoke tests can force dark mode, and use targeted unit/UI coverage to protect the new theme layer and launch path.

**Tech Stack:** SwiftUI, UIKit semantic colors, XCTest, XCUITest, XcodeGen/Xcode project, existing iOS launch bootstrap and smoke harness.

---

## File Structure

### New files to create

- `apps/ios/TrixiOS/Support/TrixTheme.swift`
  - shared dynamic iOS theme tokens for branded accent, surfaces, gradient stops, chat bubbles, separators, and banner backgrounds
- `apps/ios/TrixiOSTests/TrixThemeTests.swift`
  - focused tests for dynamic theme-token behavior across light and dark trait collections

### Existing files to modify

- `apps/ios/TrixiOS/Features/Onboarding/CreateAccountView.swift`
  - replace light-only onboarding surfaces and gradients with theme tokens
- `apps/ios/TrixiOS/Features/Onboarding/PendingApprovalView.swift`
  - replace light-only approval surfaces and gradients with theme tokens
- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
  - migrate chat backdrop, incoming surfaces, chips, system cards, composer, and attachment tray to theme tokens
- `apps/ios/TrixiOS/Features/Home/DashboardView.swift`
  - replace any obvious shared light-surface hardcodes found during the same pass
- `apps/ios/UITestSupport/TrixUITestSupport.swift`
  - add a UI-test appearance override contract
- `apps/ios/TrixiOS/App/UITestLaunchConfiguration.swift`
  - parse the new appearance override from UI-test launch environment
- `apps/ios/TrixiOS/App/TrixiOSApp.swift`
  - apply the requested UI-test appearance override at app launch
- `apps/ios/TrixiOSTests/UITestLaunchConfigurationTests.swift`
  - cover parsing of the new appearance override
- `apps/ios/TrixiOSUITests/TrixUITestApp.swift`
  - add a launch helper for dark-mode UI runs
- `apps/ios/TrixiOSUITests/TrixiOSSmokeUITests.swift`
  - add focused dark-mode smoke coverage for onboarding and seeded chat launch flows

## Task 1: Add Shared iOS Theme Tokens

**Files:**
- Create: `apps/ios/TrixiOS/Support/TrixTheme.swift`
- Test: `apps/ios/TrixiOSTests/TrixThemeTests.swift`

- [ ] **Step 1: Write the failing theme tests**

Add tests that prove the new theme surfaces resolve differently between light and dark appearance while keeping the branded accent stable.

Suggested test shape:

```swift
func testPrimarySurfaceResolvesDifferentlyForLightAndDarkMode() {
    let light = UIColor(TrixTheme.primarySurface).resolvedColor(with: .init(userInterfaceStyle: .light))
    let dark = UIColor(TrixTheme.primarySurface).resolvedColor(with: .init(userInterfaceStyle: .dark))

    XCTAssertNotEqual(light.cgColor.componentsDescription, dark.cgColor.componentsDescription)
}

func testAccentColorStaysOpaqueAcrossAppearances() {
    let light = UIColor(TrixTheme.accent).resolvedColor(with: .init(userInterfaceStyle: .light))
    let dark = UIColor(TrixTheme.accent).resolvedColor(with: .init(userInterfaceStyle: .dark))

    XCTAssertEqual(light.cgColor.alpha, 1)
    XCTAssertEqual(dark.cgColor.alpha, 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:TrixiOSTests/TrixThemeTests \
  test
```

Expected: FAIL because `TrixTheme` and its tests do not exist yet.

- [ ] **Step 3: Implement the minimal theme layer**

Add dynamic tokens for:

```swift
enum TrixTheme {
    static let accent = Color(red: 0.14, green: 0.55, blue: 0.98)
    static let primarySurface = Color(uiColor: .secondarySystemBackground)
    static let secondarySurface = Color(uiColor: .tertiarySystemBackground)
    static let elevatedFieldSurface = Color(uiColor: .systemBackground)
    static let screenBackground = Color(uiColor: .systemBackground)
    static let incomingBubble = Color(uiColor: .secondarySystemBackground)
}
```

Use trait-aware dynamic colors where a plain system semantic color is not enough for gradients or subtle strokes.

- [ ] **Step 4: Run the theme tests again**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for `TrixThemeTests`.

## Task 2: Add Dark-Mode UI-Test Launch Support

**Files:**
- Modify: `apps/ios/UITestSupport/TrixUITestSupport.swift`
- Modify: `apps/ios/TrixiOS/App/UITestLaunchConfiguration.swift`
- Modify: `apps/ios/TrixiOS/App/TrixiOSApp.swift`
- Modify: `apps/ios/TrixiOSTests/UITestLaunchConfigurationTests.swift`
- Modify: `apps/ios/TrixiOSUITests/TrixUITestApp.swift`

- [ ] **Step 1: Write the failing launch-configuration test**

Add a unit test that expects a dark-mode override to parse from UI-test environment:

```swift
func testMakeParsesRequestedInterfaceStyle() {
    let configuration = UITestLaunchConfiguration.make(
        arguments: [TrixUITestLaunchArgument.enableUITesting],
        environment: [TrixUITestLaunchEnvironment.interfaceStyle: "dark"]
    )

    XCTAssertEqual(configuration.interfaceStyle, .dark)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:TrixiOSTests/UITestLaunchConfigurationTests \
  test
```

Expected: FAIL because the configuration does not yet expose an interface-style override.

- [ ] **Step 3: Implement the launch-contract changes**

Add:

```swift
enum TrixUITestInterfaceStyle: String, Codable {
    case light
    case dark
}
```

and a new environment key such as:

```swift
static let interfaceStyle = "TRIX_UI_TEST_INTERFACE_STYLE"
```

Parse the new value in `UITestLaunchConfiguration`, then apply it during app launch with:

```swift
UIView.appearance().overrideUserInterfaceStyle = .dark
```

or the equivalent mapped style when UI testing requests it.

- [ ] **Step 4: Re-run the launch-configuration test**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for `UITestLaunchConfigurationTests`.

## Task 3: Migrate Onboarding And Consumer Chat To The Shared Theme

**Files:**
- Modify: `apps/ios/TrixiOS/Features/Onboarding/CreateAccountView.swift`
- Modify: `apps/ios/TrixiOS/Features/Onboarding/PendingApprovalView.swift`
- Modify: `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
- Modify: `apps/ios/TrixiOS/Features/Home/DashboardView.swift`

- [ ] **Step 1: Add a focused dark-mode smoke test**

Add a UI smoke scenario that launches onboarding in forced dark mode and a seeded DM flow in forced dark mode:

```swift
func testCreateAccountFlowShowsDashboardInDarkMode() async throws
func testSeededDMDetailShowsTimelineInDarkMode() async throws
```

Use the existing launch helper plus the new interface-style override so the test path exercises the same production views under dark appearance.

- [ ] **Step 2: Run the new UI smoke test to verify the path is wired**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:TrixiOSUITests/TrixiOSSmokeUITests \
  test
```

Expected: the new dark-mode smoke path fails initially until the launch helper and updated views are in place, or fails to compile until the new launch helper API exists.

- [ ] **Step 3: Migrate the affected SwiftUI surfaces**

Replace view-local light-only colors with theme tokens for:

- onboarding gradients
- onboarding cards and text-field surfaces
- pending-approval cards
- chat backdrop glow layers
- incoming bubbles
- day separators
- system event cards
- composer surfaces
- attachment preview trays
- any obvious shared `DashboardView` surface hardcode touched by the same theme language

Keep structure, copy, and brand accent intact.

- [ ] **Step 4: Re-run the dark-mode UI smoke tests**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for the targeted onboarding/chat UI smoke coverage.

## Task 4: Final Verification

**Files:**
- Inspect only

- [ ] **Step 1: Run focused unit verification**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:TrixiOSTests/TrixThemeTests \
  -only-testing:TrixiOSTests/UITestLaunchConfigurationTests \
  test
```

Expected: PASS for the theme and launch-contract tests.

- [ ] **Step 2: Run focused UI verification**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:TrixiOSUITests/TrixiOSSmokeUITests/testCreateAccountFlowShowsDashboardInDarkMode \
  -only-testing:TrixiOSUITests/TrixiOSSmokeUITests/testSeededDMDetailShowsTimelineInDarkMode \
  test
```

Expected: PASS for the dark-mode onboarding and chat smoke flows.

- [ ] **Step 3: Read diagnostics for edited files**

Inspect IDE diagnostics for the changed iOS files and fix any introduced issues.

- [ ] **Step 4: Manually inspect light and dark appearance**

Verify:

- onboarding cards remain readable in light and dark mode
- pending-approval panels maintain clear hierarchy in dark mode
- incoming and outgoing chat bubbles remain distinguishable
- system event cards and day separators remain legible
- composer and attachment tray surfaces do not flash bright white in dark mode
