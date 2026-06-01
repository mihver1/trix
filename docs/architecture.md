# Architecture

## Goal

Trix is moving to XMPP + OMEMO so the project can use a mature messaging
transport and an existing end-to-end encryption protocol instead of carrying a
custom application protocol or custom cryptography.

The MVP architecture is intentionally small:

- One private XMPP server.
- Federation disabled.
- Native SwiftUI Apple clients for iOS and macOS.
- Mandatory OMEMO encryption for direct messages and group chats.
- Members-only, non-anonymous MUC rooms for groups.
- A Trix-owned control plane for users, directory, profiles, groups, diagnostics,
  and operations.
- Local secure session and OMEMO state storage on device.

There are no live Matrix users to preserve, so the target architecture does not
include a Matrix bridge, Matrix room migration, or a parallel Matrix service.

## Components

### XMPP Server

ejabberd is the first product server candidate because the MVP needs centralized
account, group, push, diagnostics, and backup/restore operations. Prosody remains
a useful lightweight fallback for a shell-managed spike, but it should not be
treated as the product default unless the control-plane requirement is reduced.

The intended domain is `trix.selfhost.ru`. The same domain can be reused because
the Matrix path has no live users.

The server is responsible for:

- XMPP client-to-server sessions.
- Local account authentication.
- Message routing.
- MUC group rooms.
- SQLite-backed Message Archive Management for encrypted stanzas.
- HTTP file sharing/upload for encrypted media payloads.
- Push integration hooks.

The server must not decrypt Trix message content. For product DM and group chats,
stored messages and uploaded media are expected to be encrypted by the client
before they reach the server.

### Federation Boundary

Federation is disabled because Trix is a private messenger for a small known
group. That removes server-to-server trust, public registration pressure,
cross-domain moderation, and external abuse handling from the MVP.

Disabling federation requires both application config and deployment checks:

- Do not load the XMPP server-to-server module.
- Do not expose port `5269`.
- Do not document DNS SRV records for server-to-server federation.
- Verify from outside the host that client-to-server traffic works and
  server-to-server traffic does not.

This does not remove the need for TLS, backups, device trust UX, push hygiene, or
careful account recovery.

### Apple Clients

The Apple clients are SwiftUI and keep protocol/session logic out of views.

The target service boundary is protocol-neutral:

- `TrixSessionStore`: secure session persistence.
- `TrixAuthService`: login, logout, session restore.
- `TrixSyncService`: room list, account state, and sync lifecycle.
- `TrixRoomService`: timeline, send, attachments, reactions, typing, and
  read/delivery state.
- `TrixRoomMembershipService`: group member list, invite/add, remove, leave.
- `TrixUserDirectoryService`: directory search and profile lookup/update through
  the Trix control plane.
- `TrixDeviceVerificationService`: OMEMO device inventory, trust state, and
  fingerprint presentation.
- `TrixPushRegistrationService`: APNs token registration and unregister.
- `TrixCallControlService`: LiveKit token minting, TURN credentials, and active
  call authorization through the Trix control plane.
- `TrixMediaCallService`: LiveKit media session lifecycle behind a client-side
  E2EE gate.

The checked-in `apple/` project now exposes the active target, service, model,
and view boundary with protocol-neutral `Trix*` names. New work should keep that
boundary intact before binding SwiftUI to XMPP-specific APIs.

### OMEMO

OMEMO is the mandatory E2EE layer for product chats.

Trix must use an existing reviewed implementation where practical. The project
must not implement its own Double Ratchet, X3DH, OMEMO bundle handling, or manual
key manipulation. If a usable Apple OMEMO implementation cannot be validated for
DMs and group chats, that is a product blocker.

For direct messages, the sender encrypts to the recipient's devices and the
sender's other devices. For groups, the sender encrypts to devices belonging to
all current joined members of the members-only, non-anonymous MUC room.

Plaintext sending in product DM/group flows is not allowed. If the client cannot
build the required OMEMO payload, the composer must block sending and explain the
device/trust problem.

### Calls

Calls are a separate realtime-media surface layered beside XMPP, not a new chat
transport. DM v1 supports direct video calls. Group v1 supports audio-only voice
rooms for existing private MUCs.

LiveKit is the first SFU candidate and coturn supplies STUN/TURN. The SFU must
forward RTP and must not transcode, mix, record, or receive media encryption
keys. Trix call control authenticates the existing XMPP account, checks local DM
or MUC membership, issues short-lived LiveKit tokens, and issues TURN REST
credentials. Call-control responses intentionally do not include the media E2EE
key.

The Apple client creates call media keys locally and distributes call invites,
answers, voice-room state, and key rotations through OMEMO-encrypted XMPP
descriptors. If OMEMO recipient validation, trusted devices, media-key delivery,
LiveKit E2EE, or membership verification fails, call start and join fail closed.
Group voice rooms are joinable state in the room, not a push that rings every
member.

### Groups

Group chats use XMPP Multi-User Chat rooms with a strict Trix profile:

- persistent;
- members-only;
- non-anonymous, so clients can map room occupants to real JIDs for OMEMO;
- local-domain members only for the MVP;
- room creation and membership controlled by Trix flows, not arbitrary public
  room creation.

The OMEMO group-chat spike must prove member discovery, device fetching, invite
or membership changes, and encrypted history replay before group chat is treated
as production-ready.

### Control Plane

XMPP is the transport, not the whole product backend. Trix still needs a
centralized operator control plane for:

- create, disable, and reset users;
- directory search by name/handle;
- profile metadata;
- group creation;
- group add/remove/list members;
- server status, queue/archive/upload diagnostics;
- push gateway configuration and health.

This control plane should use server-supported APIs, admin commands, or a small
Trix service. It must not become a second messaging protocol or a parallel
plaintext chat backend.

For the MVP closeout, the concrete backend started as a loopback-only ejabberd
`mod_http_api` surface wrapped by `server/xmpp/scripts/operator-control.sh`.
The native admin-app slice adds `apps/trix-admin-api`, an authenticated
loopback-first wrapper for the macOS `TrixAdminMac` app. It covers user
operations, push test requests, media-storage status, metrics/log summaries, and
feature-flag storage without exposing raw ejabberd `5280`. Remote operator use
should go through an SSH tunnel or another reviewed private access path; a
public multi-operator admin API remains out of scope until separately reviewed.

App-driven registration is handled by a separate invite wrapper, not XMPP public
registration. Operators create one-use invite codes through an authenticated
operator endpoint, and signed-in Apple clients can issue codes from Settings
after the wrapper validates the current XMPP account through ejabberd
`check_password`. Apple clients redeem a code, handle, display name, and
user-chosen password through the app-facing endpoint. The wrapper stores only
invite-code hashes and redemption metadata, provisions the account through the
loopback ejabberd API, and returns the new XMPP JID for immediate client login.
The same wrapper handles self-service password changes for signed-in clients by
validating the current XMPP password through `check_password` and then calling
loopback `change_password`; request bodies must stay out of proxy and service
logs.

## Multidevice Model

A user may have multiple devices. Each device has its own OMEMO identity and
local encryption state.

For Trix MVP this means:

- Logging in on a new device is not equivalent to silently trusting that device.
- New or changed devices must be visible in the UI.
- The user needs understandable fingerprint/trust state before treating private
  chats as production-ready.
- Account recovery and device replacement must be documented as separate flows
  from login.

## Removed Legacy Code

The legacy custom `trixd`/OpenMLS clients, Rust core/server crates, generated
UniFFI bindings, SQL migrations, OpenAPI contract, and old interop harnesses are
no longer part of the active repository surface. New work should target the
current XMPP scaffold, the SwiftUI Apple app under `apple/`, and the standalone
XMPP push gateway.
