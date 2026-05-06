# MVP Checklist

Use this checklist before treating the Matrix pivot as usable for real private
messages.

## Legacy Product Parity Target

Validated from the legacy client READMEs and client checklist, not by copying
legacy implementation details.

- [x] Login, logout, and session restore.
- [x] Room list, DM timeline, group timeline, and text composer.
- [x] Encrypted DM creation, invite accept/decline, and text send/receive.
- [x] Encrypted group creation and generic group invite accept/decline.
- [x] Attachment send/download with in-app image preview through Matrix SDK
      media/timeline APIs.
- [x] Live-validate encrypted group send/receive with at least three accounts.
- [ ] Timeline refresh after app restart.
- [ ] Unread/read/delivery decorations.
- [x] Live-validate encrypted attachment round-trip and add OS open/share flow.
- [x] Foreground room/invite/timeline polling while the app scene is active.
- [ ] APNs-backed notifications through a Matrix push gateway.
- [ ] Basic profile, notification, and device-management surfaces.
- [ ] TestFlight archive path for the new Matrix Apple app.

## Server

- [x] Choose final `server_name`: trix.selfhost.ru
- [x] Confirm `server_name` is `trix.selfhost.ru` or intentionally changed
      before real users exist.
- [ ] Replace the sample registration token.
- [ ] Start Conduit locally with `cd server && docker compose up -d conduit`.
- [ ] Verify `/_matrix/client/versions` responds locally.
- [x] Start the VPS deployment through Caddy or another TLS reverse proxy.
- [x] Verify `https://trix.selfhost.ru/_matrix/client/versions`.
- [x] Verify `https://trix.selfhost.ru/.well-known/matrix/client`.
- [x] Create the first admin user.
- [x] Create a live test user.
- [x] Create the friend group accounts.
- [ ] Disable registration after bootstrap if no new users are needed.
- [ ] Back up the Conduit database volume.
- [ ] Back up the media directory or confirm media is intentionally disposable.
- [ ] Restore the backup into a fresh Conduit instance.

## Apple Login And Session

- [x] Build the iOS Matrix app target.
- [x] Build the macOS Matrix app target.
- [x] Reuse the existing iOS app identifier, Apple team, and APNs entitlement
      environment settings for the Matrix iOS target.
- [x] Reuse the existing macOS app identifier, Apple team, sandbox/network/file
      access entitlements, and APNs entitlement environment settings for the
      Matrix macOS target.
- [x] Log in with a Matrix user ID and password.
- [x] Confirm access tokens are not printed in live smoke logs.
- [x] Quit and relaunch the app.
- [x] Confirm the session restores without retyping the password.
- [x] Log out.
- [x] Confirm local session material is removed.

## Messaging

- [x] Show room list after sync.
- [x] Open a DM room through the Matrix service layer.
- [x] Create an encrypted DM through the SwiftUI Apple client flow.
- [x] Accept or decline pending invites through the SwiftUI Apple client flow.
- [x] Open a group room.
- [x] Send a plain text message.
- [x] Receive a plain text message.
- [x] Send a file or image attachment from the SwiftUI timeline composer.
- [x] Download timeline file/image attachments and preview images in app.
- [x] Open, share, or export downloaded attachments through OS controls.
- [x] Show sender, timestamp, and body in the SwiftUI timeline model.
- [x] Auto-refresh the room list, invites, and selected timeline while the app
      scene is active.
- [ ] Confirm timeline refresh after app restart.

## E2EE

- [x] Create or join an encrypted DM.
- [x] Send and receive an encrypted DM message.
- [x] Create or join an encrypted group room.
- [x] Send and receive an encrypted group message.
- [x] Confirm Conduit stores encrypted event content, not plaintext.
- [x] Confirm device verification limitation is visible in the app.
- [x] Surface Matrix SDK device verification state in the Apple UI.
- [x] Wire explicit Matrix SDK device verification actions in the Apple UI.
- [x] Add a second device and complete the Matrix SDK SAS verification flow.
- [ ] Confirm Matrix SDK verified-state flips after the SAS flow completes.
- [x] Confirm unverified device behavior is understandable.
- [x] Show a no-eligible-device blocked state when Matrix SDK cannot start
      interactive SAS.
- [x] Add SDK-backed recovery setup/confirmation UI for that blocked state.
- [x] Live-validate recovery setup/confirmation without printing recovery keys.

## Deferred MVP Items

- [ ] Device verification production UX, pending SDK verified-state validation
      after live SAS completion.
- [x] Key backup/recovery live validation.
- [ ] Key backup/recovery persistence tests.
- [ ] Push notifications through Matrix push gateway and APNs.
- [x] SDK-backed media upload/download path in the Apple UI.
- [x] Live attachment round-trip validation and OS open/share/export flow.
- [x] Production encrypted DM creation flow.
- [x] Production invite accept/decline flow.
- [x] Production group room creation.
- [x] Production group invite handling.
- [ ] TestFlight archive path for the new `apple/` Matrix app.

## Current First-Slice Status

- [x] Server/client/docs structure exists.
- [x] Conduit scaffold exists.
- [x] SwiftUI Apple scaffold exists.
- [x] Matrix service protocols exist.
- [x] Mock Matrix service exists for local UI development.
- [x] Real Matrix Rust SDK Swift adapter is wired.
- [x] Matrix SDK Swift package is pinned.
- [x] Real Conduit login is validated with a live account.
- [x] Real encrypted message sync is validated end to end.
- [x] Live iOS smoke validates login, session restore, encrypted DM creation,
      encrypted send, encrypted receive, and cleanup against
      `https://trix.selfhost.ru`.
- [x] SwiftUI Apple client has production controls for encrypted DM creation
      and pending invite accept/decline.
- [x] SwiftUI Apple client has production controls for private encrypted group
      room creation with at least two invitees, through Matrix SDK `createRoom`
      and the same generic invite accept/decline flow used for DMs. Live
      encrypted group smoke on May 6, 2026 created a private encrypted group
      with admin, test, and friend accounts, accepted both invites, sent
      generated messages from two participants, and verified receipt by the
      other participants without printing passwords, access tokens,
      registration tokens, SAS values, recovery keys, or decrypted message
      bodies.
- [x] SwiftUI Apple client can attach files/images from the timeline composer,
      send them through Matrix SDK timeline attachment APIs, render file/image
      timeline events, download them through Matrix SDK media APIs, and preview
      downloaded images in app. Downloaded attachments can be opened, shared,
      or exported through OS controls. Live encrypted attachment round-trip
      smoke on May 6, 2026 created an encrypted DM, joined the test account,
      sent a generated attachment, received the file event, downloaded it, and
      matched bytes without printing filenames, payloads, passwords, access
      tokens, registration tokens, SAS values, recovery keys, or decrypted
      message bodies.
- [x] SwiftUI Apple client runs a foreground auto-refresh loop while the app
      scene is active. It silently refreshes rooms, pending invites, and the
      selected timeline through the existing Matrix service/view-model boundary,
      and reconciles the selected room if sync removes it.
- [x] SwiftUI Apple client shows read-only Matrix SDK device verification
      state without silently trusting devices.
- [x] SwiftUI Apple client can request, accept, start SAS, approve, decline,
      and cancel Matrix SDK device verification. Live iOS smoke on May 5, 2026
      reached request, accept, SAS start, matching challenge, and
      `SessionVerificationController` `didFinish` against
      `https://trix.selfhost.ru`; Matrix SDK verified-state did not flip within
      the smoke timeout. DEBUG diagnostics on both sessions reported
      `verificationState=unverified`, `hasDevicesToVerifyAgainst=false`,
      `isLastDevice=false`, `backupExistsOnServer=false`,
      `recoveryState=disabled`, and an own user identity present with
      `hasMasterKey=true` but not verified. Element X only offers interactive
      session verification when `hasDevicesToVerifyAgainst=true`; Trix follows
      that SDK gate in the UI, adapter, and live smoke, and does not treat SAS
      completion as a local verified flag.
- [x] SwiftUI Apple client shows a no-eligible-device blocked state and exposes
      Matrix SDK recovery instead of forcing SAS: `enableRecovery` is available
      only when SDK recovery is disabled, and `recoverAndFixBackup` is available
      only when SDK recovery is enabled or incomplete. Recovery keys are shown
      only in UI state for the user to save or enter, not in logs or live smoke
      output.
- [x] Signed-simulator live iOS device verification smoke was re-run after the
      recovery UI slice on May 5, 2026. It exited successfully in the expected
      blocked state with `verificationState=unverified`,
      `hasDevicesToVerifyAgainst=false`, `backupState=unknown`,
      `backupExistsOnServer=false`, `recoveryState=disabled`, and no SAS forcing.
- [x] DEBUG live iOS smoke has a safe `recovery` mode for a dedicated disposable
      account. It refuses to run without `TRIX_MATRIX_LIVE_SMOKE_RECOVERY_USER_ID`,
      `TRIX_MATRIX_LIVE_SMOKE_RECOVERY_PASSWORD`, and
      `TRIX_MATRIX_LIVE_SMOKE_ALLOW_RECOVERY_MUTATION=1`; refuses
      `@admin:trix.selfhost.ru`; calls `enableRecovery` only from
      `recoveryState=disabled`; keeps the generated recovery key in process
      memory only; then calls `recoverAndFixBackup` from a second session and
      reports only non-secret `TRIX_LIVE_SMOKE` state lines.
- [x] Live-validated Matrix recovery/key backup setup and confirmation against
      `@recovery-smoke-20260506092649-7c56b1:trix.selfhost.ru` on May 6, 2026.
      The signed iOS simulator smoke printed only non-secret `TRIX_LIVE_SMOKE`
      lines. Setup started at `verificationState=unverified`,
      `isLastDevice=true`, `backupState=unknown`, `backupExistsOnServer=false`,
      `recoveryState=disabled`, then `enableRecovery` reached
      `verificationState=verified`, `backupState=enabled`,
      `backupExistsOnServer=true`, and `recoveryState=enabled`. Confirmation
      started from a second session with `verificationState=unverified`,
      `isLastDevice=false`, `backupState=unknown`, `backupExistsOnServer=true`,
      `recoveryState=incomplete`, then `recoverAndFixBackup` reached
      `verificationState=verified`, `backupState=enabled`,
      `backupExistsOnServer=true`, and `recoveryState=enabled`.

## Live Validation Notes

- `@admin:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- `@test:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- A third friend smoke account exists for encrypted group validation; its
  credentials are stored only in the local ignored `dev-credentials.txt`.
- `@recovery-smoke-20260506092649-7c56b1:trix.selfhost.ru` exists for recovery
  smoke validation and was consumed by the successful May 6, 2026 run. Recovery
  setup smoke accounts are one-shot because a successful run leaves SDK recovery
  enabled.
- `@recovery-smoke-20260506093024-d2736f:trix.selfhost.ru` exists as the fresh
  next-run recovery smoke account. Its password is stored in the local Keychain
  service `com.softgrid.trixmatrix.live-smoke.recovery-password`; the active
  smoke user id is stored in `com.softgrid.trixmatrix.live-smoke` /
  `recovery-user-id`.
- Admin and test credentials are stored in the user's password manager.
- Bootstrap credential files have been removed from the VPS:
  `/root/trix-matrix-admin.bootstrap` and `/root/trix-matrix-test.bootstrap`.
- The live smoke runner uses a signed iOS simulator build because unsigned
  simulator builds cannot access Keychain reliably.
- Device verification live smoke does not print SAS values; it only reports
  phase completion, SDK verified-state, eligible-device flags, backup/recovery
  state, and own user identity status.
- Recovery live smoke must use a dedicated disposable account plus
  `TRIX_MATRIX_LIVE_SMOKE_ALLOW_RECOVERY_MUTATION=1`; it must not run against
  `@admin:trix.selfhost.ru` without explicit approval.
- Several smoke-created encrypted DM rooms may exist on the live server.
