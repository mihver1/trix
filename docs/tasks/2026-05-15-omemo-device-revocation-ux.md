# Task: OMEMO Device Revocation UX

You are the next coding agent working in the Trix repo. Add a user-facing path
to revoke an own OMEMO device and remove or deactivate its published OMEMO
bundle through reviewed library/server APIs.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `docs/xmpp-migration/spike-checklist.md`
- `apple/project.yml`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/TrixOMEMOStore.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/DeviceVerificationViewModel.swift`
- `apple/Sources/Shared/Views/TrixLimitationsView.swift`
- `apple/Sources/Shared/Views/TrixRoomListView.swift`
- `apple/Sources/macOS/TrixMacRootView.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

Settings already shows current and published account OMEMO devices discovered
through MartinOMEMO, but revocation is explicitly not implemented.

## Goal

The user can revoke one of their own non-current devices from Settings. Future
sends should stop encrypting to that device, and the UI should show the device as
revoked/inactive or remove it after server state refresh.

## Non-Goals

- Do not let a user revoke another account's device.
- Do not delete OMEMO private keys by manually editing server PubSub nodes unless
  MartinOMEMO or ejabberd exposes a reviewed, documented API for that operation.
- Do not weaken send gating to work around stale devices.
- Do not erase the current device without an explicit destructive flow that also
  logs out locally.
- Do not promise that old ciphertext can be made unreadable on a device that
  already received it.

## Implementation Plan

1. Investigate MartinOMEMO's device-list and bundle publication APIs:
   - how the local device id is published;
   - how an old device is removed from the OMEMO device list;
   - whether its bundle can be deleted or only made unreachable by removing the
     device id from the published list.
2. Extend service boundaries with explicit device actions:
   - `accountDevices(session:)` or reuse existing refresh;
   - `revokeOwnDevice(deviceID:session:)`;
   - optional `renameOwnDevice` only if trivial and supported.
3. In `XMPPMartinService`, implement revocation only through supported APIs:
   - remove target own device id from the account's published OMEMO device list;
   - delete the bundle if the library/server offers a safe API;
   - refresh identities and mark local store state inactive/compromised for the
     revoked device if needed.
4. For current-device revocation, either:
   - defer with clear UI copy; or
   - require confirmation, unregister published device state, clear local session
     and OMEMO Keychain state for this account, then log out.
   Pick the smallest safe route.
5. Update Settings UI:
   - show revoke action only for own non-current devices;
   - require confirmation;
   - show exact caveat that old messages already delivered to that device cannot
     be clawed back;
   - refresh device list after success.
6. Add send-path protections:
   - revoked/inactive own devices must not be included as encryption recipients;
   - untrusted peer devices still block sends as before.
7. Add live smoke `own-device-revocation`:
   - sign in same account on two devices or two isolated local stores;
   - confirm both devices appear;
   - revoke the older device;
   - refresh and confirm it is removed/inactive;
   - send a DM or group message and confirm recipient set excludes revoked
     device, without printing payloads or key material.
8. Update `docs/security.md` and `docs/mvp-checklist.md` with the exact revocation
   behavior and its limits.

## Acceptance Criteria

- Settings exposes a safe revoke action for own non-current devices.
- Revocation updates published OMEMO device state through MartinOMEMO/server
  supported APIs.
- Future sends do not target revoked devices.
- The UI does not imply old ciphertext is deleted from the revoked device.
- No OMEMO private keys, bundles with private material, trust secrets, or
  decrypted messages are logged.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed `own-device-revocation` live smoke if a same-account
two-device setup is available.
