# Architecture

## Goal

Trix is moving to Matrix so the project can use a real, reviewed protocol and
an existing E2EE implementation instead of carrying custom messaging and
OpenMLS orchestration.

The MVP architecture is intentionally small:

- One Conduit homeserver.
- Federation disabled.
- Native SwiftUI Apple clients.
- Matrix Rust SDK Swift components for protocol, sync, room state, and E2EE.
- Local secure session storage on device.

## Components

### Server

Conduit is the homeserver. It owns Matrix account registration, login, room
state, sync, media metadata, and server-side persistence. It does not decrypt
encrypted room messages.

The first deployment uses `trix.selfhost.ru` as the Matrix `server_name`.
Changing `server_name` after users exist changes Matrix user IDs and room IDs,
so it should be treated as permanent.

Federation is disabled because the product is a private messenger for a tiny
group. That removes a large operational surface: remote server trust,
federation signing, moderation of external users, and cross-server abuse. It
does not remove the need for TLS, backups, device verification, or careful
account recovery.

### Apple Client

The Apple client is SwiftUI and keeps SDK/session logic out of views.

The service boundary is:

- `MatrixSessionStore`: secure session persistence.
- `MatrixAuthService`: login, logout, session restore.
- `MatrixSyncService`: room list and sync lifecycle.
- `MatrixRoomService`: room timeline and text send operations.
- `RoomListViewModel`: room list presentation state.
- `TimelineViewModel`: timeline presentation state.

The checked-in `apple/` implementation now pins `matrix-rust-components-swift`
and uses `MatrixRustSDKAdapter` behind these protocols. A mock service remains
available for local UI development through dependency injection.

### Matrix Rust SDK

The Matrix Rust SDK is the intended source of truth for:

- Matrix client-server protocol calls.
- Sync.
- Room timeline handling.
- Olm/Megolm E2EE.
- Device identity and verification APIs.
- Key backup and recovery APIs.

Trix code should not manually parse or manipulate E2EE key material. If a
feature needs encryption behavior, it should be built through Matrix SDK APIs.

## Why No Custom Crypto

The old prototype carried custom application protocol and OpenMLS integration
work. That makes every client, storage, and recovery flow security-sensitive.
For this product, that is unnecessary risk.

Matrix already defines interoperable encrypted rooms, device identity,
verification, and recovery concepts. The MVP should spend effort on correct
integration and a clear UX instead of inventing cryptographic behavior.

## Multidevice Model

In Matrix, a user can have multiple devices. Encrypted rooms distribute message
keys to verified or otherwise trusted devices according to Matrix SDK behavior
and room encryption policy. Each device has its own identity and local crypto
store.

For Trix MVP this means:

- Logging in on a new device is not equivalent to silently trusting that device.
- Existing devices may need to verify the new device.
- Users need visible recovery/verification states.
- Key backup is a separate feature from login and must be treated carefully.

The first UI exposes SDK verification/recovery state directly. If the SDK
reports no eligible verified session for interactive SAS, the app must show that
blocked state and use Matrix SDK recovery APIs rather than inventing a local
trust override.

## Legacy Code

The existing `apps/ios`, `apps/macos`, `crates/trix-core`, and `apps/trixd`
paths remain in the repository during the pivot. They preserve UI history,
release tooling, and test references. New Matrix protocol work should avoid
expanding the legacy OpenMLS/UniFFI surface unless the task explicitly concerns
legacy maintenance.
