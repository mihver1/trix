# Matrix: Device Management Parity

Status: Open.

## Summary

Legacy Trix has account-level device inventory, link approval, revocation, and
per-chat device membership controls. Matrix has a different device model. The
Matrix Apple app currently surfaces SDK verification/recovery, but not a full
device inventory or account-management surface.

## Legacy behavior to match

- Show current and linked devices.
- Approve pending linked devices.
- Revoke old devices.
- Show enough state for users to understand which devices can access messages.
- Legacy per-chat device membership is MLS-specific and should not be ported
  directly.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Home/DashboardView.swift`
- `apps/ios/TrixiOS/Features/Onboarding/PendingApprovalView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `crates/trix-server/src/routes/devices.rs`

## Current Matrix state

- `MatrixDeviceVerificationService` exposes verification status, SAS actions,
  and recovery setup/confirmation.
- UI intentionally keeps "new devices are not silently trusted" visible.
- No Matrix account device inventory, rename, logout/revoke, or device list UI
  was found.

## Required implementation

- Investigate Matrix SDK Swift bindings for listing devices and invalidating
  sessions/devices.
- Add a service protocol for device inventory and supported device actions.
- Add iOS/macOS device management UI under settings.
- Keep verification/recovery state visible and avoid trust-all shortcuts.
- Clearly document which legacy device operations do not map to Matrix.

## Boundaries

- Do not manually manipulate Matrix encryption keys.
- Do not add local verified overrides.
- Do not silently trust all devices.
- Do not expose per-chat device membership controls unless Matrix SDK supports a
  correct Matrix-native concept.

## Acceptance criteria

- Settings shows the active Matrix session/device and other known devices when
  SDK support is available.
- User can revoke/logout a device if Matrix SDK supports it.
- Device verification state remains visible and accurate.
- Unsupported legacy device actions are documented, not faked.

## Verification plan

- Build iOS and macOS Matrix targets.
- Test with one account signed in on two devices/simulators.
- Verify device list, revoke/logout, and verification state updates.
- Confirm no access tokens or recovery keys are logged.
- `git diff --check`
