# MVP Checklist

Use this checklist before treating the Matrix pivot as usable for real private
messages.

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
- [ ] Create the friend group accounts.
- [ ] Disable registration after bootstrap if no new users are needed.
- [ ] Back up the Conduit database volume.
- [ ] Back up the media directory or confirm media is intentionally disposable.
- [ ] Restore the backup into a fresh Conduit instance.

## Apple Login And Session

- [x] Build the iOS Matrix app target.
- [x] Build the macOS Matrix app target.
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
- [ ] Open a group room.
- [ ] Send a plain text message.
- [ ] Receive a plain text message.
- [x] Show sender, timestamp, and body in the SwiftUI timeline model.
- [ ] Confirm timeline refresh after app restart.

## E2EE

- [x] Create or join an encrypted DM.
- [x] Send and receive an encrypted DM message.
- [ ] Create or join an encrypted group room.
- [ ] Send and receive an encrypted group message.
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
- [ ] Live-validate recovery setup/confirmation without printing recovery keys.

## Deferred MVP Items

- [ ] Device verification production UX, pending SDK verified-state validation
      after live SAS completion.
- [ ] Key backup/recovery live validation and persistence tests.
- [ ] Push notifications through Matrix push gateway and APNs.
- [ ] Media upload.
- [ ] Media download.
- [x] Production encrypted DM creation flow.
- [x] Production invite accept/decline flow.
- [ ] Production group room creation.
- [ ] Production group invite handling.
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

## Live Validation Notes

- `@admin:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- `@test:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- Admin and test credentials are stored in the user's password manager.
- Bootstrap credential files have been removed from the VPS:
  `/root/trix-matrix-admin.bootstrap` and `/root/trix-matrix-test.bootstrap`.
- The live smoke runner uses a signed iOS simulator build because unsigned
  simulator builds cannot access Keychain reliably.
- Device verification live smoke does not print SAS values; it only reports
  phase completion, SDK verified-state, eligible-device flags, backup/recovery
  state, and own user identity status.
- Several smoke-created encrypted DM rooms may exist on the live server.
