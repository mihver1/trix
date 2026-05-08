# XMPP+OMEMO Implementation Plan

## Goals

Ship a private XMPP-backed Trix messenger with mandatory OMEMO for DMs and
groups, no federation, centralized Trix control-plane operations, and native
iOS and macOS clients with legacy feature parity.

The plan does not include Matrix history migration, Matrix bridging, or
compatibility with existing Matrix rooms. Users should treat the XMPP launch as
a new service boundary.

## Architecture Target

### XMPP Service

The XMPP service owns account authentication, roster state, message routing,
MUC or group-chat state, upload metadata, offline queues, and server-side
retention policy. It must run as a private service with federation disabled.

The server must support the XMPP extensions needed by the MVP:

- Client login over TLS.
- Stream management for reconnect behavior.
- Message carbons or equivalent multi-device delivery.
- Message archive management for sync and restart recovery.
- HTTP file upload or an equivalent server-managed attachment path.
- Private one-to-one messaging.
- Private group messaging.
- OMEMO device bundles and encrypted message distribution.

The final server package may live under `server/xmpp/`. For the product path,
ejabberd is the first candidate because the MVP needs centralized account, group,
push, diagnostics, and backup/restore operations. Prosody can remain as a
lightweight fallback for a shell-managed spike.

### Trix Control Plane

The Trix control plane is the operator-owned source of truth for:

- Account creation and disablement.
- Invite issuance and expiry.
- User display profile metadata owned by Trix.
- Group creation policy.
- Group membership changes.
- Device/session audit summaries where supported by the XMPP stack.
- Server health and backup status.

The Apple clients should not expose self-registration for the MVP. They should
consume Trix control-plane decisions and use XMPP only for messaging,
presence-compatible state, roster/group membership sync, encrypted message
delivery, and media transfer.

### Apple Clients

The product has two Apple clients:

- Native iOS SwiftUI client.
- Native macOS SwiftUI client.

Both clients should use shared protocol-neutral service protocols where practical:

- `TrixSessionStore`: secure local session and device material storage.
- `TrixAuthService`: login, logout, and session restore.
- `TrixSyncService`: connection lifecycle, roster, group list, and archive
  sync.
- `TrixRoomService`: DMs, groups, timelines, sends, reactions, receipts, and
  attachments.
- `TrixDeviceTrustService`: OMEMO capability checks, device lists, bundle handling,
  trust state, recovery/import flows if supported, and encrypted send gates.
- `TrixControlPlaneService`: account bootstrap, invites, profile, group policy,
  and admin operations.

SwiftUI views should use view models over those protocols. OMEMO calls must
stay inside the service layer.

## Implementation Order

### Phase 0: Spike Gates

Close the spike gates in [Spike Checklist](spike-checklist.md) before committing
to the client library and server stack.

Definition of done:

- Apple XMPP+OMEMO library choice is proven or rejected with a small local
  prototype.
- Private group OMEMO behavior is proven for at least three accounts.
- Multi-device behavior is understood and documented.
- Server choice has a working local private configuration.
- No unresolved spike is hidden as an implementation assumption.

Verification:

- Complete every required item in `spike-checklist.md`.
- Record the chosen libraries, server, and unsupported behaviors in this
  folder before implementation starts.

### Phase 1: Server Skeleton And Control Plane Contract

Create a local private XMPP service and a minimal Trix control-plane contract.

Definition of done:

- XMPP server starts locally with federation disabled.
- TLS-local or development TLS path is documented.
- Operator can create, disable, and inspect test accounts.
- Trix control-plane API shape is documented for account bootstrap and group
  membership.
- Backups and restore expectations are documented.
- Server logs do not contain passwords, access tokens, OMEMO key material, or
  decrypted message bodies.

Verification checklist:

- Start the local XMPP service.
- Confirm client login succeeds for two generated users.
- Confirm federation is disabled by attempting or inspecting remote-domain
  routing policy.
- Confirm account disablement prevents new client sessions.
- Restore a backup into a clean local server and log in with a test account.

### Phase 2: Apple Service Boundary

Introduce XMPP service protocols and mock implementations for iOS and macOS.

Definition of done:

- iOS and macOS build with the new service boundary.
- SwiftUI views do not call the XMPP library directly.
- Mock services cover login, room list, DM timeline, group timeline, invite,
  composer, attachment, and visible encryption states.
- Existing legacy and Matrix release tooling remains untouched unless a later
  task explicitly reopens that scope.

Verification commands:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

These commands are placeholders until the XMPP Apple target names are finalized.
Update them when the XMPP targets exist.

### Phase 3: Real XMPP Login And Sync

Wire the chosen XMPP client library behind the service protocols.

Definition of done:

- Login, logout, and session restore work on iOS and macOS.
- Room list includes DMs, groups, and pending invites.
- Timeline loads from live XMPP archive state after restart.
- Reconnect behavior is stable across app foreground/background transitions.
- Session material is stored in Keychain or another approved secure local
  store.
- No credentials or session tokens are logged.

Verification checklist:

- Log in on iOS.
- Log in on macOS.
- Quit and relaunch each client.
- Confirm session restore.
- Disable the account from the control plane.
- Confirm new sessions are rejected.
- Confirm logs redact credentials and message content.

### Phase 4: Mandatory OMEMO Messaging

Make OMEMO a hard send/join requirement for DMs and groups.

Definition of done:

- New DM creation fails closed if OMEMO cannot be enabled.
- New group creation fails closed if OMEMO cannot be enabled for all required
  participants.
- Sending a message fails closed when the active conversation is not encrypted.
- The UI shows an actionable blocked state for missing device bundles,
  unsupported devices, or untrusted devices.
- Server storage contains encrypted payloads only for DM and group message
  bodies.
- The app does not implement custom encryption or manually manipulate OMEMO key
  material outside library APIs.

Verification checklist:

- Create an encrypted DM between two accounts.
- Send and receive text in both directions.
- Create an encrypted group with at least three accounts.
- Send and receive text from multiple participants.
- Inspect server-side stored message payloads and confirm no plaintext bodies.
- Remove or break a participant device bundle and confirm the send path blocks
  rather than falling back to plaintext.

### Phase 5: Legacy Parity Features

Implement parity features using the legacy product as the behavior target, not
as code to copy.

Definition of done:

- The [Parity Checklist](parity-checklist.md) is complete or explicitly
  deferred with owner and reason.
- iOS and macOS both cover login, inbox, DMs, groups, attachments, reactions,
  unread/read/delivery state, typing or equivalent composing state, profile,
  directory, settings, device/account state, and release flows.
- Control-plane admin operations cover account bootstrap, group membership,
  system status, and diagnostics needed by the private service.

Verification checklist:

- Run the parity checklist on iOS.
- Run the parity checklist on macOS.
- Run local server restore validation.
- Run attachment round-trip validation.
- Run multi-device validation.
- Run TestFlight archive validation for each Apple client once release targets
  exist.

### Phase 6: Launch Readiness

Validate the private deployment path and operational runbooks.

Definition of done:

- Production server configuration is documented.
- Federation is disabled in production.
- Registration is operator-controlled.
- Backups and restore are tested.
- Monitoring and log redaction are validated.
- iOS and macOS install paths are validated.
- Known limitations are visible in docs and UI.

Verification checklist:

- Provision a fresh production-like server.
- Create test users through the control plane.
- Run encrypted DM and group smoke tests.
- Run backup/restore drill.
- Archive and install both Apple clients.
- Confirm no plaintext message bodies, credentials, or OMEMO secrets appear in
  logs.

## Documentation Definition Of Done

Before implementation is considered complete:

- This folder reflects the final server and Apple library choices.
- Spike results are recorded as accepted decisions or open blockers.
- Parity status is current.
- Risk register has no unowned high-severity risks.
- Verification commands match the actual target names and server paths.
