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
- Remote pushes are accepted only as the Trix sync notification contract:
  `aps.content-available=1` plus `trix.type=sync`, optional `trix.account`,
  optional `trix.room`, and optional badge metadata. The only accepted visible
  APNs alert is generic: title `Trix` with `New encrypted message` or unread-count
  wording. Payloads with plaintext/body outside that generic alert, decrypted
  content, filename, attachment-name, or notification-profile fields are ignored
  by the app.
- Foreground notification presentation is suppressed for this target; remote
  pushes refresh local encrypted state. Inactive visible APNs are shown by the
  system, while legacy silent sync payloads may still create a generic local
  notification after local sync. Those local fallback notifications honor
  per-room default, muted, and mentions-only profiles after decrypted local state
  has been refreshed.
- Per-room notification profiles are stored locally in an AES-GCM encrypted
  Application Support file with the encryption key in Keychain, and are backed by
  a private XMPP PEP item under `urn:softgrid:trix:notification-profiles:1`.
  They are never copied into APNs payloads.

Current MVP status: `server/xmpp` enables ejabberd `mod_push` and the checked-in
`trix-push-gateway` provides the private XEP-0114 component that accepts
Martin/Tigase APNs token registration, maps XEP-0357 nodes, signs APNs requests,
and emits the generic sync notification contract above. On 2026-05-10 the
gateway was deployed on the VPS with deployment-local APNs token-auth material
and connected to ejabberd as `push.trix.selfhost.ru`. Signed macOS APNs smoke
passed on 2026-05-20 with gateway/APNs provider acceptance and QA-visible
notification text limited to the generic Trix alert. On 2026-06-01 the live
deployment was adjusted so XMPP component publishes produce silent APNs sync
wakes while visible notification text remains local and generic after sync.

Optional live smoke modes are available through `TRIX_XMPP_LIVE_SMOKE_MODE`:
`login`, `session-restore`, `roster`, `room-list`, `search`, `peer-devices`,
`second-device-fingerprint`, `own-device-revocation`, `trust-peer`, `profile`,
`device-passport`, `profile-update`, `timeline`, `send-timeline`, `timeline-restart`,
`group-timeline-restart`, `dm-backfill-repair`,
`timeline-relaunch-seed`, `timeline-relaunch-verify`, `dm-e2ee`,
`dm-reaction`, `dm-reply`, `dm-edit-retract`, `dm-attachment`,
`delivery-receipt`, `typing`, `blocked-send`, `group-e2ee`,
`group-attachment`, `group-mention`, `group-thread`, `group-leave`,
`group-call-lab-media`, `call-echo-assistant`, and `read-markers`.
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

Persistent encrypted sync and process-relaunch gate:

```bash
cd apple

TRIX_XMPP_LIVE_SMOKE_USER_ID=test@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_PEER_ID=friend@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_THIRD_ID=third@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD='...' \
./scripts/run-persistent-sync-gate.sh
```

The wrapper runs `timeline-restart`, `group-timeline-restart`, and
`dm-backfill-repair` without Keychain-backed smoke storage by default. The
Keychain-specific process
quit/relaunch proof (`timeline-relaunch-seed` then `timeline-relaunch-verify`)
is skipped unless `--include-keychain-relaunch` is provided; that opt-in sets
`TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN=1` for the relaunch processes only. The
wrapper self-skips with an explicit status line when required credentials are
missing. The relaunch proof requires a signed macOS app executable by default;
pass `--allow-unsigned` only for local non-release debugging.

The runner prints only `TRIX_XMPP_LIVE_SMOKE` status lines and must not print
passwords, auth tokens, OMEMO secrets, or decrypted message bodies. The
`room-list` mode follows the UI reload path by loading rooms and invitations.
The `search` mode also requires `TRIX_XMPP_LIVE_SMOKE_SEARCH_TERM`. The vCard
directory returns local users through `vjud.trix.selfhost.ru`, and the client
does substring filtering locally so prefix queries such as `fri` can match
`friend@trix.selfhost.ru`. The `peer-devices` mode requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID` and refreshes the contact's published OMEMO
devices without printing fingerprints or visual fingerprint challenges. The
`second-device-fingerprint` mode logs into the same account through a second
isolated local profile (`TRIX_XMPP_LIVE_SMOKE_SECOND_DEVICE_PROFILE` base name),
verifies two distinct OMEMO device IDs, checks local/second fingerprint
presence, and fails if the second device is silently trusted. The
`own-device-revocation` mode uses the same isolated second-device setup, revokes
the second account device through the reviewed MartinOMEMO revocation API, and
verifies the target device is removed or marked inactive in refreshed published
device state. It accepts optional
`TRIX_XMPP_LIVE_SMOKE_REVOKE_DEVICE_ID` to target a specific own device ID. The
`device-passport` mode requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID`,
`TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD`, `TRIX_XMPP_LIVE_SMOKE_THIRD_ID`,
`TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD`, and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`; it expects the primary signed-in device to
already be Device Passport approved or reset-rooted. The mode logs in an
isolated second same-account profile, fails if that device is silently trusted,
approves it through Device Passport, sends the OMEMO-encrypted approval
descriptor from the primary device, requires a prior-trust account to auto-apply
the claim, and requires a no-prior-trust account to keep only a pending notice.
It does not call the operator reset route; reset remains server/operator-only and
is covered by the server smoke below. The
`session-restore` mode saves the
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
only IDs and MAM/cache counts, including scanned archive pages, whether the scan
reached the archive start, and whether archived sender stanzas are missing a
local recipient key. The `group-timeline-restart` mode uses the same
three-account variables as `group-e2ee`, sends one OMEMO group message, restores
through a fresh service instance, and requires timeline overlap after restart.
The `dm-backfill-repair` mode uses `TRIX_XMPP_LIVE_SMOKE_PEER_ID`,
`TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD`, `TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1`, and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`: it sends an encrypted DM before logging
in a fresh same-account local profile, verifies MAM saw a sender stanza missing
the fresh device's local recipient key, then waits for the item to appear via an
encrypted timeline-backfill response. It prints only IDs, device ids, counts,
and booleans.
`timeline-relaunch-seed` stores a scrubbed overlap marker plus a smoke Keychain
session, while `timeline-relaunch-verify` runs in a second process, restores from
that saved session without requiring a password variable, and requires overlap.
Those relaunch modes are the explicit Keychain smoke lane and should be run with
`TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN=1` or
`./scripts/run-persistent-sync-gate.sh --include-keychain-relaunch`. The
relaunch modes accept
`TRIX_XMPP_LIVE_SMOKE_RELAUNCH_MARKER_PATH`,
`TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_SERVICE`,
`TRIX_XMPP_LIVE_SMOKE_RELAUNCH_SESSION_ACCOUNT`, and optional
`TRIX_XMPP_LIVE_SMOKE_RELAUNCH_CLEANUP=0` for debug retention. The `dm-e2ee` mode also requires
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

The conversation-XEP smoke entrypoints `dm-reply`, `dm-edit-retract`,
`group-mention`, `group-thread`, `group-leave`, and `read-markers` are wired as scrubbed
feature probes in this checkout. They validate required environment shape, use
the shared metadata request APIs and Martin send/parse surfaces, and then
validate live metadata when credentials are supplied:
`dm-reply` requires the two-account DM variables; `dm-edit-retract` requires the
same two-account DM variables; `group-mention`, `group-thread`, and
`group-leave` require the three-account group variables; `read-markers` requires
the owner account plus a peer account. `group-leave` validates non-owner leave,
room removal from the leaver account, remaining-member visibility, and blocked
sends after leave. These modes print only IDs/counts/booleans/status tokens and
must not print message bodies, credentials, OMEMO secrets, filenames, local
paths, or raw stanza payloads. `read-markers` sends XEP-0333 displayed markers and
validates same-account convergence through the private Trix read-cursor node,
because ejabberd/Martin marker archive/carbon delivery is not reliable enough
for unread sync. The remaining proof is restart/reload coverage and stable
group target ids for mention/thread metadata.

The `group-call-lab-media` mode is the deterministic reduced macOS call-lab
driver. It requires the same three-account variables as `group-e2ee`, creates a
fresh private MUC, joins all accounts before call control, explicitly trusts the
active OMEMO devices when `TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`, and then drives
the existing `TrixCallViewModel`, `HTTPCallControlService`, encrypted call
descriptor, and `TrixLiveKitMediaCallService` path for two group-voice
participants. The Apple-side local lab wrapper runs it with relay-only ICE and
audio probes enabled:

```bash
cd apple

TRIX_XMPP_LIVE_SMOKE_USER_ID=test@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_PEER_ID=friend@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_THIRD_ID=third@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD='...' \
./scripts/run-local-call-lab-macos.sh evidence
```

The wrapper starts the loopback LiveKit/coturn/call-control lab, captures an
evidence bundle under `apple/build/LocalCallLabEvidence/`, and runs
`server/xmpp/scripts/call-log-audit.sh` against it. The bundle must contain only
scrubbed smoke lines and sanitized app/call-control/LiveKit/coturn logs.

Encrypted-call echo diagnostics are tracked separately in
`docs/tasks/2026-05-25-live-call-echo-bot.md`. The intended assistant is a
normal disposable XMPP account that joins only disposable smoke rooms on
`trix.selfhost.ru` or the local call lab, receives media keys only through
OMEMO-encrypted call descriptors, and prints only scrubbed status lines.
The current `call-echo-assistant` live smoke mode creates a fresh private MUC
with owner, peer, and echo disposable accounts, trusts the active OMEMO devices
through the smoke-only trust gate, and drives the owner and echo account through
the normal relay-only E2EE LiveKit group-voice join path with the echo
remote-audio probe enabled. Use the live wrapper to build the macOS smoke app,
run the assistant, capture scrubbed status lines, and audit the evidence bundle:

```bash
cd apple

TRIX_XMPP_LIVE_SMOKE_USER_ID=test@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_PEER_ID=friend@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD='...' \
TRIX_XMPP_LIVE_SMOKE_ECHO_ID=tri21echo@trix.selfhost.ru \
TRIX_XMPP_LIVE_SMOKE_ECHO_PASSWORD='...' \
./scripts/run-live-call-echo-assistant-macos.sh evidence
```

For the current forced-relay blocker, set `TRIX_CALL_LIVEKIT_DEBUG_LOGS=1` on
`run-live-call-echo-assistant-macos.sh` or `run-local-call-lab-macos.sh` evidence
runs. The wrapper then captures `io.livekit.sdk` RTC debug lines in
`apple-oslog.log` without printing LiveKit tokens, TURN credentials, media keys,
or decrypted content.

The 2026-05-26 live echo-assistant evidence passed after the live Docker media
deployment switched coturn to `external-ip=<public-ip>/<coturn-container-ip>` and
LiveKit to a Docker-private `rtc.node_ip` allowed by coturn. Evidence bundle:
`apple/build/LiveCallEchoEvidence/post-livekit-private-node-20260526T204403Z`.
That proof used UDP TURN on `3478`; after the run, coturn TLS key ownership was
corrected for both ejabberd and coturn because the live deployment shares
`certs/*.pem`, and `turns:trix.selfhost.ru:5349` was reachable again.

Echo-assistant evidence is diagnostic-only: it can make manual media debugging
easier, but it does not close the encrypted-calls MVP item without the real
signed-device DM video, group voice, forced TURN relay, and log-audit proof.
The pinned LiveKit Swift `2.9.0` path exposes video buffer publishing through
`BufferCapturer`; delayed audio echo still needs a reviewed public API for
publishing replayed PCM from the Apple client. Until those layers land, the
mode reports `delayed_audio_echo=false` and `delayed_video_echo=false`; do not
fake them by giving a server-side process decrypted media keys.

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
  badges that preserve/increment for inactive-room preview updates, local
  mark-read-on-open, account/connection/push state summaries without token
  values, redacted diagnostics, chat bubbles, OMEMO-gated composer controls,
  inline previews for supported encrypted image attachments, and encrypted
  attachment download/preview/retry affordances;
- macOS-specific three-column workspace with dense room sidebar, selected-room
  timeline column, room inspector column, deterministic generated avatars, and
  Settings diagnostics for connection, push, and redacted local state;
- iOS and macOS generic push handling that requests notification permission,
  avoids marking rooms read while inactive, and shows only generic
  encrypted-message/unread-count notifications without decrypted body text or
  attachment names, with per-room default/muted/mentions-only controls in each
  room;
- login/session UI plus invite-code account creation from the login screen,
  invite-code issuing from Settings for signed-in accounts, and Settings-based
  password change that updates the saved Keychain session password only after the
  server accepts the new password;
- room list and timeline UI;
- composer and attachment affordances;
- settings/profile surfaces;
- service and view-model boundaries;
- mock service for local UI development;
- Martin-backed XMPP login, invite-code issuing/registration, password-change
  handoff to the account wrapper, Keychain-backed session restore, logout, and
  roster-backed DM list;
- MartinOMEMO/libsignal linked into both targets for the OMEMO implementation
  path;
- Keychain-backed local OMEMO state for the account's registration id, identity
  key pair, prekeys, signed prekeys, sessions, identities, and sender keys;
- CryptoKit-backed AES-GCM engine for MartinOMEMO;
- explicit peer-device inventory, visual fingerprint display, hidden technical
  fingerprint disclosure, and manual trust for DMs;
- Settings-based account device management for the current account: the app
  refreshes published OMEMO devices through MartinOMEMO, shows device IDs,
  visual fingerprint challenges, active/trust state, and allows manual trust
  of one selected active account device only after visual comparison;
- OMEMO encrypted DM text send after at least one active contact device is
  trusted;
- sender-side restart replay for new outbound messages is supported by including
  the current account bare JID alongside peer/group recipients, so MartinOMEMO
  fanout covers the sender's own published devices as well as addressed
  recipients;
- DM and group timeline sync can repair old MAM ciphertext that lacks a local
  recipient key by sending an OMEMO-encrypted timeline-backfill request; an
  updated client that can still decrypt the original item responds with an
  OMEMO-encrypted timeline-backfill descriptor that reconstructs the timeline
  item without showing service JSON in chat. Group repair descriptors use the
  joined MUC member set and remain blocked unless every repair recipient has a
  trusted active OMEMO device;
- new encrypted sends refresh the current account's published OMEMO devices and
  are blocked while another active account device is still untrusted, so a
  sender cannot create fresh ciphertext that their other signed-in client cannot
  decrypt;
- manual encrypted DM timeline refresh uses bounded MAM pagination instead of a
  single 50-item tail query, scanning the peer-filtered archive up to 6 pages /
  300 archived stanzas. If the server returns an empty peer-filtered page, the
  unfiltered fallback scans deeper for matching peer stanzas instead of stopping
  at the noisy account-wide tail. Live-smoke diagnostics report page depth and
  raw scanned counts;
- day separators, sender/time-window clustering, sender names on the first
  incoming group cluster, local unread preservation for inactive rooms, local
  unread clearing on open, `You:` outgoing previews, and local-only hide/forget
  wording for DMs;
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
  secret URLs. Supported image attachments (`gif`, `heic`, `heif`, `jpeg`,
  `jpg`, `png`, `webp`, plus image MIME types) render inline in the iOS and
  macOS timeline after local decrypt when their encrypted descriptor carries a
  bounded original size;
- Telegram static sticker import through the app-facing XMPP account wrapper,
  a per-account local sticker library encrypted under Application Support with
  a Keychain-held key, a composer sticker picker, received Telegram sticker pack
  import, and sticker timeline rendering. Sticker sends reuse the encrypted
  attachment path and remain gated on the same OMEMO availability, recipient,
  and trust checks as normal attachments. Animated `.TGS` and video `.WEBM`
  Telegram stickers are skipped in v1 and reported as unsupported;
- encrypted group attachment send through the same local file-encryption and
  HTTP-upload path, gated on a validated MUC member recipient set and trusted
  active OMEMO devices for every group recipient; `group-attachment` live smoke
  passed on 2026-05-10 with peer and third-account download/decrypt validation;
- Martin-backed private MUC creation/join, members-only non-anonymous room
  configuration, persistent pending invite accept/decline after reconnect,
  member list, add-member, and remove-member operations. New Apple-created
  groups grant invited members MUC admin affiliation for the MVP UI, and member
  lists merge live occupants, affiliation results, and an encrypted local
  known-member file cache whose key is stored in Keychain;
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
equality checks. Sticker sends use the same attachment send gate and encrypted
descriptor path; credentialed `dm-sticker` and `group-sticker` live-smoke modes
are not wired in this slice. The Matrix Rust SDK adapter has been removed from
the new Apple targets.

On iOS and macOS, supported encrypted image attachments get inline timeline
previews from the same local-decrypt service path as the full attachment
preview. On macOS, downloaded attachments are previewed locally after decrypt
and expose Open, Share, and Export OS controls. The room inspector's
shared-media section uses the same service/view-model download path as the
timeline; it does not add plaintext server access or a separate file-transfer
path.

The product session path stores the XMPP login material only in the app Keychain
record used by `TrixAppModel.start()` for restore. Logging out disconnects the
active XMPP session, removes that saved login record, clears in-memory account,
room, timeline, and verification state, and leaves local OMEMO identity/trust
state in Keychain so the client does not silently rotate devices or discard
trust decisions. Resetting OMEMO state is still a manual app-Keychain reset
operation, not a normal logout side effect.

Timeline restart behavior uses two layers. `XMPPMartinService.timeline(...)`
loads the room's local encrypted timeline file cache before querying MAM, then
merges any decryptable encrypted archive items back into the same bounded cache.
The file cache is encrypted with a small cache key stored in Keychain, while
message history itself is not stored as Keychain generic-password blobs.
Cold session restore also loads an encrypted room-summary file cache before the
server room-list refresh starts. The room-list payload is stored in Application
Support, not Keychain; Keychain stores only the room-summary cache key.
The `timeline-restart` and `group-timeline-restart` live-smoke modes exercise
DM and group overlap through fresh service restore and report only scrubbed
counts/IDs/booleans. The `dm-backfill-repair` live-smoke mode is the specific
same-account new-device repair gate for old DM archive rows that were not
encrypted to the new device, and it is part of
`./scripts/run-persistent-sync-gate.sh` by default. `timeline-relaunch-seed` and
`timeline-relaunch-verify` provide the process-level quit/relaunch harness by
persisting a smoke Keychain session and marker in one process and verifying
overlap in a second process. Keep MVP checklist items open until this wrapper
is run successfully with disposable live credentials on a signed app build.

The Device Verification And Recovery settings surface is explicit about the
current recovery limit. This MartinOMEMO slice does not provide a validated
server-side OMEMO key backup/recovery path, and the app does not implement one
itself. Reinstalling the app or resetting its Keychain state creates a new OMEMO
device. DM and group history that was not encrypted for that device can now be
repaired only when an updated peer, own client, or group member client that
still has decryptable plaintext comes online and answers the encrypted
timeline-backfill request. Group repair still requires joined MUC membership
resolution plus trusted active OMEMO devices for every repair recipient.
Replacement devices must be trusted only after comparing the visual fingerprint
from an existing trusted session. The current visual flow is a deterministic
display transform over the MartinOMEMO identity
fingerprint; it is not an interactive SAS exchange.

## Target Service Boundary

SwiftUI views should depend on view models, not XMPP or OMEMO APIs.

The target protocol-neutral boundary is:

- `TrixSessionStore`: secure local session and device material storage.
- `TrixRegistrationService`: invite issuing, unauthenticated invite redemption
  before a normal XMPP login, and signed-in account password change through the
  Trix wrapper.
- `TrixStickerImportService`: signed-in Telegram sticker-pack import and
  server-proxied sticker file download through the same app-facing wrapper.
- `TrixAuthService`: login, logout, and session restore.
- `TrixSyncService`: cached and live room list, account state, and sync
  lifecycle.
- `TrixRoomService`: timeline, text send, attachments, reactions, typing, and
  read/delivery state.
- `TrixRoomMembershipService`: group member list, invite/add, remove, and
  server-backed leave. Non-owner group leave goes through the Trix
  control-plane wrapper before local MUC leave so the room is hidden only after
  server membership removal succeeds.
- `TrixUserDirectoryService`: directory search, profile lookup/update, and
  compact online/last-seen activity lookup for direct chat and profile surfaces
  through the XMPP-backed client path.
- `TrixDeviceVerificationService`: OMEMO device inventory, trust state, visual
  fingerprint presentation, and hidden technical fingerprint disclosure.
- `TrixPushRegistrationService`: APNs token registration and unregister.
- `TrixCallControlService`: call-control authorization, LiveKit token requests,
  DM callee joins by opaque call ID, and TURN credentials.
- `TrixCallDescriptorService`: OMEMO-encrypted call invite, answer, end, voice
  room state, and media-key rotation descriptors. Sends use the same recipient
  set and trust gates as encrypted chat sends.
- `TrixMediaCallService`: LiveKit media connection lifecycle with client-side
  media E2EE required. For signed-device TURN smoke only, launching the app with
  `TRIX_CALL_FORCE_RELAY_ONLY=1` makes the LiveKit adapter request relay-only
  ICE transport policy; normal product launches keep the default ICE policy.
  The audio publish path uses an explicit Opus voice profile by default
  (`TRIX_CALL_AUDIO_PROFILE=voice`, 48 kbps, no DTX, no RED). Use
  `loss-resilient` to keep RED enabled without DTX, or `livekit-default` to
  compare against LiveKit Swift's default DTX+RED behavior during diagnostics.
  The video publish path defaults to an Apple hardware-friendly H.264 profile
  (`TRIX_CALL_VIDEO_PROFILE=apple-h264`, 960x540 capture, 24 fps, 800 kbps, no
  simulcast) with VP8 as the LiveKit backup codec. Use `apple-h264-low` for
  constrained-link diagnostics, `apple-hevc` only as an explicit HEVC/H.265
  interop check, or `livekit-default` to compare against LiveKit Swift defaults.
  The macOS app entitlement set includes outgoing and incoming network access,
  camera, and microphone because signed macOS WebRTC media sockets need the
  sandbox network capability in both directions.
- `TrixCallViewModel`: shared call UI state for the DM video button, incoming
  accept/decline/end actions, and group voice-room join/leave participant state.
  Its lifecycle contract is the UI source of truth for idle, ringing,
  connecting, active, reconnecting, ending, ended, and failed states so stale
  incoming bars, active room indicators, and platform call surfaces clear from
  one state path. Group rooms publish voice-room state only; they do not surface
  ringing UI.
- `TrixControlPlaneService`: account bootstrap, profile, group policy, and admin
  operations.

The current `Trix*` protocols and models implement this boundary while keeping
XMPP and OMEMO calls behind service and view-model layers.

## XMPP/OMEMO Implementation Gates

Do not wire production XMPP code directly into SwiftUI views. Keep these gates
accurate as the implementation changes:

1. Confirm the Apple XMPP library path. Current first candidate: Martin
   `3.2.4` plus MartinOMEMO `2.2.3`.
2. Use Tigase Martin plus MartinOMEMO for the private non-commercial MVP path;
   GPL/AGPL obligations are accepted for that scope in
   `docs/xmpp-migration/license-sbom.md`.
3. Keep the license/SBOM record current before broader distribution.
4. Encrypted DM receive and live two-account DM send are validated with
   `dm-e2ee`.
5. Encrypted group send/receive in a members-only, non-anonymous MUC is
   validated with three accounts.
6. MAM restart/offline history is validated for current-device decryptable DM
   and group stanzas; older sender-side stanzas without a local recipient key
   remain blocked on reviewed recovery/backfill.
7. XEP-0444 DM reactions are wired; use `dm-reaction` for focused live
   validation after reaction changes.
8. Encrypted attachment upload/download is validated with `dm-attachment` and
   `group-attachment`; both modes print only scrubbed status lines.
9. Validate static Telegram sticker import, local encrypted library
   persistence, and received Telegram sticker pack import. The checked-in unit
   tests cover URL parsing, save/load/dedup, descriptor metadata flow, and
   received-pack import; live credentialed sticker-send smoke remains optional
   follow-up work.
10. Live-validate the broader device trust UX with a second signed device. The
   Settings surface and manual per-device visual fingerprint trust are wired;
   live second-device validation is still pending.
11. APNs push without plaintext payloads is validated for signed macOS and the
    shared iOS/macOS plumbing. Keep separate physical iOS evidence if the
    release gate requires it.

Group OMEMO evidence from the checked libraries: Martin exposes `MucModule`
join/configuration/invite/affiliation APIs, and MartinOMEMO exposes
`encode(message:for:)` for multiple bare JIDs plus `decode(message:from:)` so
non-anonymous MUC messages can be decoded against the real sender JID. The app
uses those APIs only; it does not manipulate OMEMO keys directly. Group member
visibility is backed by live MUC state plus a local encrypted known-member file
cache whose key is stored in Keychain;
older rooms where the current user is only a MUC member can still get forbidden
from ejabberd for owner-only add/remove operations. Non-owner leave is
owner-assisted through the Trix control-plane wrapper. The remaining group
blocker is broader restart/offline replay coverage, not live send/receive or a
custom crypto gap.

See [../docs/xmpp-migration/apple-omemo-feasibility.md](../docs/xmpp-migration/apple-omemo-feasibility.md)
and [../docs/xmpp-migration/spike-checklist.md](../docs/xmpp-migration/spike-checklist.md).

## Security Rules

- Do not add custom cryptography.
- Do not manually manipulate OMEMO key material.
- Do not add plaintext fallback for product DMs or groups.
- Do not silently trust all devices.
- Do not log XMPP passwords, auth tokens, OMEMO secrets, APNs tokens, decrypted
  message bodies, or decrypted attachment contents.
- Do not log Telegram bot tokens, sticker token secrets, signed sticker file
  tokens, Telegram file paths, or decrypted sticker bytes.
- Keep protocol calls behind service/view-model boundaries.

## Planned Cleanup

Remaining cleanup:

1. Remove the temporary `matrix-*` just lane aliases after downstream callers
   have moved to `trix-*`.
2. Keep the persistent sync and directory/profile smoke wrappers current when
   the service boundary changes.
