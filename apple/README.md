# Trix Apple Client

This directory contains the current native SwiftUI Apple scaffold for iOS and
macOS.

The project is in transition. The active product direction is XMPP + OMEMO, and
the active Apple service, model, view, and source-file surface now uses
protocol-neutral `Trix*` names. The generated Xcode project and schemes keep the
`TrixMatrix*` names for command compatibility during this slice. Historical
Matrix references describe the previous experiment only.

There are no live Matrix users to preserve, so the Apple migration does not need
a Matrix bridge, Matrix history import, Matrix device migration, or parallel
Matrix operation.

## Targets

- `TrixMatrixiOS`: iOS SwiftUI app.
- `TrixMatrixMac`: macOS SwiftUI app.

Generate the Xcode project:

```bash
cd apple
xcodegen generate
```

Build macOS:

```bash
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Build iOS:

```bash
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO
```

## Release, Signing, And APNs

The new XMPP Apple targets currently reuse the legacy Apple app identity:

- iOS target `TrixMatrixiOS`: bundle identifier `com.softgrid.trixapp`, team
  `HGY33KYKQ2`, entitlement file `TrixiOS.entitlements`.
- macOS target `TrixMatrixMac`: bundle identifier `com.softgrid.trixapp`, team
  `HGY33KYKQ2`, entitlement file `TrixMac.entitlements`.

The APNs entitlement environment is build-configuration driven:

- `Debug`: `TRIX_APNS_ENTITLEMENT_ENVIRONMENT=development`.
- `Release`: `TRIX_APNS_ENTITLEMENT_ENVIRONMENT=production`.

The iOS entitlement key is `aps-environment`. The macOS entitlement key is
`com.apple.developer.aps-environment`, alongside the sandbox, network-client,
and user-selected read-only file access entitlements inherited from the legacy
macOS app.

Generate a local unsigned archive when private signing material is unavailable:

```bash
cd apple
./scripts/archive-testflight.sh --platform ios --unsigned-archive
./scripts/archive-testflight.sh --platform macos --unsigned-archive
```

Create an App Store Connect archive/export with local Xcode signing state:

```bash
cd apple
TRIX_APPLE_BUILD_NUMBER=42 ./scripts/archive-testflight.sh --platform ios
TRIX_APPLE_BUILD_NUMBER=42 ./scripts/archive-testflight.sh --platform macos
```

For TestFlight upload, set `TRIX_ASC_DESTINATION=upload` and provide App Store
Connect authentication through local environment variables such as
`TRIX_ASC_AUTH_KEY_PATH`, `TRIX_ASC_AUTH_KEY_ID`, and
`TRIX_ASC_AUTH_ISSUER_ID`. Do not commit APNs keys, App Store Connect keys,
provisioning profiles, passwords, or signing certificates.

APNs is not a plaintext message channel. Push payloads must contain only routing
or wake-up metadata such as account, room, badge, collapse, or sync hints. They
must not include decrypted message bodies, decrypted attachment names, OMEMO
keys, XMPP passwords, auth tokens, APNs tokens, or device trust secrets. Product
DM and group sends remain blocked unless OMEMO encryption succeeds.

The checked-in Apple app now has fail-closed APNs plumbing:

- iOS and macOS register with APNs through the platform app delegates.
- The APNs token stays in memory on the client side and is never printed.
- After login/session restore, `TrixAppModel` asks `XMPPMartinService` to
  register the token through a discovered XMPP push component.
- The XMPP path uses Martin's `TigasePushNotificationsModule`: ad-hoc
  `register-device`, then XEP-0357 `enable` for the returned node.
- Remote pushes are accepted only as the Trix wake contract
  `com.softgrid.trix.apns.wake.v1`: `aps.content-available=1` plus
  `trix.type=sync`, optional `trix.account`, optional `trix.room`, and optional
  badge metadata. Payloads with alert, sound, plaintext/body, decrypted,
  filename, or attachment-name fields are ignored by the app.
- Foreground notification presentation is suppressed for this target; remote
  pushes only wake and refresh local encrypted state.

Current MVP blocker: `server/xmpp` enables ejabberd `mod_push` and the checked-in
`trix-push-gateway` provides the private XEP-0114 component that accepts
Martin/Tigase APNs token registration, maps XEP-0357 nodes, signs APNs requests,
and emits the wake-only payload contract above. On 2026-05-10 the gateway was
deployed on the VPS with deployment-local APNs token-auth material and connected
to ejabberd as `push.trix.selfhost.ru`. Keep signed-device APNs smoke open until
the gateway sends a wake-only payload with no plaintext fields.

Optional live smoke modes are available through `TRIX_XMPP_LIVE_SMOKE_MODE`:
`login`, `session-restore`, `roster`, `room-list`, `search`, `peer-devices`,
`trust-peer`, `profile`, `profile-update`, `timeline`, `send-timeline`,
`timeline-restart`, `dm-e2ee`, `dm-reaction`, `dm-attachment`,
`delivery-receipt`, `typing`, `blocked-send`, `group-e2ee`, and
`group-attachment`.
Provide credentials only through temporary environment variables:

```bash
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/trix-xmpp-smoke-mac \
  build CODE_SIGNING_ALLOWED=NO

TRIX_XMPP_LIVE_SMOKE_MODE=login \
TRIX_XMPP_LIVE_SMOKE_USER_ID=user@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PASSWORD='...' \
/tmp/trix-xmpp-smoke-mac/Build/Products/Debug/Trix.app/Contents/MacOS/Trix
```

The runner prints only `TRIX_XMPP_LIVE_SMOKE` status lines and must not print
passwords, auth tokens, OMEMO secrets, or decrypted message bodies. The
`room-list` mode follows the UI reload path by loading rooms and invitations.
The `search` mode also requires `TRIX_XMPP_LIVE_SMOKE_SEARCH_TERM`. The vCard
directory returns local users through `vjud.trix.selfhost.ru`, and the client
does substring filtering locally so prefix queries such as `fri` can match
`friend@trix.selfhost.ru`. The `peer-devices` mode requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID` and refreshes the contact's published OMEMO
devices without printing fingerprints. The `session-restore` mode saves the
fresh session into a smoke-only Keychain item, loads it through a new service
instance, restores the XMPP connection, logs out, clears that smoke item, and
prints only status lines. The `trust-peer` mode requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID` and `TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`; it
trusts one active OMEMO device for explicit smoke setup only. The `profile`
mode reads the current account vCard and prints only boolean field presence. The
`profile-update` mode requires `TRIX_XMPP_LIVE_SMOKE_ALLOW_PROFILE_UPDATE=1` and
accepts `TRIX_XMPP_LIVE_SMOKE_PROFILE_DISPLAY_NAME`,
`TRIX_XMPP_LIVE_SMOKE_PROFILE_BIO`, `TRIX_XMPP_LIVE_SMOKE_PROFILE_STATUS`, and
`TRIX_XMPP_LIVE_SMOKE_PROFILE_WEBSITE`; it does not print the submitted values.
The `blocked-send`
mode also requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID`; it creates or refreshes a
direct roster entry, then treats `e2eeUnavailable` or missing OMEMO trust as
success because plaintext fallback must stay blocked. The `timeline` mode also
requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID`; it loads the encrypted MAM-backed
timeline and prints only counts, never message bodies. The `send-timeline` mode
requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID` and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1`; it sends one generated OMEMO message and
then reloads the timeline, still printing only IDs plus timeline and
sent/delivered counts. The `timeline-restart` mode also requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID`; with `TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1` and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`, it first sends one generated OMEMO DM,
then reloads MAM/cache, disconnects the service, restores through a fresh
service instance, and requires overlapping item IDs after restart. It prints
only IDs and MAM/cache counts, including whether archived sender stanzas are
missing a local recipient key. The `dm-e2ee` mode also requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID`, `TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD`,
`TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1`, and, when trust is not already present,
`TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`; it keeps the peer online, sends one
generated OMEMO DM, waits for the peer to decrypt it, and prints only
IDs/status. The `dm-attachment` mode uses the same credential and trust
variables, sends one generated image fixture through the encrypted attachment
path, waits for the peer to download and decrypt it, and prints only
IDs/status, byte counts, and image booleans. It must not print the decrypted
content, filename, media key fragment, or download URL. The `dm-reaction` mode
uses the same credential and trust variables, sends one generated OMEMO DM,
reacts from the peer through XEP-0444, waits for the owner timeline to show the
aggregate, and prints only IDs/status. The `delivery-receipt`
mode also requires
`TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD`; it keeps the peer online, sends one
generated OMEMO message, and waits for a real XMPP delivery receipt without
printing message text or credentials. The `typing` mode uses the same peer
credential variables, sends composing and paused XMPP chat states from the peer,
and prints only state-transition status. The `group-e2ee` mode requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID`, `TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD`,
`TRIX_XMPP_LIVE_SMOKE_THIRD_ID`, `TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD`,
`TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1`, and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`; it creates a private MUC, joins all three
accounts, checks owner/peer/third member-list visibility, explicitly trusts the
active OMEMO devices, sends one generated group message, and prints only
IDs/status. The `group-attachment` mode uses the same three-account variables,
validates the MUC member recipient set and trust graph, sends one generated
encrypted image attachment, waits for peer and third account download/decrypt,
and prints only IDs/status, byte counts, and image booleans.

From the repository root, the current Apple lanes are:

- `just trix-ios-build`
- `just trix-ios-run`
- `just trix-macos-build`
- `just trix-macos-run`

The old `matrix-*` just lanes remain as temporary compatibility aliases.

## Current Role

The checked-in Apple code is now the first XMPP client slice:

- shared SwiftUI views for iOS and macOS;
- iOS-specific Chats and Settings tabs with a dense inbox, prioritized pending
  invites, visible accept/decline buttons plus iOS swipe actions, capped unread
  badges, local mark-read-on-open, account/connection/push state summaries
  without token values, redacted diagnostics, chat bubbles, OMEMO-gated composer
  controls, and encrypted attachment download/preview/retry affordances;
- macOS-specific three-column workspace with dense room sidebar, selected-room
  timeline column, room inspector column, deterministic generated avatars, and
  Settings diagnostics for connection, push, and redacted local state;
- login/session UI;
- room list and timeline UI;
- composer and attachment affordances;
- settings/profile surfaces;
- service and view-model boundaries;
- mock service for local UI development;
- Martin-backed XMPP login, Keychain-backed session restore, logout, and
  roster-backed DM list;
- MartinOMEMO/libsignal linked into both targets for the OMEMO implementation
  path;
- Keychain-backed local OMEMO state for the account's registration id, identity
  key pair, prekeys, signed prekeys, sessions, identities, and sender keys;
- CryptoKit-backed AES-GCM engine for MartinOMEMO;
- explicit peer-device inventory, fingerprint display, and manual trust for DMs;
- Settings-based account device management for the current account: the app
  refreshes published OMEMO devices through MartinOMEMO, shows device IDs,
  fingerprints, active/trust state, and allows manual trust of one selected
  active account device only after fingerprint comparison;
- OMEMO encrypted DM text send after at least one active contact device is
  trusted;
- sender-side restart replay for new outbound messages is supported by including
  the current account's own OMEMO device in the MartinOMEMO recipient set for
  DM and group sends; older archived stanzas without that local recipient key
  remain unrecoverable without a reviewed recovery/key-backup path;
- day separators, sender/time-window clustering, sender names on the first
  incoming group cluster, local unread clearing, `You:` outgoing previews, and
  local-only hide/forget wording for DMs;
- reaction model/service/view-model/UI wiring with quick-reaction menu,
  aggregate chips, self-highlight, mock-service toggling, and a Martin-backed
  XEP-0444 stanza send/receive/cache path. Reaction metadata is visible to the
  private XMPP server, while product text and attachment sends remain gated on
  OMEMO trust/encryption. The `dm-reaction` live-smoke mode is wired for
  credentialed validation, but has not been run in this slice;
- multiline composer entry with macOS `Cmd+Return` send and newline-preserving
  drafts;
- encrypted DM attachment send/download through MartinOMEMO file encryption and
  XEP-0363 HTTP upload, with image dimensions preserved in the encrypted
  descriptor; on 2026-05-10 the credentialed `dm-attachment` live smoke passed
  upload, peer download, local decrypt, MIME, byte equality, and image
  classification without printing decrypted content, filenames, media keys, or
  secret URLs;
- encrypted group attachment send through the same local file-encryption and
  HTTP-upload path, gated on a validated MUC member recipient set and trusted
  active OMEMO devices for every group recipient; `group-attachment` live smoke
  passed on 2026-05-10 with peer and third-account download/decrypt validation;
- Martin-backed private MUC creation/join, members-only non-anonymous room
  configuration, persistent pending invite accept/decline after reconnect,
  member list, add-member, and remove-member operations. New Apple-created
  groups grant invited members MUC admin affiliation for the MVP UI, and member
  lists merge live occupants, affiliation results, and a Keychain known-member
  cache;
- macOS room inspector with contact/group people panels, common chat summaries,
  metadata, directory-backed member add/remove controls, and shared-media rows
  that can download encrypted attachments into the decrypted preview flow;
- OMEMO-gated group text send using MartinOMEMO multi-recipient encode for the
  known MUC member set;
- existing signing, entitlement, and TestFlight assumptions.

The current Apple XMPP dependency decision is Martin `3.2.4` plus MartinOMEMO
`2.2.3` and Tigase libsignal `1.0.0`. GPL/AGPL obligations are accepted for the
private non-commercial MVP/TestFlight path and recorded in
`docs/xmpp-migration/license-sbom.md`; broader distribution still needs the
source/license handling documented there.

Plaintext fallback is still blocked. DM text send now goes through MartinOMEMO
only after manual device trust. DM attachments are encrypted locally before
upload and the product composer keeps attachment send disabled until OMEMO send
is available. Group text send is wired through MartinOMEMO and remains blocked
unless every known group recipient has a trusted active OMEMO device; live
three-account group send/receive/decrypt validation passed on 2026-05-09. Group
attachment send now uses the encrypted attachment path, but the product UI only
enables the attachment picker after the service validates the MUC recipient set
and group OMEMO trust state. Credentialed DM and group attachment live-smoke
runs passed on 2026-05-10 with upload, download, decrypt, MIME/image, and byte
equality checks. The Matrix Rust SDK adapter has been removed from the new Apple
targets.

On macOS, downloaded attachments are previewed locally after decrypt and expose
Open, Share, and Export OS controls. The room inspector's shared-media section
uses the same service/view-model download path as the timeline; it does not add
plaintext server access or a separate file-transfer path.

The product session path stores the XMPP login material only in the app Keychain
record used by `TrixAppModel.start()` for restore. Logging out disconnects the
active XMPP session, removes that saved login record, clears in-memory account,
room, timeline, and verification state, and leaves local OMEMO identity/trust
state in Keychain so the client does not silently rotate devices or discard
trust decisions. Resetting OMEMO state is still a manual app-Keychain reset
operation, not a normal logout side effect.

Timeline restart behavior uses two layers. `XMPPMartinService.timeline(...)`
loads the room's Keychain-backed local timeline cache before querying MAM, then
merges any decryptable encrypted archive items back into the same bounded cache.
The `timeline-restart` live-smoke mode exercises this through a fresh service
instance and reports only counts. On 2026-05-10 the credentialed run passed with
MAM available, local cache loaded after restart, overlapping item IDs, and no
missing local recipient key for the newly sent sender-side stanza. This is a
fresh service/session restore check, not yet a full signed-app OS process
quit/relaunch harness.

The Device Verification And Recovery settings surface is explicit about the
current recovery limit. This MartinOMEMO slice does not provide a validated
server-side OMEMO key backup/recovery path, and the app does not implement one
itself. Reinstalling the app or resetting its Keychain state creates a new OMEMO
device. Old encrypted history that was not encrypted for that device can remain
unavailable, and replacement devices must be trusted only after comparing
fingerprints from an existing trusted session.

## Target Service Boundary

SwiftUI views should depend on view models, not XMPP or OMEMO APIs.

The target protocol-neutral boundary is:

- `TrixSessionStore`: secure local session and device material storage.
- `TrixAuthService`: login, logout, and session restore.
- `TrixSyncService`: room list, account state, and sync lifecycle.
- `TrixRoomService`: timeline, text send, attachments, reactions, typing, and
  read/delivery state.
- `TrixRoomMembershipService`: group member list, invite/add, remove, and the
  future server-backed leave path. The current group leave action is local-only
  and says so in the confirmation dialog.
- `TrixUserDirectoryService`: directory search and profile lookup/update through
  the Trix control plane.
- `TrixDeviceVerificationService`: OMEMO device inventory, trust state, and
  fingerprint presentation.
- `TrixPushRegistrationService`: APNs token registration and unregister.
- `TrixControlPlaneService`: account bootstrap, profile, group policy, and admin
  operations.

The current `Trix*` protocols and models implement this boundary while keeping
XMPP and OMEMO calls behind service and view-model layers.

## XMPP/OMEMO Implementation Gates

Do not wire production XMPP code directly into SwiftUI views. First close these
gates:

1. Confirm the Apple XMPP library path. Current first candidate: Martin
   `3.2.4` plus MartinOMEMO `2.2.3`.
2. Use Tigase Martin plus MartinOMEMO for the private non-commercial MVP path;
   GPL/AGPL obligations are accepted for that scope in
   `docs/xmpp-migration/license-sbom.md`.
3. Keep the license/SBOM record current before broader distribution.
4. Validate encrypted DM receive and live two-account DM send with `dm-e2ee`.
5. Validate encrypted group send/receive in a members-only, non-anonymous MUC.
6. Validate MAM restart/offline history.
7. Validate XEP-0444 DM reactions with `dm-reaction`.
8. Validate encrypted attachment upload/download with `dm-attachment` and
   `group-attachment`; both modes print only scrubbed status lines.
9. Live-validate the broader device trust UX with a second signed device. The
   Settings surface and manual per-device trust are wired; live second-device
   validation is still pending.
10. Validate APNs push without plaintext payloads.

Group OMEMO evidence from the checked libraries: Martin exposes `MucModule`
join/configuration/invite/affiliation APIs, and MartinOMEMO exposes
`encode(message:for:)` for multiple bare JIDs plus `decode(message:from:)` so
non-anonymous MUC messages can be decoded against the real sender JID. The app
uses those APIs only; it does not manipulate OMEMO keys directly. Group member
visibility is backed by live MUC state plus a local Keychain known-member cache;
older rooms where the current user is only a MUC member can still get forbidden
from ejabberd for affiliation-changing add/remove operations. The remaining
group blocker is broader restart/offline replay coverage, not live send/receive
or a custom crypto gap.

See [../docs/xmpp-migration/apple-omemo-feasibility.md](../docs/xmpp-migration/apple-omemo-feasibility.md)
and [../docs/xmpp-migration/spike-checklist.md](../docs/xmpp-migration/spike-checklist.md).

## Security Rules

- Do not add custom cryptography.
- Do not manually manipulate OMEMO key material.
- Do not add plaintext fallback for product DMs or groups.
- Do not silently trust all devices.
- Do not log XMPP passwords, auth tokens, OMEMO secrets, APNs tokens, decrypted
  message bodies, or decrypted attachment contents.
- Keep protocol calls behind service/view-model boundaries.

## Planned Cleanup

After the XMPP adapter grows encrypted messaging:

1. Remove the temporary `matrix-*` just lane aliases after downstream callers
   have moved to `trix-*`.
2. Add broader persistent tests around encrypted DM/group sync and
   directory/profile flows.
