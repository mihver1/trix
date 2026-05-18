# Task: APNs Generic Signed-Device Smoke

You are the next coding agent working in the Trix repo. Close the APNs MVP item
only if a signed iOS or macOS device proves generic APNs delivery without plaintext
payload fields.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `docs/security.md`
- `server/xmpp/README.md`
- `crates/trix-push/src/lib.rs`
- `apps/trix-push-gateway/src/main.rs`
- `apps/trix-push-gateway/src/xmpp_component.rs`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/App/TrixAPNsCoordinator.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/project.yml`

The app currently accepts only `aps.content-available=1` plus
`trix.type=sync`, rejects plaintext/body/decrypted/filename style keys, and
allows only generic visible alert text. The gateway sends
`TrixApnsNotificationPayload` and the XEP-0114 component returns
`max-payload-size=0`.

## Goal

Produce signed-device evidence that APNs delivery works and that the delivered
payload contains no plaintext fields.

## Non-Goals

- Do not add alert pushes with message text.
- Do not expose APNs token values, APNs signing material, gateway tokens, or
  XMPP credentials in logs, docs, screenshots, or committed files.
- Do not expose the push gateway or ejabberd component port publicly.
- Do not mark the checklist complete from unit tests alone. The open item is
  specifically signed-device delivery.

## Implementation Plan

1. Confirm the current state with `git status --short`, then inspect the files
   above.
2. Build or install a signed app using the existing `apple/` lane and a real
   Apple signing identity.
3. Register APNs from the signed app. Verify the app reaches an APNs registered
   state through UI/status or scrubbed logs without printing the token.
4. Trigger a generic push through the real path:
   - Prefer the XMPP path: app registers through Martin/XEP-0357,
     `ejabberd mod_push` publishes to `trix-push-gateway`, and the gateway
     delivers APNs.
   - If the XMPP trigger is unavailable, use the loopback-only HTTP
     `/v0/apns/wake` endpoint as a diagnostic fallback. Keep bearer token and
     APNs token out of output and shell history.
5. Capture a sanitized payload proof. It is acceptable to add a temporary or
   permanent diagnostic that prints only field presence, for example
   `content_available=1 alert=generic body_plaintext=absent filename=absent
   media_key=absent decrypted=absent`.
6. Confirm the signed device receives a visible generic notification, such as
   `New encrypted message` or `N unread encrypted messages`.
7. If code changes were needed, add focused tests around the changed code. Keep
   `TrixApnsNotificationPayload` and `TrixRemoteNotificationPayload` fail-closed for
   forbidden fields.
8. Update `docs/mvp-checklist.md`, `docs/security.md`, and `server/xmpp/README.md`
   with exact dated evidence only after the signed-device proof passes.

## Acceptance Criteria

- A signed iOS or macOS device receives a visible APNs notification for the XMPP
  Trix app.
- The payload proof shows `aps.content-available=1` and `trix.type=sync`.
- The payload proof shows only generic `aps.alert`/`aps.sound` and no message
  body plaintext, decrypted content, filename, attachment name, media key,
  attachment URL, or equivalent user-content field.
- App handling remains generic; no decrypted text or attachment
  metadata appears in push or local notification output.
- Gateway and app logs remain secret-safe.
- `docs/mvp-checklist.md` is updated only if the live proof passes.

## Verification Commands

Run the applicable checks after code or docs changes:

```bash
cargo test -p trix-push
cargo test -p trix-push-gateway
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
bash -n server/xmpp/scripts/*.sh apple/scripts/archive-testflight.sh
git diff --check
```

Also report the signed-device command chain and scrubbed APNs evidence. If a
real signed device or APNs credential path is unavailable, report that as the
blocker and leave the checklist open.
