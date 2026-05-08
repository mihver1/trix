# Trix Apple Client

This directory contains the current native SwiftUI Apple scaffold for iOS and
macOS.

The project is in transition. The active product direction is XMPP + OMEMO, but
many files, targets, and type names are still Matrix-named from the previous
experiment. Treat that naming as temporary scaffolding, not the protocol
direction.

There are no live Matrix users to preserve, so the Apple migration does not need
a Matrix bridge, Matrix history import, Matrix device migration, or parallel
Matrix operation.

## Targets

Current target names remain Matrix-named until the protocol-neutral rename lands:

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

Optional live smoke modes are available through `TRIX_XMPP_LIVE_SMOKE_MODE`:
`login`, `roster`, `room-list`, `search`, `peer-devices`, `trust-peer`,
`timeline`, `send-timeline`, and `blocked-send`.
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
devices without printing fingerprints. The `trust-peer` mode requires
`TRIX_XMPP_LIVE_SMOKE_PEER_ID` and `TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST=1`; it
trusts one active OMEMO device for explicit smoke setup only. The `blocked-send`
mode also requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID`; it creates or refreshes a
direct roster entry, then treats `e2eeUnavailable` or missing OMEMO trust as
success because plaintext fallback must stay blocked. The `timeline` mode also
requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID`; it loads the encrypted MAM-backed
timeline and prints only counts, never message bodies. The `send-timeline` mode
requires `TRIX_XMPP_LIVE_SMOKE_PEER_ID` and
`TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND=1`; it sends one generated OMEMO message and
then reloads the timeline, still printing only IDs and counts.

From the repository root, the current Apple lanes are still named after the old
Matrix experiment:

- `just matrix-ios-build`
- `just matrix-ios-run`
- `just matrix-macos-build`
- `just matrix-macos-run`

Rename these lanes after the XMPP targets exist.

## Current Role

The checked-in Apple code is now the first XMPP client slice:

- shared SwiftUI views for iOS and macOS;
- login/session UI;
- room list and timeline UI;
- composer and attachment affordances;
- settings/profile surfaces;
- service and view-model boundaries;
- mock service for local UI development;
- Martin-backed XMPP login, session restore, and roster-backed DM list;
- MartinOMEMO/libsignal linked into both targets for the OMEMO implementation
  path;
- Keychain-backed local OMEMO state for the account's registration id, identity
  key pair, prekeys, signed prekeys, sessions, identities, and sender keys;
- CryptoKit-backed AES-GCM engine for MartinOMEMO;
- explicit peer-device inventory, fingerprint display, and manual trust for DMs;
- OMEMO encrypted DM text send after at least one active contact device is
  trusted;
- existing signing, entitlement, and TestFlight assumptions.

Plaintext fallback is still blocked. DM text send now goes through MartinOMEMO
only after manual device trust. Incoming encrypted DM decrypt, encrypted
attachments, and encrypted group-chat handling are still pending. The Matrix Rust
SDK adapter and Matrix live smoke runner have been removed from the new Apple
targets.

## Target Service Boundary

SwiftUI views should depend on view models, not XMPP or OMEMO APIs.

The target protocol-neutral boundary is:

- `TrixSessionStore`: secure local session and device material storage.
- `TrixAuthService`: login, logout, and session restore.
- `TrixSyncService`: room list, account state, and sync lifecycle.
- `TrixRoomService`: timeline, text send, attachments, reactions, typing, and
  read/delivery state.
- `TrixRoomMembershipService`: group member list, invite/add, remove, and leave.
- `TrixDirectoryService`: directory search and profile lookup/update through the
  Trix control plane.
- `TrixDeviceTrustService`: OMEMO device inventory, trust state, and fingerprint
  presentation.
- `TrixPushRegistrationService`: APNs token registration and unregister.
- `TrixControlPlaneService`: account bootstrap, profile, group policy, and admin
  operations.

The current `Matrix*` protocols and models can be renamed into this shape before
the XMPP adapter is wired.

## XMPP/OMEMO Implementation Gates

Do not wire production XMPP code directly into SwiftUI views. First close these
gates:

1. Confirm the Apple XMPP library path. Current first candidate: Martin
   `3.2.4` plus MartinOMEMO `2.2.3`.
2. Spike Tigase Martin plus MartinOMEMO first, because this is a non-commercial
   friends app and GPL/AGPL obligations may be acceptable.
3. Record the license/SBOM decision before shipping.
4. Validate encrypted DM receive and live two-account DM send.
5. Validate encrypted group send/receive in a members-only, non-anonymous MUC.
6. Validate MAM restart/offline history.
7. Validate encrypted attachment upload/download.
8. Validate broader device trust UX without silent trust-all.
9. Validate APNs push without plaintext payloads.

Known MartinOMEMO risk: the checked version wires sender-key store callbacks with
an apparent upstream `user_data` bug, so group OMEMO must remain blocked until a
local patch, upstream fix, or alternate group path is validated.

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

1. Rename targets away from `TrixMatrix*`.
2. Rename `Matrix*` app/model/service/view files to `Trix*` or `XMPP*` where
   appropriate.
3. Replace `just matrix-*` lanes with XMPP Apple lanes.
4. Add TestFlight archive/upload paths for the XMPP Apple app.
