# Matrix: APNs-Backed Push Notifications Parity

Status: Open.

## Summary

Legacy Trix has APNs token registration, server-side APNs delivery, background
remote notification handling, local notification presentation, and macOS
notification settings. Matrix Apple currently has APNs entitlements but no
Matrix push gateway integration.

## Legacy behavior to match

- iOS registers APNs tokens, handles remote notifications, refreshes in the
  background, and posts local notifications for new messages.
- macOS exposes notification settings, syncs/deletes APNs tokens, and supports
  background polling notifications.
- The legacy server sends background APNs inbox updates.

Relevant legacy entry points:

- `apps/ios/TrixiOS/App/AppModel.swift`
- `apps/ios/TrixiOS/App/NotificationSupport.swift`
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
- `apps/macos/Sources/TrixMac/Support/NotificationSupport.swift`
- `crates/trix-server/src/push.rs`

## Current Matrix state

- iOS and macOS Matrix targets have APNs entitlements.
- `docs/mvp-checklist.md`, `apple/README.md`, and
  `MatrixLimitationsView.swift` list push notifications as TODO.
- No Matrix push gateway, push rule setup, token registration service, or user
  notification coordinator is wired for the Matrix app.

## Required implementation

- Decide and document the Matrix push gateway path for the private Conduit
  deployment.
- Add a Matrix push registration service that registers APNs tokens through
  Matrix-supported push APIs.
- Add iOS remote notification handling that wakes the Matrix client and refreshes
  rooms/timelines without printing event bodies.
- Add macOS notification preference UI and token sync/delete behavior.
- Reuse existing app identifiers and entitlements where configured.
- Add user-facing notification previews that do not expose decrypted message
  bodies unless the platform notification policy and product decision allow it.

## Boundaries

- Do not add telemetry.
- Do not log APNs tokens, Matrix access tokens, decrypted bodies, passwords, or
  registration tokens.
- Do not resurrect legacy server APNs APIs for Matrix rooms.

## Acceptance criteria

- iOS registers and unregisters APNs push data for the active Matrix account.
- macOS exposes notification settings and registers/deletes push data.
- A message sent while the app is backgrounded produces a notification.
- Tapping/opening the notification lands in the relevant room or refreshes the
  inbox safely.
- Push works for encrypted DM and encrypted group rooms without weakening E2EE.

## Verification plan

- Build signed iOS and macOS Matrix apps because push cannot be fully validated
  with unsigned builds.
- Use disposable Matrix accounts and a non-secret APNs test path.
- Validate background notification receipt on iOS.
- Validate macOS notification settings and delivery.
- `git diff --check`
