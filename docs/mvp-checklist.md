# MVP Checklist

Use this checklist before treating the XMPP + OMEMO pivot as usable for real
private messages.

There are no live Matrix users to preserve. Do not build a Matrix bridge,
parallel Matrix service, or Matrix data migration path for this MVP.

## Legacy Product Parity Target

Validated from the legacy client READMEs, known-bugs backlog, and client
checklist, not by copying legacy implementation details.

- [x] Login, logout, and session restore.
- [x] Room list with DMs and groups.
- [x] DM timeline, group timeline, and text composer.
- [x] Mandatory OMEMO DM creation and text send/receive.
- [x] Mandatory OMEMO group creation and text send/receive.
- [ ] Attachment send/download with encrypted media and in-app image preview
      is implemented in the Apple XMPP service for DMs and group MUCs; group
      sends remain gated on a validated MUC member recipient set plus trusted
      active OMEMO devices for every recipient. Keep open until live validation
      is complete.
- [ ] iOS product-parity pass: Chats/Settings tabs, dense inbox, visible invite
      actions, account state, chat bubbles, composer, and attachment download
      affordances aligned with the legacy Trix client.
- [ ] macOS product-parity pass: multi-column workspace, room inspector, member
      management, and attachment open/share/export flow.
- [x] Live-validate E2EE group send/receive with at least three accounts.
      `group-e2ee` macOS live smoke passed on 2026-05-09 with `test`, `friend`,
      and `admin` accounts.
- [ ] Timeline refresh after app restart through MAM and local cache.
- [ ] Unread/read decorations.
- [x] Delivery decorations.
- [x] Typing indicators.
- [ ] Message reactions.
- [x] Foreground room/invite/timeline refresh while the app scene is active.
- [ ] APNs-backed notifications without plaintext payloads. Apple token capture,
      XMPP push-component registration plumbing, and wake-only payload handling
      are wired. `trix-push-gateway` now includes the APNs sender plus XEP-0114
      component/store for Martin/XEP-0357 registration nodes. Delivery remains
      blocked until deployment with real APNs credentials passes signed-device
      smoke without exposing plaintext payloads.
- [x] Trix user directory search for new DM/group creation and add-member flows.
- [x] Basic XMPP vCard-backed profile view/edit surface for display name, bio,
      status, and website.
- [ ] Device trust and broader device-management surfaces.
- [x] Repeatable local archive/TestFlight script path for the new XMPP Apple
      app targets.

## Server

- [x] Choose final XMPP domain: `trix.selfhost.ru`.
- [x] Confirm no live Matrix users or rooms need preservation.
- [x] Add private XMPP server scaffold under `server/xmpp/`.
- [x] Start the local XMPP server.
- [x] Verify client-to-server login locally.
- [x] Verify server-to-server federation is disabled in config.
- [x] Verify port `5269` is not externally reachable in production.
- [x] Enable private MUC service for `conference.trix.selfhost.ru`.
- [x] Enforce or document members-only, non-anonymous, persistent group-room
      defaults.
- [x] Enable SQL-backed MAM for encrypted stanza replay.
- [x] Enable HTTP file sharing/upload for encrypted attachments.
- [x] Disable public registration.
- [x] Create disposable local test users.
- [ ] Create the friend group accounts through an operator-controlled flow.
- [x] Back up server state.
- [x] Back up uploaded encrypted media or confirm media is intentionally
      disposable.
- [x] Restore backup into a fresh server instance through the
      ejabberd-native backup/restore verifier.

## Apple Login And Session

- [x] Rename service/model/view boundary from `Matrix*` to protocol-neutral
      `Trix*`. The generated Xcode project and schemes still keep
      `TrixMatrix*` compatibility names for this slice.
- [x] Keep SwiftUI views dependent on view models, not XMPP or OMEMO APIs.
- [x] Build the iOS Apple target with the first XMPP adapter slice.
- [x] Build the macOS Apple target with the first XMPP adapter slice.
- [x] Remove Matrix Rust SDK and Matrix live smoke code from the new Apple
      targets.
- [x] Add scrubbed XMPP live smoke hooks for login, roster, and plaintext-send
      blocking checks.
- [x] Persist local OMEMO registration id, identity key pair, prekeys, signed
      prekeys, session records, identities, and sender keys in Keychain.
- [x] Register MartinOMEMO with a CryptoKit AES-GCM engine.
- [x] Reuse the existing iOS app identifier, Apple team, and APNs entitlement
      environment settings.
- [x] Reuse the existing macOS app identifier, Apple team, sandbox/network/file
      access entitlements, and APNs entitlement environment settings.
- [x] Log in with a local XMPP JID and password.
- [x] Confirm auth material is not printed in app or live-smoke output paths.
- [x] Quit and relaunch the app through the Keychain-backed restore path.
- [x] Confirm the session restores without retyping the password.
- [x] Log out.
- [x] Confirm local session cleanup behavior is explicit and safe: logout removes
      the saved XMPP login from Keychain and keeps OMEMO device/trust state
      local until app Keychain data is reset.

## Messaging

- [x] Show roster-backed DM room list after sync with cached/MAM-backed latest
      preview and activity sorting.
- [x] Open a DM through the service layer.
- [x] Create an encrypted DM through the SwiftUI Apple client flow.
- [x] Create a private encrypted MUC group through the SwiftUI Apple client flow.
- [x] Accept or decline pending MUC invites after reconnect through the Apple
      XMPP service's local invite cache and MAM resync; mediated declines are
      sent through Martin, while direct-invite decline remains local-only.
- [x] Open a group room through the service layer.
- [x] Wire DM text send through MartinOMEMO only after explicit peer-device
      trust.
- [x] Live-validate DM text send between two accounts.
- [x] Receive and decrypt an OMEMO DM message.
- [x] Receive and decrypt an OMEMO group message.
- [x] Block plaintext send in product DM/group flows.
- [x] Send a file or image attachment from the SwiftUI timeline composer in
      encrypted DMs and group MUCs. Group attachment send remains blocked unless
      the service validates the MUC member recipient set and every recipient has
      a trusted active OMEMO device.
- [x] Download encrypted DM timeline file/image attachments, decrypt locally,
      and preview images in app.
- [x] Open, share, or export downloaded DM attachments through OS controls.
- [x] Show sender, timestamp, and body in the SwiftUI timeline model.
- [x] Show sent/delivered decorations for local outgoing DM messages through
      XMPP delivery receipts.
- [x] Live-validate XMPP delivery receipt updates with both DM accounts online.
- [x] Send and receive live XMPP chat-state typing indicators for DMs.
- [x] Live-validate typing `composing` and `paused` transitions with both DM
      accounts online.
- [x] Auto-refresh the room list, invites, and selected timeline while the app
      scene is active.
- [x] Refresh the roster-backed DM room list and selected DM timeline while the
      app scene is active.
- [x] Select DM and new-group invitees from Trix directory search results
      instead of raw JID-only entry.
- [x] Select existing-group add-member users from Trix directory search results.
- [x] Keep newly decrypted or locally sent DM timeline items visible after app
      restart through the local Keychain-backed timeline cache.
- [ ] Restore sender-side OMEMO self-history from MAM after restart; encrypted
      server archives are ciphertext-only and old messages that were not
      encrypted for the sender's current device cannot be reconstructed.

## E2EE

- [x] Validate that MartinOMEMO/libsignal resolves and builds for iOS and
      macOS targets.
- [x] Wire persistent local OMEMO state and module registration into the XMPP
      connection.
- [ ] Spike Tigase Martin plus MartinOMEMO first, with GPL/AGPL obligations
      explicitly accepted or rejected for the non-commercial friends app.
- [x] Create or join an encrypted DM.
- [x] Send and receive an encrypted DM message.
- [x] Create or join a private members-only, non-anonymous MUC with OMEMO-gated
      product sends.
- [x] Send and receive an encrypted group message.
- [x] Confirm server MAM stores encrypted stanza content, not plaintext.
- [x] Confirm the Apple XMPP attachment path encrypts media with MartinOMEMO
      before HTTP upload. Group MUC attachment send additionally requires a
      validated recipient set and trusted active OMEMO device for every
      recipient. Live server round-trip validation is still required.
- [ ] Add a second device and confirm device list/fingerprint state is visible.
- [x] Show peer OMEMO device fingerprints and manual trust controls for DMs.
- [x] Confirm untrusted or unknown device behavior is understandable.
- [x] Confirm the app does not silently trust all devices.
- [x] Confirm the composer blocks sending when required OMEMO state is missing.
- [ ] Confirm recovery or reinstall limitations are visible and documented.

## Control Plane

- [x] Validate ejabberd admin API as the first control-plane candidate.
- [x] Decide whether any operations still require a small Trix control-plane
      service in front of ejabberd: yes, use ejabberd `mod_http_api` only as a
      localhost backend behind an authenticated/audited Trix operator wrapper.
- [x] Create user.
- [ ] Disable user.
- [ ] Reset password.
- [ ] Search directory by handle/name.
- [x] View and edit account profile metadata through the Apple XMPP client.
- [x] Create group through the Apple XMPP client MUC path.
- [x] Add group member through the Apple XMPP client MUC path.
- [x] Remove group member through the Apple XMPP client MUC path.
- [x] List group members through the Apple XMPP client MUC path. The Apple
      service merges live MUC occupants, affiliation results, and a Keychain
      known-member cache so previously seen group members remain visible after
      reconnect. New Apple-created private MUCs grant invited members MUC admin
      affiliation for the MVP member-management UI; older member-only rooms may
      still return forbidden for add/remove from non-admin accounts.
- [x] View server health.
- [ ] View archive/upload/push health.
- [x] Keep admin credentials out of logs and repo files.

## Deferred MVP Items

- [ ] Production device trust UX.
- [ ] Account recovery/reinstall UX.
- [ ] Push notifications through APNs. Blocked until the checked-in
      `trix-push-gateway` component is deployed behind ejabberd
      `mod_push`/XEP-0357 with deployment-local APNs signing material and passes
      signed-device delivery smoke with no plaintext payload fields.
- [ ] Persistent tests around encrypted DM/group sync.
- [ ] Persistent tests around directory/profile/control-plane flows.
- [x] Repeatable archive/TestFlight script path for the new XMPP `apple/` app.
- [x] Fail-closed Apple APNs registration plumbing exists for the new XMPP
      targets: platform token capture, service-bound XMPP push registration, and
      wake-only remote push handling.
- [x] Trix APNs gateway/push component exists as `trix-push-gateway`: it accepts
      Martin/Tigase registration, stores XEP-0357 node mappings, and calls the
      APNs sender with wake-only payloads.
- [ ] Trix APNs gateway/push component is deployed with deployment-local
      credentials outside the repo and passes signed-device delivery smoke.

## Current First-Slice Status

- [x] XMPP-only product direction is documented.
- [x] Matrix data migration is explicitly out of scope because there are no live
      Matrix users.
- [x] XMPP server scaffold exists.
- [x] Production ejabberd is deployed at `trix.selfhost.ru`.
- [x] SQL-backed MAM is enabled.
- [x] Daily root-only XMPP backup timer is installed.
- [x] Apple OMEMO dependency candidate builds: Martin `3.2.4`, MartinOMEMO
      `2.2.3`, libsignal `1.0.0`.
- [ ] OMEMO DM live smoke is validated.
- [x] OMEMO group live smoke is validated.
- [x] Protocol-neutral Apple service boundary exists.
- [x] First XMPP adapter is wired for login, restore, and roster-backed room
      list.
- [x] Persistent local OMEMO store is wired.
- [x] Product composer blocks plaintext sending while OMEMO state or peer trust
      is missing.
- [x] Manual peer-device trust UI is wired for DMs.
- [x] DM text send uses MartinOMEMO encode/write after peer trust.
- [x] Apple XMPP group create/join/invite/member operations are wired through
      Martin MUC primitives. Group text send now uses MartinOMEMO multi-recipient
      encode for known members, and live three-account send/receive/decrypt
      validation passed on 2026-05-09. Group member lists persist known members
      in Keychain and the smoke checks owner, peer, and third-account visibility.
- [x] Matrix Rust SDK adapter and live smoke runner are removed from the new
      Apple target.
- [x] Apple APNs tokens are never logged by the new XMPP app path and remote
      pushes are handled as wake/sync hints only.
- [ ] APNs delivery is blocked on deployment/signed-device smoke. ejabberd
      `mod_push` is wired to a private XEP-0114 component path, and
      `trix-push-gateway` owns APNs sender plus Martin/XEP-0357 registration
      mapping, but the live APNs credentialed path has not been smoke-tested.
- [ ] Trix control-plane model is selected.
- [x] No custom crypto is added.

## Notes

- Apple source files, service protocols, models, and views now use
  protocol-neutral `Trix*` names. The generated project and schemes remain
  `TrixMatrix.xcodeproj`, `TrixMatrixiOS`, and `TrixMatrixMac` for command
  compatibility during this slice. Temporary `matrix-*` just aliases remain only
  for callers that have not switched command names yet.
- Existing legacy TestFlight scripts are preserved. The new XMPP Apple app now
  has `apple/scripts/archive-testflight.sh` for iOS/macOS archive, export, and
  upload paths, with unsigned archive mode for machines without signing
  material.
- Live smoke must print only scrubbed status lines. It must not print passwords,
  auth tokens, OMEMO secrets, APNs tokens, decrypted message bodies, or decrypted
  attachment contents.
