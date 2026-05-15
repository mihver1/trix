# Task: Second-Device Fingerprint Smoke

You are the next coding agent working in the Trix repo. Prove that a real
two-device account exposes OMEMO device IDs and fingerprints without silently
trusting the new device.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `docs/security.md`
- `apple/README.md`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/TrixOMEMOStore.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/DeviceVerificationViewModel.swift`
- `apple/Sources/Shared/Views/TrixRoomListView.swift`

The Settings and peer-device paths are wired, and `peer-devices` /
`trust-peer` live-smoke modes exist. The checklist still requires adding a
second device and validating visible fingerprint state in a live two-device run.

## Goal

Run or add a repeatable smoke that signs into the same account from two distinct
device identities, confirms both OMEMO devices are published and visible, shows
non-empty fingerprints, and confirms the app does not silently trust the new
device.

## Non-Goals

- Do not implement SAS verification or device revocation in this task.
- Do not mark all devices trusted to make sends pass.
- Do not mutate OMEMO key material directly.
- Do not fake two devices by reusing the same Keychain-backed OMEMO state.

## Implementation Plan

1. First try a real signed-device run: two physical devices, or one physical
   device plus a separately installed signed macOS app, logged into the same
   disposable account.
2. If repeatable automation is needed, add a smoke mode such as
   `second-device-fingerprint`. Be careful with persistence:
   - `TrixOMEMOStore` keychain state is keyed by account, so two services using
     the same keychain account may share one OMEMO identity.
   - A valid automated second-device smoke must use genuinely separate OMEMO
     device state, for example two signed app installs/devices or an explicit
     smoke-only isolated store namespace.
   - Any store-namespace change must be scoped so production users keep the
     existing Keychain behavior.
3. For each device, collect only scrubbed facts: device count, distinct device
   IDs, fingerprint present/absent, active state, and local trust state. Do not
   print full fingerprints unless the user explicitly asks and the output is not
   committed.
4. Validate the UI path as well as the service path:
   - Settings/current account shows the current device.
   - Published account devices include the second device.
   - Fingerprint fields are visible.
   - Trust remains manual and not silently granted.
5. If using a peer account to inspect device discovery, run `peer-devices` from
   the peer side and confirm the same two active devices are visible.
6. Update `apple/README.md` with any new smoke mode and env variables.
7. Update `docs/mvp-checklist.md` only after the two-device proof passes.

## Acceptance Criteria

- The same account has two distinct live OMEMO device identities.
- Both device IDs are visible through the app/service path.
- Fingerprint presence is confirmed for both devices.
- The new device is not silently trusted.
- The proof is live and uses real published MartinOMEMO device discovery.
- No credentials, OMEMO secrets, or full trust material are printed.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also report the live two-device evidence with scrubbed status lines. If only
one signed device is available, leave the checklist open and document exactly
what is missing.
