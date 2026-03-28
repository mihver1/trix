# macOS TestFlight Archive Design

## Summary

This design prepares `apps/macos` for App Store Connect / TestFlight distribution by moving the macOS app target into an App Store-compatible runtime and signing posture, then adding a repeatable CLI archive/export flow.

The work intentionally targets the App Store Connect path only:

- signed `xcarchive`
- `app-store-connect` export/upload flow
- sandbox-compatible runtime behavior for file import, local storage, and network access

It does not attempt to revive the old direct-distribution path based on `Developer ID`, `notarytool`, or `dmg`.

## Context

The repository already has the right foundation for archive creation:

- a committed `apps/macos/TrixMac.xcodeproj`
- automatic signing in the app target
- a prebuild script that produces a universal `libtrix_core.a`
- successful local `xcodebuild archive` runs in unsigned mode

However, the current project is not ready for App Store Connect distribution because it is missing several App Store-facing requirements:

- no committed macOS app entitlements file
- no enabled App Sandbox entitlement
- no explicit app category
- no repeatable script for `archive` plus `exportArchive`
- attachment import currently relies on raw file URLs from `.fileImporter`, which is fragile once the app is sandboxed

## Goals

- Produce a locally reproducible `xcarchive` for the `TrixMac` scheme.
- Support `xcodebuild -exportArchive` using the `app-store-connect` method.
- Keep automatic signing with the existing Apple distribution identity / Xcode-managed profiles.
- Make the runtime compatible with sandboxed TestFlight execution.
- Preserve the current local storage model under app-controlled directories and keep network access working.

## Non-Goals

- No `dmg`, notarization, or direct-download distribution work.
- No App Store Connect metadata automation beyond archive/export preparation.
- No large refactor of the existing macOS app architecture.
- No expansion of entitlements beyond the minimum needed for current behavior.

## Decision Summary

The chosen direction is:

1. Keep Xcode automatic signing for the archive/export path instead of introducing manual certificate/profile plumbing.
2. Add a committed app entitlements file with the minimum sandbox permissions required by the current client:
   - `com.apple.security.app-sandbox`
   - `com.apple.security.network.client`
   - `com.apple.security.files.user-selected.read-only`
3. Add an explicit `LSApplicationCategoryType` so the archive stops warning about a missing app category.
4. Add a dedicated archive/export script for the App Store Connect path instead of reusing the beta `dmg` script.
5. Make attachment import sandbox-safe by copying user-selected files into app-controlled storage immediately after import, so later async send logic does not depend on long-lived access to external URLs.
6. Verify the result with `xcodebuild archive` and `xcodebuild -exportArchive`.

## Architecture

### 1. App Store-Compatible Signing Surface

`TrixMac` should keep `CODE_SIGN_STYLE = Automatic`, but it needs a real entitlements file referenced from the app target. The entitlements file must represent the actual runtime contract of the app under TestFlight:

- sandbox enabled
- outgoing network connections enabled
- read-only access to files explicitly selected by the user

No custom keychain-sharing entitlement is required for the current `SecItem` usage. Keychain items remain scoped through the app identity/service naming already present in app code.

### 2. Sandbox-Compatible Runtime Behavior

The app currently imports attachments from `.fileImporter` and stores the raw file URL in `AttachmentDraft`. That is acceptable for a non-sandboxed local build, but it becomes risky once the app is distributed through TestFlight because the selected file URL may no longer be readable later during async send flow.

The safer design is:

1. resolve the selected file URL
2. read/copy the selected file immediately
3. place the copied file under app-controlled storage
4. use the copied local URL for later preview/send work

This keeps the send path independent from any temporary security-scoped access window and aligns with the existing app pattern of storing state under app-owned directories.

### 3. Archive And Export Flow

Add a dedicated archive script under `apps/macos/scripts/` that:

1. builds the universal Rust archive through the existing prebuild flow
2. runs `xcodebuild archive` for `TrixMac`
3. optionally runs `xcodebuild -exportArchive` with `method = app-store-connect`
4. supports both:
   - local export for later upload
   - direct upload destination when credentials/signing allow it

The export configuration should live in a committed plist so the distribution method is stable and inspectable.

### 4. Validation Surface

The end state is considered correct when:

- `xcodebuild archive` succeeds with signing enabled
- the archived app has the expected sandbox entitlements
- `xcodebuild -exportArchive` succeeds for the App Store Connect method
- the app still launches locally after the sandbox changes
- attachment import still works using copied app-owned files

## Risks And Mitigations

### Risk: attachment import breaks after sandboxing

Mitigation: copy imported files immediately into app-owned storage and test the import/send path locally.

### Risk: App Store Connect rejects missing metadata or category

Mitigation: set `LSApplicationCategoryType` during this change instead of leaving archive warnings unresolved.

### Risk: automatic signing behaves differently between local machines

Mitigation: keep the script Xcode-native, rely on `-allowProvisioningUpdates`, and avoid manual provisioning profile wiring unless Apple forces it.

## Validation Plan

- Run `xcodebuild archive` for `apps/macos/TrixMac.xcodeproj`
- Run `xcodebuild -exportArchive` with an App Store Connect export options plist
- Inspect app entitlements with `codesign -d --entitlements :-`
- Sanity-check attachment import after sandbox changes
- Check recently edited files for lints/diagnostics before calling the work complete
