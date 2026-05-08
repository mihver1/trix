# MVP Checklist

Use this checklist before treating the XMPP + OMEMO pivot as usable for real
private messages.

There are no live Matrix users to preserve. Do not build a Matrix bridge,
parallel Matrix service, or Matrix data migration path for this MVP.

## Legacy Product Parity Target

Validated from the legacy client READMEs, known-bugs backlog, and client
checklist, not by copying legacy implementation details.

- [ ] Login, logout, and session restore.
- [ ] Room list with DMs and groups.
- [ ] DM timeline, group timeline, and text composer.
- [ ] Mandatory OMEMO DM creation and text send/receive.
- [ ] Mandatory OMEMO group creation and text send/receive.
- [ ] Attachment send/download with encrypted media and in-app image preview.
- [ ] iOS product-parity pass: Chats/Settings tabs, dense inbox, visible invite
      actions, account state, chat bubbles, composer, and attachment download
      affordances aligned with the legacy Trix client.
- [ ] macOS product-parity pass: multi-column workspace, room inspector, member
      management, and attachment open/share/export flow.
- [ ] Live-validate E2EE group send/receive with at least three accounts.
- [ ] Timeline refresh after app restart through MAM and local cache.
- [ ] Unread/read/delivery decorations.
- [ ] Typing indicators.
- [ ] Message reactions.
- [ ] Foreground room/invite/timeline refresh while the app scene is active.
- [ ] APNs-backed notifications without plaintext payloads.
- [ ] Trix user directory search for new DM/group creation and add-member flows.
- [ ] Basic profile and Trix metadata view/edit surface.
- [ ] Device trust and broader device-management surfaces.
- [ ] TestFlight archive path for the new XMPP Apple app.

## Server

- [x] Choose final XMPP domain: `trix.selfhost.ru`.
- [x] Confirm no live Matrix users or rooms need preservation.
- [x] Add private XMPP server scaffold under `server/xmpp/`.
- [ ] Start the local XMPP server.
- [ ] Verify client-to-server login locally.
- [x] Verify server-to-server federation is disabled in config.
- [x] Verify port `5269` is not externally reachable in production.
- [x] Enable private MUC service for `conference.trix.selfhost.ru`.
- [x] Enforce or document members-only, non-anonymous, persistent group-room
      defaults.
- [x] Enable SQL-backed MAM for encrypted stanza replay.
- [x] Enable HTTP file sharing/upload for encrypted attachments.
- [x] Disable public registration.
- [ ] Create disposable local test users.
- [ ] Create the friend group accounts through an operator-controlled flow.
- [x] Back up server state.
- [x] Back up uploaded encrypted media or confirm media is intentionally
      disposable.
- [ ] Restore backup into a fresh server instance.

## Apple Login And Session

- [ ] Rename service/model boundary from `Matrix*` to protocol-neutral `Trix*`.
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
- [ ] Reuse the existing iOS app identifier, Apple team, and APNs entitlement
      environment settings.
- [ ] Reuse the existing macOS app identifier, Apple team, sandbox/network/file
      access entitlements, and APNs entitlement environment settings.
- [ ] Log in with a local XMPP JID and password.
- [ ] Confirm auth material is not printed in logs.
- [ ] Quit and relaunch the app.
- [ ] Confirm the session restores without retyping the password.
- [ ] Log out.
- [ ] Confirm local session and OMEMO state cleanup behavior is explicit and safe.

## Messaging

- [ ] Show room list after sync.
- [ ] Open a DM through the service layer.
- [ ] Create an encrypted DM through the SwiftUI Apple client flow.
- [ ] Create a private encrypted MUC group through the SwiftUI Apple client flow.
- [ ] Accept or decline pending invites where supported by the chosen XMPP stack.
- [ ] Open a group room.
- [x] Wire DM text send through MartinOMEMO only after explicit peer-device
      trust.
- [x] Live-validate DM text send between two accounts.
- [x] Receive and decrypt an OMEMO DM message.
- [ ] Receive and decrypt an OMEMO group message.
- [x] Block plaintext send in product DM/group flows.
- [ ] Send a file or image attachment from the SwiftUI timeline composer.
- [ ] Download timeline file/image attachments and preview images in app.
- [ ] Open, share, or export downloaded attachments through OS controls.
- [ ] Show sender, timestamp, and body in the SwiftUI timeline model.
- [ ] Auto-refresh the room list, invites, and selected timeline while the app
      scene is active.
- [ ] Select DM, group invitees, and group add-member users from Trix directory
      search results instead of raw JID-only entry.
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
- [ ] Create or join an encrypted DM.
- [ ] Send and receive an encrypted DM message.
- [ ] Create or join an encrypted group room.
- [ ] Send and receive an encrypted group message.
- [x] Confirm server MAM stores encrypted stanza content, not plaintext.
- [ ] Confirm uploaded media is encrypted before the server receives it.
- [ ] Add a second device and confirm device list/fingerprint state is visible.
- [x] Show peer OMEMO device fingerprints and manual trust controls for DMs.
- [x] Confirm untrusted or unknown device behavior is understandable.
- [x] Confirm the app does not silently trust all devices.
- [x] Confirm the composer blocks sending when required OMEMO state is missing.
- [ ] Confirm recovery or reinstall limitations are visible and documented.

## Control Plane

- [ ] Validate ejabberd admin API as the first control-plane candidate.
- [ ] Decide whether any operations still require a small Trix control-plane
      service in front of ejabberd.
- [ ] Create user.
- [ ] Disable user.
- [ ] Reset password.
- [ ] Search directory by handle/name.
- [ ] View and edit profile metadata.
- [ ] Create group.
- [ ] Add group member.
- [ ] Remove group member.
- [ ] List group members.
- [ ] View server health.
- [ ] View archive/upload/push health.
- [ ] Keep admin credentials out of logs and repo files.

## Deferred MVP Items

- [ ] Production device trust UX.
- [ ] Account recovery/reinstall UX.
- [ ] Push notifications through APNs.
- [ ] Persistent tests around encrypted DM/group sync.
- [ ] Persistent tests around directory/profile/control-plane flows.
- [ ] TestFlight archive path for the new XMPP `apple/` app.

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
- [ ] OMEMO group live smoke is validated.
- [ ] Protocol-neutral Apple service boundary exists.
- [x] First XMPP adapter is wired for login, restore, and roster-backed room
      list.
- [x] Persistent local OMEMO store is wired.
- [x] Product composer blocks plaintext sending while OMEMO state or peer trust
      is missing.
- [x] Manual peer-device trust UI is wired for DMs.
- [x] DM text send uses MartinOMEMO encode/write after peer trust.
- [x] Matrix Rust SDK adapter and live smoke runner are removed from the new
      Apple target.
- [ ] Trix control-plane model is selected.
- [ ] No custom crypto is added.

## Notes

- Matrix-named Apple targets and files may remain during the transition. Treat
  them as temporary scaffolding until the protocol-neutral rename lands.
- Existing legacy TestFlight scripts remain the current release reference until
  the XMPP Apple app has its own archive/upload path.
- Live smoke must print only scrubbed status lines. It must not print passwords,
  auth tokens, OMEMO secrets, APNs tokens, decrypted message bodies, or decrypted
  attachment contents.
