# MVP Checklist

Use this checklist before treating the Matrix pivot as usable for real private
messages.

## Server

- [ ] Choose final `server_name`.
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
- [ ] Add a second device and verify it through the Matrix SDK flow.
- [ ] Confirm unverified device behavior is understandable.

## Deferred MVP Items

- [ ] Device verification production UX.
- [ ] Key backup.
- [ ] Key recovery.
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
      and pending invite accept/decline. This slice has not re-run live smoke.

## Live Validation Notes

- `@admin:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- `@test:trix.selfhost.ru` exists and can login/logout through the Matrix API.
- Admin and test credentials are stored in the user's password manager.
- Bootstrap credential files have been removed from the VPS:
  `/root/trix-matrix-admin.bootstrap` and `/root/trix-matrix-test.bootstrap`.
- The live smoke runner uses a signed iOS simulator build because unsigned
  simulator builds cannot access Keychain reliably.
- Several smoke-created encrypted DM rooms may exist on the live server.
