# Cross-Client Interoperability Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local-first interoperability harness that exercises iOS, macOS, and Android against one live backend through seeded restore flows and cross-client DM/group/device-approval scenarios.

**Architecture:** Add a repo-level Python orchestrator under `scripts/interop/` that executes semantic scenario steps, performs preflight checks, and records structured evidence. Each platform gets a small interop driver seam that accepts structured actions, uses app-owned test support where possible, and proves user-visible state at selected checkpoints without requiring one always-on tri-UI rig.

**Tech Stack:** Python 3 standard library, shell integration via `scripts/client-smoke-harness.sh`, XCTest/XCUITest for iOS and macOS, Android instrumentation + `adb`, Genymotion, Swift, Kotlin, existing seeded UI-test launch contracts.

---

## File Structure

### Existing files to modify

- `scripts/client-smoke-harness.sh`
  - Add `interop-seeded`, `interop-cross`, and `interop-full` suites plus Genymotion and backend preflight.
- `docs/client-smoke-harness.md`
  - Document the new interop suites and their runtime requirements.
- `apps/ios/UITestSupport/TrixUITestSupport.swift`
  - Extend shared iOS test support with interop action/result types or a sibling import path.
- `apps/ios/TrixiOS/App/UITestLaunchConfiguration.swift`
  - Accept interop action/env inputs and launch-mode distinctions needed by the driver.
- `apps/ios/TrixiOSUITests/TrixUITestApp.swift`
  - Add a command-oriented iOS interop launcher path.
- `apps/ios/project.yml`
  - Include any new interop test support/app files and regenerate the committed Xcode project.
- `apps/ios/TrixiOS.xcodeproj/project.pbxproj`
- `apps/ios/TrixiOS.xcodeproj/xcshareddata/xcschemes/TrixiOS.xcscheme`
- `apps/macos/Sources/TrixMac/Support/MacUITestSupport.swift`
  - Extend or complement with interop action/result support.
- `apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift`
  - Accept interop action/env inputs.
- `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
  - Add a command-oriented macOS interop launcher path.
- `apps/macos/project.yml`
  - Include new interop files and keep the Xcode project in sync.
- `apps/macos/TrixMac.xcodeproj/project.pbxproj`
- `apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme`
- `apps/android/app/build.gradle.kts`
  - Add interop debug/instrumentation support and an explicit Genymotion-friendly base-URL path.
- `apps/android/app/src/main/java/chat/trix/android/MainActivity.kt`
  - Pass launch intent/state needed by the Android interop bridge.
- `apps/android/app/src/main/java/chat/trix/android/ui/TrixApp.kt`
  - Execute interop actions and emit results/evidence from the app layer.
- `apps/android/README.md`
  - Clarify Genymotion-only local interop wiring and host URL expectations.

### New files to create

- `scripts/__init__.py`
- `scripts/interop/__init__.py`
- `scripts/interop/cli.py`
  - Main entrypoint for interop suites and ad hoc scenario runs.
- `scripts/interop/contracts.py`
  - Shared Python dataclasses/enums for actions, steps, evidence, capabilities, and suite config.
- `scripts/interop/evidence.py`
  - Structured artifact writer for `scenario.json`, `step-results.json`, and logs.
- `scripts/interop/preflight.py`
  - Backend, simulator, macOS, and Genymotion preflight checks.
- `scripts/interop/runner.py`
  - Sequential scenario runner that binds participants to steps and records evidence.
- `scripts/interop/scenarios.py`
  - `interop-seeded`, `interop-cross`, and `interop-full` scenario definitions.
- `scripts/interop/platforms/__init__.py`
- `scripts/interop/platforms/base.py`
  - Common driver protocol and command-result helpers.
- `scripts/interop/platforms/ios_driver.py`
  - Host-side wrapper that invokes iOS interop driver tests and translates JSON in/out.
- `scripts/interop/platforms/macos_driver.py`
  - Host-side wrapper that invokes macOS interop driver tests and translates JSON in/out.
- `scripts/interop/platforms/android_driver.py`
  - Host-side wrapper that invokes Android instrumentation and enforces Genymotion-only selection.
- `scripts/interop/tests/__init__.py`
- `scripts/interop/tests/test_contracts.py`
- `scripts/interop/tests/test_preflight.py`
- `scripts/interop/tests/test_runner.py`
- `scripts/interop/tests/test_scenarios.py`
- `scripts/interop/tests/test_seeded_suite.py`
- `scripts/interop/tests/test_cross_suite.py`
- `docs/cross-client-interop-harness.md`
  - Runbook for local setup, Genymotion requirements, evidence output, and troubleshooting.
- `apps/ios/UITestSupport/TrixInteropSupport.swift`
  - Shared interop action/result models for iOS app + UI-test target.
- `apps/ios/TrixiOS/App/TrixInteropActionBridge.swift`
  - App-side executor for semantic interop actions.
- `apps/ios/TrixiOSTests/TrixInteropActionBridgeTests.swift`
  - Narrow unit tests for iOS interop action parsing and local bridge behavior.
- `apps/ios/TrixiOSUITests/TrixiOSInteropDriver.swift`
  - UI-test-side iOS driver helper that launches the app with one action request.
- `apps/ios/TrixiOSUITests/TrixiOSInteropDriverTests.swift`
  - iOS driver smoke tests for seeded bootstrap and DM delivery actions.
- `apps/macos/Sources/TrixMac/Support/TrixMacInteropSupport.swift`
  - Shared interop action/result models for macOS app + UI-test target.
- `apps/macos/Sources/TrixMac/App/TrixMacInteropActionBridge.swift`
  - App-side executor for semantic interop actions.
- `apps/macos/Tests/TrixMacTests/TrixMacInteropActionBridgeTests.swift`
  - Narrow unit tests for macOS interop action parsing and local bridge behavior.
- `apps/macos/TrixMacUITests/TrixMacInteropDriver.swift`
  - UI-test-side macOS driver helper that launches the app with one action request.
- `apps/macos/TrixMacUITests/TrixMacInteropDriverTests.swift`
  - macOS driver smoke tests for seeded bootstrap and DM delivery actions.
- `apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropSupport.kt`
  - Android interop action/result models and debug-only helpers.
- `apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropActionBridge.kt`
  - App-side semantic action executor for Android.
- `apps/android/app/src/test/java/chat/trix/android/interop/AndroidInteropConfigTest.kt`
  - JVM tests for action parsing, Genymotion base-URL handling, and config fallbacks.
- `apps/android/app/src/androidTest/java/chat/trix/android/interop/AndroidInteropDriverInstrumentedTest.kt`
  - Instrumented Android driver smoke tests and action runner entrypoint.

### Responsibility boundaries

- Keep all host-side orchestration in `scripts/interop/`; do not embed the overall harness inside any client app.
- Keep platform action/result schemas next to each platform’s existing UI-test support so app target and driver target can share them.
- Use app-owned semantic bridges for most actions; keep UI-specific proof points in the existing UI test layers.
- Keep Android interop code in `src/debug/` or `src/androidTest/` so the release app is not forced to ship test-only bridges.
- Treat `project.yml` as the source of truth for XcodeGen outputs; never hand-edit generated Xcode project files without regenerating.

## Task 1: Orchestrator Contracts, Evidence, And Genymotion Preflight

**Files:**
- Create: `scripts/__init__.py`
- Create: `scripts/interop/__init__.py`
- Create: `scripts/interop/contracts.py`
- Create: `scripts/interop/evidence.py`
- Create: `scripts/interop/preflight.py`
- Create: `scripts/interop/tests/__init__.py`
- Create: `scripts/interop/tests/test_contracts.py`
- Create: `scripts/interop/tests/test_preflight.py`

- [ ] **Step 1: Write the failing Python tests**

```python
from scripts.interop.contracts import InteropAction, StepParticipantBinding
from scripts.interop.preflight import select_genymotion_serial


def test_action_round_trip_preserves_actor_and_targets():
    action = InteropAction(
        name="sendText",
        actor="ios-a",
        target_clients=["android-b"],
        asserting_clients=["macos-c"],
    )
    payload = action.to_json_dict()
    restored = InteropAction.from_json_dict(payload)
    assert restored == action


def test_select_genymotion_serial_rejects_non_genymobile_targets():
    devices = [
        {"serial": "emulator-5554", "manufacturer": "Google"},
    ]
    try:
        select_genymotion_serial(devices, explicit_serial=None)
    except ValueError as error:
        assert "Genymotion" in str(error)
    else:
        raise AssertionError("Expected non-Genymotion devices to be rejected.")


def test_generated_scenario_label_is_unique_per_run():
    from scripts.interop.contracts import build_scenario_label

    first = build_scenario_label("interop-cross")
    second = build_scenario_label("interop-cross")
    assert first != second


def test_android_serial_override_selects_candidate_to_validate_first():
    from scripts.interop.preflight import resolve_android_interop_serial

    devices = [
        {"serial": "10.0.0.15:5555", "manufacturer": "Genymobile"},
        {"serial": "192.168.56.101:5555", "manufacturer": "Genymobile"},
    ]
    selected = resolve_android_interop_serial(
        devices,
        explicit_serial="10.0.0.15:5555",
    )
    assert selected == "10.0.0.15:5555"


def test_android_serial_override_still_requires_live_genymotion_device():
    from scripts.interop.preflight import resolve_android_interop_serial

    devices = [
        {"serial": "emulator-5554", "manufacturer": "Google"},
    ]
    try:
        resolve_android_interop_serial(
            devices,
            explicit_serial="emulator-5554",
        )
    except ValueError as error:
        assert "Genymotion" in str(error)
    else:
        raise AssertionError("Expected explicit serial to still require Genymotion validation.")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_contracts scripts.interop.tests.test_preflight -v
```

Expected: FAIL with import errors for missing `scripts.interop` modules or missing contract/preflight helpers.

- [ ] **Step 3: Write the minimal implementation**

Add small Python units:

- `contracts.py`
  - `InteropAction`
  - `ScenarioStep`
  - `DriverCapability`
  - `DriverResult`
  - `build_scenario_label()`
  - per-step evidence payload fields:
    - resolved ids
    - expected vs observed state
    - timeout/retry metadata
    - per-step state snapshot metadata
  - JSON serialization helpers
- `evidence.py`
  - writes `scenario.json`
  - appends `step-results.json`
  - records per-step resolved-id/state-snapshot fields
  - records failure-only screenshot references for UI-backed steps
- `preflight.py`
  - backend health probe
  - Genymotion-only serial selection based on `ro.product.manufacturer`
  - iOS simulator availability check
  - macOS UI-test runtime availability check
  - `TRIX_ANDROID_INTEROP_SERIAL` candidate selection with live Genymotion validation before exact-single-match fallback

Genymotion selection contract should be explicit:

```python
def resolve_android_interop_serial(devices, explicit_serial):
    ...
    if explicit_serial is not None:
        candidate = next((d for d in devices if d["serial"] == explicit_serial), None)
        if candidate is None or candidate["manufacturer"] != "Genymobile":
            raise ValueError("TRIX_ANDROID_INTEROP_SERIAL must point at a live Genymotion device.")
        return explicit_serial
    eligible = [d for d in devices if d["manufacturer"] == "Genymobile"]
    if len(eligible) != 1:
        raise ValueError("Expected exactly one eligible Genymotion device.")
    return eligible[0]["serial"]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `python3 -m unittest ...` command from Step 2.

Expected: PASS for contract round-trip and Genymotion-only preflight tests.

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/__init__.py \
  scripts/interop/__init__.py \
  scripts/interop/contracts.py \
  scripts/interop/evidence.py \
  scripts/interop/preflight.py \
  scripts/interop/tests/__init__.py \
  scripts/interop/tests/test_contracts.py \
  scripts/interop/tests/test_preflight.py
git commit -m "test: add interop harness foundations"
```

## Task 2: Scenario DSL And Sequential Runner

**Files:**
- Create: `scripts/interop/cli.py`
- Create: `scripts/interop/runner.py`
- Create: `scripts/interop/scenarios.py`
- Create: `scripts/interop/platforms/__init__.py`
- Create: `scripts/interop/platforms/base.py`
- Create: `scripts/interop/platforms/ios_driver.py`
- Create: `scripts/interop/platforms/macos_driver.py`
- Create: `scripts/interop/platforms/android_driver.py`
- Create: `scripts/interop/tests/test_runner.py`
- Create: `scripts/interop/tests/test_scenarios.py`

- [ ] **Step 1: Write the failing scenario/runner tests**

```python
from scripts.interop.runner import run_steps_with_driver_map
from scripts.interop.scenarios import build_interop_seeded_suite


def test_seeded_suite_declares_per_step_participants():
    suite = build_interop_seeded_suite()
    assert suite.name == "interop-seeded"
    assert any(step.actor == "ios-owner" for step in suite.steps)
    assert any(step.asserting_clients for step in suite.steps)


def test_runner_executes_steps_sequentially():
    calls = []

    class FakeDriver:
        def __init__(self):
            self.cleaned = False

        def perform(self, action):
            calls.append(action.name)
            return {"ok": True}

        def cleanup(self):
            self.cleaned = True

    suite = build_interop_seeded_suite()
    trimmed = suite.with_steps(suite.steps[:2])
    run_steps_with_driver_map(trimmed, {"ios-owner": FakeDriver()})
    assert calls == [trimmed.steps[0].action.name, trimmed.steps[1].action.name]


def test_interop_full_defaults_to_seeded_plus_cross_composition():
    from scripts.interop.scenarios import build_interop_full_suite
    suite = build_interop_full_suite()
    assert suite.name == "interop-full"
    assert suite.includes_suites == ["interop-seeded", "interop-cross"]


def test_runner_passes_driver_artifact_paths_into_evidence():
    from scripts.interop.runner import run_steps_with_driver_map
    from scripts.interop.scenarios import build_interop_seeded_suite

    artifacts = {"log_path": "/tmp/ios-driver.log", "screenshot_path": None}

    class FakeDriver:
        def perform(self, action):
            return {"ok": True, "artifacts": artifacts}

        def cleanup(self):
            return None

    suite = build_interop_seeded_suite().with_steps(build_interop_seeded_suite().steps[:1])
    result = run_steps_with_driver_map(suite, {"ios-owner": FakeDriver()})
    assert result.step_results[0].artifacts["log_path"] == "/tmp/ios-driver.log"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_runner scripts.interop.tests.test_scenarios -v
```

Expected: FAIL because the runner, base driver protocol, and suite builders do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create:

- `cli.py`
  - suite selection
  - unique `scenarioLabel` assignment per run
  - dispatch to the sequential runner
- `platforms/base.py`
  - a small `InteropDriver` protocol with `perform(action)`, `cleanup()`, and `shutdown()`
- `platforms/__init__.py`
- `platforms/ios_driver.py`
- `platforms/macos_driver.py`
- `platforms/android_driver.py`
  - start as stub host-side wrappers that raise `NotImplementedError` until Tasks 3-5 fill them in
- `scenarios.py`
  - `build_interop_seeded_suite()`
  - `build_interop_cross_suite()`
  - `build_interop_full_suite()`
  - step-based scenario definitions with `actor`, optional targets, optional asserting clients
- `runner.py`
  - sequential execution only
  - evidence write on each step
  - capability gating before scenario start
  - per-run cleanup hooks for drivers when reset is requested
  - pass per-driver artifact paths (logs, transcripts, failure screenshots) into `evidence.py`

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `python3 -m unittest ...` command from Step 2.

Expected: PASS for scenario declaration and sequential execution tests.

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/interop/cli.py \
  scripts/interop/runner.py \
  scripts/interop/scenarios.py \
  scripts/interop/platforms/__init__.py \
  scripts/interop/platforms/base.py \
  scripts/interop/platforms/ios_driver.py \
  scripts/interop/platforms/macos_driver.py \
  scripts/interop/platforms/android_driver.py \
  scripts/interop/tests/test_runner.py \
  scripts/interop/tests/test_scenarios.py
git commit -m "test: add interop scenario runner"
```

## Task 3: iOS Interop Action Bridge And Driver Smoke

**Files:**
- Create: `apps/ios/UITestSupport/TrixInteropSupport.swift`
- Create: `apps/ios/TrixiOS/App/TrixInteropActionBridge.swift`
- Create: `apps/ios/TrixiOSTests/TrixInteropActionBridgeTests.swift`
- Create: `apps/ios/TrixiOSUITests/TrixiOSInteropDriver.swift`
- Create: `apps/ios/TrixiOSUITests/TrixiOSInteropDriverTests.swift`
- Modify: `apps/ios/TrixiOS/App/UITestLaunchConfiguration.swift`
- Modify: `apps/ios/TrixiOSUITests/TrixUITestApp.swift`
- Modify: `apps/ios/project.yml`
- Generate: `apps/ios/TrixiOS.xcodeproj/project.pbxproj`
- Generate: `apps/ios/TrixiOS.xcodeproj/xcshareddata/xcschemes/TrixiOS.xcscheme`

- [ ] **Step 1: Write the failing iOS tests**

```swift
import XCTest
@testable import Trix

final class TrixInteropActionBridgeTests: XCTestCase {
    func testActionDecoderParsesSendTextRequest() throws {
        let action = try TrixInteropAction.decode(
            """
            {"name":"sendText","actor":"ios-a","chatAlias":"dm-a-b","text":"hello"}
            """
        )
        XCTAssertEqual(action.name, .sendText)
        XCTAssertEqual(action.actor, "ios-a")
    }
}
```

```swift
import XCTest

final class TrixiOSInteropDriverTests: XCTestCase {
    func testSeededBootstrapAction() async throws {
        let result = try await TrixiOSInteropDriver.run(
            action: .bootstrapApprovedAccount,
            baseURL: TrixUITestApp.configuredBaseURL()
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertNotNil(result.accountId)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TrixiOSTests/TrixInteropActionBridgeTests \
  -only-testing:TrixiOSUITests/TrixiOSInteropDriverTests/testSeededBootstrapAction \
  test
```

Expected: FAIL because the interop support/bridge/driver files do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Implement the iOS path by extending the existing seeded UI-test contour:

- `TrixInteropSupport.swift`
  - request/result models shared by app + UI test target
- `UITestLaunchConfiguration.swift`
  - parse one interop action input and result output path
- `TrixInteropActionBridge.swift`
  - execute semantic actions by calling existing model/bridge APIs
- `TrixiOSInteropDriver.swift`
  - launch app with one action and read back result JSON
  - persist xcodebuild/test command output or action transcript path for every action
  - capture screenshot file paths on failed UI-backed assertions and return them in the driver result

Regenerate the project:

```bash
cd apps/ios && xcodegen generate
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command from Step 2.

Expected: PASS for iOS interop action decoding and driver smoke.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/ios/UITestSupport/TrixInteropSupport.swift \
  apps/ios/TrixiOS/App/TrixInteropActionBridge.swift \
  apps/ios/TrixiOSTests/TrixInteropActionBridgeTests.swift \
  apps/ios/TrixiOSUITests/TrixiOSInteropDriver.swift \
  apps/ios/TrixiOSUITests/TrixiOSInteropDriverTests.swift \
  apps/ios/TrixiOS/App/UITestLaunchConfiguration.swift \
  apps/ios/TrixiOSUITests/TrixUITestApp.swift \
  apps/ios/project.yml \
  apps/ios/TrixiOS.xcodeproj/project.pbxproj \
  apps/ios/TrixiOS.xcodeproj/xcshareddata/xcschemes/TrixiOS.xcscheme
git commit -m "feat: add ios interop driver seam"
```

## Task 4: macOS Interop Action Bridge And Driver Smoke

**Files:**
- Create: `apps/macos/Sources/TrixMac/Support/TrixMacInteropSupport.swift`
- Create: `apps/macos/Sources/TrixMac/App/TrixMacInteropActionBridge.swift`
- Create: `apps/macos/Tests/TrixMacTests/TrixMacInteropActionBridgeTests.swift`
- Create: `apps/macos/TrixMacUITests/TrixMacInteropDriver.swift`
- Create: `apps/macos/TrixMacUITests/TrixMacInteropDriverTests.swift`
- Modify: `apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift`
- Modify: `apps/macos/TrixMacUITests/TrixMacUITestApp.swift`
- Modify: `apps/macos/project.yml`
- Generate: `apps/macos/TrixMac.xcodeproj/project.pbxproj`
- Generate: `apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme`

- [ ] **Step 1: Write the failing macOS tests**

```swift
import XCTest
@testable import TrixMac

final class TrixMacInteropActionBridgeTests: XCTestCase {
    func testActionDecoderParsesAwaitMessageRequest() throws {
        let action = try TrixMacInteropAction.decode(
            #"{"name":"awaitMessageVisible","actor":"macos-a","messageAlias":"msg-1"}"#
        )
        XCTAssertEqual(action.name, .awaitMessageVisible)
        XCTAssertEqual(action.actor, "macos-a")
    }
}
```

```swift
import XCTest

final class TrixMacInteropDriverTests: XCTestCase {
    func testSeededBootstrapAction() async throws {
        let result = try await TrixMacInteropDriver.run(
            action: .bootstrapApprovedAccount,
            baseURL: TrixMacUITestApp.configuredBaseURL()
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertNotNil(result.accountId)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path apps/macos --filter TrixMacInteropActionBridgeTests
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacInteropDriverTests/testSeededBootstrapAction \
  test
```

Expected: FAIL because the macOS interop support/bridge/driver files do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Implement the macOS path by extending the existing deterministic UI-test contour:

- `TrixMacInteropSupport.swift`
  - shared request/result models
- `MacUITestLaunchConfiguration.swift`
  - parse interop action input and result output path
- `TrixMacInteropActionBridge.swift`
  - execute semantic actions through existing model/bootstrap APIs
- `TrixMacInteropDriver.swift`
  - launch the app once per action and read result JSON
  - persist xcodebuild/test command output or action transcript path for every action
  - capture screenshot file paths on failed UI-backed assertions and return them in the driver result

Regenerate the project:

```bash
cd apps/macos && xcodegen generate
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `swift test` and `xcodebuild` commands from Step 2.

Expected: PASS for macOS interop action decoding and driver smoke.

- [ ] **Step 5: Commit**

```bash
git add \
  apps/macos/Sources/TrixMac/Support/TrixMacInteropSupport.swift \
  apps/macos/Sources/TrixMac/App/TrixMacInteropActionBridge.swift \
  apps/macos/Tests/TrixMacTests/TrixMacInteropActionBridgeTests.swift \
  apps/macos/TrixMacUITests/TrixMacInteropDriver.swift \
  apps/macos/TrixMacUITests/TrixMacInteropDriverTests.swift \
  apps/macos/Sources/TrixMac/App/MacUITestLaunchConfiguration.swift \
  apps/macos/TrixMacUITests/TrixMacUITestApp.swift \
  apps/macos/project.yml \
  apps/macos/TrixMac.xcodeproj/project.pbxproj \
  apps/macos/TrixMac.xcodeproj/xcshareddata/xcschemes/TrixMac.xcscheme
git commit -m "feat: add macos interop driver seam"
```

## Task 5: Android Debug Bridge, Genymotion Runtime, And Driver Smoke

**Files:**
- Create: `apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropSupport.kt`
- Create: `apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropActionBridge.kt`
- Create: `apps/android/app/src/test/java/chat/trix/android/interop/AndroidInteropConfigTest.kt`
- Create: `apps/android/app/src/androidTest/java/chat/trix/android/interop/AndroidInteropDriverInstrumentedTest.kt`
- Modify: `apps/android/app/build.gradle.kts`
- Modify: `apps/android/app/src/main/java/chat/trix/android/MainActivity.kt`
- Modify: `apps/android/app/src/main/java/chat/trix/android/ui/TrixApp.kt`
- Modify: `apps/android/README.md`

- [ ] **Step 1: Write the failing Android tests**

```kotlin
package chat.trix.android.interop

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidInteropConfigTest {
    @Test
    fun genymotionBaseUrlDefaultsToHostLoopback() {
        val config = AndroidInteropConfig.forGenymotion(
            hostBaseUrl = "http://127.0.0.1:8080",
        )
        assertEquals("http://10.0.3.2:8080", config.deviceReachableBaseUrl)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
./apps/android/gradlew -p apps/android testDebugUnitTest -PtrixSkipAndroidNdkBuild=true --tests chat.trix.android.interop.AndroidInteropConfigTest
./apps/android/gradlew -p apps/android connectedDebugAndroidTest \
  -PtrixBaseUrl=http://10.0.3.2:8080 \
  -Pandroid.testInstrumentationRunnerArguments.class=chat.trix.android.interop.AndroidInteropDriverInstrumentedTest
```

Expected: FAIL because the Android interop bridge/config/instrumented driver do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Implement the Android path with debug-only seams:

- `AndroidInteropSupport.kt`
  - action/result models
- `AndroidInteropActionBridge.kt`
  - executes semantic actions inside the debug app
- `TrixApp.kt` / `MainActivity.kt`
  - accept interop driver requests and publish results
- `build.gradle.kts`
  - add runner arguments and explicit interop base-URL path

The Android driver result must include:

- instrumentation/adb transcript path for each action
- screenshot artifact paths for failed UI-backed steps

Keep the normal Android app default unchanged if possible; interop should explicitly set the Genymotion-reachable URL rather than mutating unrelated AVD defaults.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same Gradle commands from Step 2.

Expected:

- JVM config test PASS
- instrumented driver smoke PASS on a live Genymotion device

- [ ] **Step 5: Commit**

```bash
git add \
  apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropSupport.kt \
  apps/android/app/src/debug/java/chat/trix/android/interop/AndroidInteropActionBridge.kt \
  apps/android/app/src/test/java/chat/trix/android/interop/AndroidInteropConfigTest.kt \
  apps/android/app/src/androidTest/java/chat/trix/android/interop/AndroidInteropDriverInstrumentedTest.kt \
  apps/android/app/build.gradle.kts \
  apps/android/app/src/main/java/chat/trix/android/MainActivity.kt \
  apps/android/app/src/main/java/chat/trix/android/ui/TrixApp.kt \
  apps/android/README.md
git commit -m "feat: add android interop driver seam"
```

## Task 6: `interop-seeded` Suite Across All Three Clients

**Files:**
- Modify: `scripts/interop/cli.py`
- Create: `scripts/interop/tests/test_seeded_suite.py`
- Modify: `scripts/interop/scenarios.py`
- Modify: `scripts/interop/runner.py`
- Modify: `scripts/interop/platforms/ios_driver.py`
- Modify: `scripts/interop/platforms/macos_driver.py`
- Modify: `scripts/interop/platforms/android_driver.py`

- [ ] **Step 1: Write the failing seeded-suite tests**

```python
from scripts.interop.scenarios import build_interop_seeded_suite


def test_seeded_suite_uses_shared_server_fixture_plus_per_client_local_seeds():
    suite = build_interop_seeded_suite()
    assert any(step.action.name == "bootstrapAccount" for step in suite.steps)
    assert any(step.action.name == "restoreSession" for step in suite.steps)
    assert any("pending" in step.id for step in suite.steps)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_seeded_suite -v
```

Expected: FAIL because `interop-seeded` is still only a placeholder and the platform drivers do not expose the full seed/restore set yet.

- [ ] **Step 3: Write the minimal implementation**

Implement:

- `cli.py`
  - `run --suite interop-seeded`
- `scenarios.py`
  - concrete `interop-seeded` steps for approved, pending, and restore bundles
- platform drivers
  - enough actions to bootstrap local state, relaunch, and snapshot visible DM/group state

The seeded suite must create one shared server-side topology while still producing per-client local seeds.
The runner must propagate a unique `scenarioLabel` into every driver invocation and call driver cleanup hooks when the suite or step requests reset.

- [ ] **Step 4: Run the tests and real suite to verify it passes**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_seeded_suite -v
python3 -m scripts.interop.cli run \
  --suite interop-seeded \
  --base-url http://127.0.0.1:8080 \
  --ios-destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected:

- unit tests PASS
- `interop-seeded` completes and writes structured evidence

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/interop/cli.py \
  scripts/interop/tests/test_seeded_suite.py \
  scripts/interop/scenarios.py \
  scripts/interop/runner.py \
  scripts/interop/platforms/ios_driver.py \
  scripts/interop/platforms/macos_driver.py \
  scripts/interop/platforms/android_driver.py
git commit -m "feat: add seeded interop suite"
```

## Task 7: `interop-cross` DM And Group Rings

**Files:**
- Create: `scripts/interop/tests/test_cross_suite.py`
- Modify: `scripts/interop/scenarios.py`
- Modify: `scripts/interop/runner.py`
- Modify: `scripts/interop/platforms/ios_driver.py`
- Modify: `scripts/interop/platforms/macos_driver.py`
- Modify: `scripts/interop/platforms/android_driver.py`

- [ ] **Step 1: Write the failing DM/group suite tests**

```python
from scripts.interop.scenarios import build_interop_cross_suite


def test_cross_suite_contains_dm_ring_for_all_three_clients():
    suite = build_interop_cross_suite()
    ids = [scenario.id for scenario in suite.scenarios]
    assert "dm-ring-android-ios-macos" in ids
    assert "dm-ring-ios-macos-android" in ids
    assert "dm-ring-macos-android-ios" in ids


def test_cross_suite_contains_group_creation_and_reply_ring():
    suite = build_interop_cross_suite()
    ids = [scenario.id for scenario in suite.scenarios]
    assert "group-ring-android-ios-macos" in ids
    assert "group-ring-ios-macos-android" in ids
    assert "group-ring-macos-android-ios" in ids
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_cross_suite -v
```

Expected: FAIL because the DM/group ring scenarios and required driver actions are not all implemented yet.

- [ ] **Step 3: Write the minimal implementation**

Implement:

- three DM ring scenarios
- three group create/reply ring scenarios
- platform driver support for:
  - `createDM`
  - `createGroup`
  - `sendText`
  - `awaitChatVisible`
  - `awaitMessageVisible`
  - `awaitUnreadState`
  - `markChatRead`

Each DM/group ring must include explicit row-visibility proof before timeline assertions so the interop harness continues to validate user-visible chat-list convergence, not only message ids.

- [ ] **Step 4: Run the tests and reduced live suite to verify it passes**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_cross_suite -v
python3 -m scripts.interop.cli run \
  --suite interop-cross \
  --scenario dm-ring-android-ios-macos \
  --scenario group-ring-ios-macos-android \
  --base-url http://127.0.0.1:8080 \
  --ios-destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected:

- unit tests PASS
- reduced live DM/group ring pass and write evidence

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/interop/tests/test_cross_suite.py \
  scripts/interop/scenarios.py \
  scripts/interop/runner.py \
  scripts/interop/platforms/ios_driver.py \
  scripts/interop/platforms/macos_driver.py \
  scripts/interop/platforms/android_driver.py
git commit -m "feat: add interop dm and group rings"
```

## Task 8: Restore, Canonical Device Approval, Harness Integration, And Docs

**Files:**
- Create: `docs/cross-client-interop-harness.md`
- Modify: `scripts/interop/scenarios.py`
- Modify: `scripts/interop/cli.py`
- Modify: `scripts/interop/preflight.py`
- Modify: `scripts/interop/platforms/ios_driver.py`
- Modify: `scripts/interop/platforms/macos_driver.py`
- Modify: `scripts/interop/platforms/android_driver.py`
- Modify: `scripts/client-smoke-harness.sh`
- Modify: `docs/client-smoke-harness.md`

- [ ] **Step 1: Write the failing restore/device/harness checks**

```python
from scripts.interop.preflight import AndroidRuntimeRequirementError
from scripts.interop.scenarios import build_interop_cross_suite


def test_cross_suite_contains_restore_and_device_approval_proofs():
    suite = build_interop_cross_suite()
    ids = [scenario.id for scenario in suite.scenarios]
    assert "restore-ios-target" in ids
    assert "restore-macos-target" in ids
    assert "restore-android-target" in ids
    assert "device-approval-canonical" in ids


def test_preflight_rejects_non_genymotion_serial_for_android_suite():
    try:
        raise AndroidRuntimeRequirementError("serial emulator-5554 is not a Genymotion device")
    except AndroidRuntimeRequirementError as error:
        assert "Genymotion" in str(error)


def test_device_approval_proof_requires_post_approval_observation():
    suite = build_interop_cross_suite()
    scenario = next(item for item in suite.scenarios if item.id == "device-approval-canonical")
    assert any(step.action.name == "awaitDeviceState" for step in scenario.steps)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_cross_suite scripts.interop.tests.test_preflight -v
./scripts/client-smoke-harness.sh --list-suites | rg '^interop-seeded$|^interop-cross$|^interop-full$'
```

Expected:

- Python tests FAIL because restore/device approval scenarios are missing
- harness list command FAIL because interop suites are not integrated yet

- [ ] **Step 3: Write the minimal implementation**

Implement:

- restore-target scenarios so each client serves once as restore target across the suite
- one canonical three-client device approval scenario:
  - create link intent
  - register pending device
  - approve pending device
  - reconnect after approval
  - assert updated device state from the non-approving clients
- `client-smoke-harness.sh`
  - add `interop-seeded`
  - add `interop-cross`
  - add `interop-full`
  - define `interop-full` as an opt-in composition of `interop-seeded` plus the full `interop-cross` matrix
  - start the local backend app, not just Postgres, whenever an `interop-*` suite is selected
  - fail preflight if backend, iOS simulator, macOS UI-test runtime, or required Genymotion is unavailable
  - honor `TRIX_ANDROID_INTEROP_SERIAL` before any automatic Genymotion selection
- docs:
  - `docs/cross-client-interop-harness.md`
  - `docs/client-smoke-harness.md`

Restore coverage must include the spec-required post-restore proof:

- another client sends a new event after restore
- the restored client reconciles and surfaces that event

- [ ] **Step 4: Run the tests and harness verification to verify it passes**

Run:

```bash
python3 -m unittest scripts.interop.tests.test_cross_suite scripts.interop.tests.test_preflight -v
./scripts/client-smoke-harness.sh --list-suites | rg '^interop-seeded$|^interop-cross$|^interop-full$'
./scripts/client-smoke-harness.sh --suite interop-seeded --suite interop-cross --stop-postgres
```

Expected:

- Python tests PASS
- all three interop suite names appear in `--list-suites`
- seeded and cross suites run through the smoke harness and exit 0

- [ ] **Step 5: Commit**

```bash
git add \
  docs/cross-client-interop-harness.md \
  scripts/interop/scenarios.py \
  scripts/interop/cli.py \
  scripts/interop/preflight.py \
  scripts/interop/platforms/ios_driver.py \
  scripts/interop/platforms/macos_driver.py \
  scripts/interop/platforms/android_driver.py \
  scripts/client-smoke-harness.sh \
  docs/client-smoke-harness.md
git commit -m "feat: add cross-client interop harness"
```

## Final Verification

- [ ] Run Python interop unit coverage:

```bash
python3 -m unittest discover -s scripts/interop/tests -p 'test_*.py' -v
```

Expected: PASS for contracts, preflight, scenarios, runner, seeded suite, and cross suite tests.

- [ ] Run iOS interop driver smoke:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TrixiOSUITests/TrixiOSInteropDriverTests \
  test
```

Expected: PASS for iOS interop driver smoke.

- [ ] Re-run existing iOS UI proof:

```bash
xcodebuild \
  -project apps/ios/TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TrixiOSUITests/TrixiOSSmokeUITests \
  test
```

Expected: PASS for the existing iOS UI smoke layer independently of `interop-*`.

- [ ] Run macOS interop driver smoke:

```bash
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacInteropDriverTests \
  test
```

Expected: PASS for macOS interop driver smoke.

- [ ] Re-run existing macOS UI proof:

```bash
xcodebuild \
  -project apps/macos/TrixMac.xcodeproj \
  -scheme TrixMac \
  -destination 'platform=macOS' \
  -only-testing:TrixMacUITests/TrixMacSmokeUITests \
  test
```

Expected: PASS for the existing macOS UI smoke layer independently of `interop-*`.

- [ ] Run Android interop driver smoke on Genymotion:

```bash
./apps/android/gradlew -p apps/android connectedDebugAndroidTest \
  -PtrixBaseUrl=http://10.0.3.2:8080 \
  -Pandroid.testInstrumentationRunnerArguments.class=chat.trix.android.interop.AndroidInteropDriverInstrumentedTest
```

Expected: PASS on a live Genymotion device.

- [ ] Re-run existing Android UI proof:

```bash
./apps/android/gradlew -p apps/android connectedDebugAndroidTest \
  -PtrixBaseUrl=http://10.0.3.2:8080 \
  -Pandroid.testInstrumentationRunnerArguments.class=chat.trix.android.feature.chats.ChatsScreenTest,chat.trix.android.feature.bootstrap.BootstrapScreenTest
```

Expected: PASS for the existing Android instrumentation proof layer independently of `interop-*`.

- [ ] Run smoke harness verification:

```bash
./scripts/client-smoke-harness.sh --suite interop-seeded --suite interop-cross --stop-postgres
```

Expected: PASS with backend preflight, Genymotion preflight, and structured evidence written for both suites.

- [ ] Run `@superpowers:verification-before-completion` before claiming the rollout is complete.

## Notes For Execution

- Use `@superpowers:test-driven-development` on every task, even when the task is “just harness plumbing”.
- Keep local execution sequential. Do not try to hold iOS simulator, Android runtime, and long-lived full UI driving active unless a step truly needs it.
- Keep Android interop `Genymotion-only` in wave 1. Do not silently widen support to arbitrary `adb` targets.
- Prefer explicit action/result JSON over log scraping.
- Keep platform-local UI proof suites (`ios-ui`, `macos-ui`, Android UI/instrumentation) independent; do not collapse them into the interop harness.
