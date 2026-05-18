# Task: Local App Lock With System Authentication

You are the next coding agent working in the Trix repo. Add an optional local
app lock for iOS and macOS using Apple's LocalAuthentication framework.

## Current Context

Relevant files:

- `apple/project.yml`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Views/TrixRootView.swift`
- `apple/Sources/iOS/TrixiOSApp.swift`
- `apple/Sources/iOS/TrixiOSAppDelegate.swift`
- `apple/Sources/macOS/TrixMacApp.swift`
- `apple/Sources/macOS/TrixMacRootView.swift`
- `apple/Sources/Shared/Views/TrixRoomListView.swift`
- `apple/Sources/Shared/Services/TrixSessionKeychainStore.swift`
- `docs/security.md`

The app already observes `scenePhase` for active/inactive push behavior. Session
and OMEMO state live in Keychain, while the decrypted timeline cache uses an
app-local Keychain-held cache key.

## Goal

Users can enable an app lock. When the app returns from background or after a
configured idle interval, Trix hides chat content and requires system
authentication:

- iOS: Face ID, Touch ID, or device passcode via `deviceOwnerAuthentication`;
- macOS: Touch ID, Apple Watch, or user password via `deviceOwnerAuthentication`.

## Non-Goals

- Do not build a custom passcode keypad in this slice.
- Do not claim this protects against malware or a fully compromised endpoint.
- Do not block APNs generic background sync solely because the visual app lock
  is active.
- Do not delete sessions on failed local auth unless the user explicitly logs out
  or a later product decision adds wipe policy.

## Implementation Plan

1. Add a shared `TrixAppLockService` around `LAContext`:
   - `canEvaluatePolicy(.deviceOwnerAuthentication)`;
   - `authenticate(reason:)`;
   - current biometry type for settings labels.
2. Add persistent app-lock settings:
   - enabled/disabled;
   - lock on background;
   - optional idle timeout;
   - keep settings in app storage or Keychain depending on sensitivity.
3. Add `NSFaceIDUsageDescription` to the generated iOS Info.plist settings in
   `apple/project.yml`.
4. Add a shared app-lock view model:
   - locked/unlocked state;
   - authentication in flight;
   - last unlock time;
   - lock on scene inactive/background according to settings;
   - lock immediately through a manual action.
5. Add a lock screen overlay at the root level:
   - hide room list, timeline, previews, and settings content while locked;
   - show only generic account/app state;
   - require system auth to unlock.
6. Update iOS and macOS Settings:
   - toggle app lock;
   - show whether system auth is available;
   - manual "Lock Now" action.
7. Keep background behavior safe:
   - APNs can still trigger generic sync;
   - local notifications remain generic and plaintext-free;
   - no decrypted content is shown while locked.
8. Add unit tests for settings state and view-model transitions where practical.

## Acceptance Criteria

- App lock can be enabled and disabled.
- Returning from background locks visible chat content when configured.
- Unlock uses system authentication and never receives biometric data directly.
- macOS uses the same root-level content hiding behavior as iOS.
- Push handling remains generic and does not expose decrypted content
  while the app is locked.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Manual signed-device verification is required for real Face ID/Touch ID behavior;
simulators can only prove fallback UI and state transitions.
