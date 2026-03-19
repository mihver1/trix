# Trix v0 Spec

## Status

Draft.

This document defines the initial `v0` architecture for a native-first end-to-end encrypted messenger with:

- `macOS` as the first client platform
- `Rust` backend as a single binary
- `PostgreSQL` as the primary metadata store
- local filesystem blob storage for encrypted attachments
- `OpenMLS` as the group encryption layer
- `multi-device` support in `v0`

## Product Goals

- Fast native desktop UX comparable to a modern consumer messenger.
- End-to-end encrypted direct messages and group chats.
- Encrypted image and file attachments.
- Multi-device accounts from day one.
- Single-node deployment for development and early production.
- Storage and API design that can evolve to multi-instance deployment later.

## Non-Goals for v0

- Voice or video calls.
- Public channels, bots, or federation.
- Server-side full-text search over message content.
- Strong metadata hiding beyond basic minimization.
- Anonymous routing, anti-censorship transports, or anti-DPI protocol camouflage.
- Device-less account recovery.
- Sharing full history to a newly linked device without an already trusted device online.

## Core Decisions

### Identity Model

- `account` is the user-facing identity.
- `device` is the cryptographic client instance.
- Each device has its own device key material and its own MLS leaf membership.
- Each account has an `account_root` signing key shared only across trusted devices of that account.
- A new device becomes trusted only after an already trusted device approves it.

### Chat Model

- `1 chat = 1 MLS group`.
- A direct message chat is an MLS group whose members are all devices of two accounts.
- A group chat is an MLS group whose members are all devices of all participant accounts.
- Every account also has a private `account sync group` used only by that account's devices.

### Storage Model

- `PostgreSQL` stores metadata, ordering, device state, chat state, inbox state, and MLS coordination state.
- Encrypted attachment blobs are stored on local disk via an internal `BlobStore`.
- Message ciphertext is stored in `PostgreSQL` in `v0`.
- Clients store local history in encrypted `SQLite`.

## Threat Model Summary

### Protected in v0

- Server cannot read message plaintext.
- Server cannot read attachment plaintext.
- Revoked devices cannot read future chat traffic after group state updates are applied.
- Newly linked devices only receive history from an already trusted device.

### Not Protected in v0

- Server still sees account, device, chat, and delivery metadata.
- Network observers still see IP addresses, timing, and traffic volume.
- Push systems will leak wake-up timing once mobile clients exist.
- A fully compromised trusted device can authorize another device for that same account.

## High-Level Architecture

### Components

### Client

- `macOS` application built with `SwiftUI`
- shared `Rust core`
- `OpenMLS`
- encrypted local `SQLite`
- `Keychain` for device keys and account root material

### Backend Binary

- `HTTP API`
- `WebSocket session gateway`
- auth and device registration
- device directory and append-only device log
- `KeyPackage` store
- chat membership and ordering service
- per-device inbox service
- attachment `BlobStore`
- background jobs for cleanup and delivery retries

### External Dependencies

- `PostgreSQL`
- local filesystem volume for encrypted blobs

### Deployment Modes

### Single Node

- one backend instance
- one `PostgreSQL` instance
- one mounted blob volume
- optional reverse proxy for TLS termination

### Later HA Evolution

- multiple stateless backend instances
- shared `PostgreSQL`
- shared blob storage implementation
- sticky or resumable WebSocket routing

The `v0` design must avoid assumptions that only work with in-process state.

## Core Entities

### Account

Represents a user identity. Owns multiple trusted devices.

Fields:

- `account_id` `uuid`
- `handle` `text`, optional unique user handle
- `profile_name` `text`
- `profile_bio` `text`, optional
- `avatar_blob_id` `text`, optional
- `account_root_pubkey` `bytea`
- `created_at`
- `deleted_at`, optional

### Device

Represents a physical client instance.

Fields:

- `device_id` `uuid`
- `account_id`
- `display_name` `text`
- `platform` `text`
- `device_status` enum: `pending`, `active`, `revoked`
- `credential_identity` `bytea`
- `account_root_signature` `bytea`
- `transport_pubkey` `bytea`
- `created_at`
- `activated_at`, optional
- `revoked_at`, optional

### Device Log Entry

Append-only account-scoped log of device lifecycle changes.

Fields:

- `device_log_seq` `bigserial`
- `account_id`
- `event_type` enum: `device_added`, `device_activated`, `device_revoked`
- `subject_device_id`
- `actor_device_id`
- `payload_json`
- `created_at`

### Chat

Represents a logical conversation.

Fields:

- `chat_id` `uuid`
- `chat_type` enum: `dm`, `group`, `account_sync`
- `title` `text`, optional
- `avatar_blob_id` `text`, optional
- `created_by_account_id`
- `created_at`
- `archived_at`, optional
- `last_server_seq` `bigint`

### Chat Account Membership

Tracks which accounts conceptually belong to a chat.

Fields:

- `chat_id`
- `account_id`
- `role` enum: `owner`, `member`
- `membership_status` enum: `active`, `left`, `removed`
- `joined_at`
- `left_at`, optional

### Chat Device Membership

Tracks which devices are active MLS leaves for a chat.

Fields:

- `chat_id`
- `device_id`
- `leaf_index` `integer`, optional while pending
- `membership_status` enum: `pending_add`, `active`, `pending_remove`, `removed`
- `added_in_epoch`
- `removed_in_epoch`, optional
- `joined_at`
- `removed_at`, optional

### MLS Group State

Tracks the current cryptographic state for a chat.

Fields:

- `chat_id`
- `group_id_bytes` `bytea`
- `epoch` `bigint`
- `state_status` enum: `active`, `rotating`, `blocked`
- `last_commit_message_id`, optional
- `updated_at`

### Device KeyPackage

Stores publishable `KeyPackage` objects for future group operations.

Fields:

- `key_package_id` `uuid`
- `device_id`
- `cipher_suite` `text`
- `key_package_bytes` `bytea`
- `status` enum: `available`, `reserved`, `consumed`, `expired`
- `published_at`
- `reserved_at`, optional
- `consumed_at`, optional

### Device Link Intent

Tracks a trusted-device-approved bootstrap for adding a new device to an existing account.

Fields:

- `link_intent_id` `uuid`
- `account_id`
- `created_by_device_id`
- `link_token` `uuid`
- `pending_device_id`, optional
- `status` enum: `open`, `pending_approval`, `completed`, `expired`, `canceled`
- `expires_at`
- `created_at`
- `completed_at`, optional
- `approved_by_device_id`, optional
- `approved_at`, optional

### Message

Server-stored encrypted message envelope for a chat.

Fields:

- `message_id` `uuid`
- `chat_id`
- `server_seq` `bigint`
- `sender_account_id`
- `sender_device_id`
- `epoch` `bigint`
- `message_kind` enum: `application`, `commit`, `welcome_ref`, `system`
- `content_type` enum: `text`, `reaction`, `receipt`, `attachment`, `chat_event`
- `ciphertext` `bytea`
- `aad_json` `jsonb`
- `created_at`

Notes:

- `ciphertext` is opaque to the server.
- `aad_json` contains only routing-safe metadata such as `chat_id`, `message_kind`, and format version.
- `msg_id` inside the client payload is still required for replay and dedupe and is not exposed in server-visible metadata.
- `server_seq` is monotonic per chat and is allocated transactionally while appending to that chat.

### Device Inbox Entry

Per-device delivery queue entry.

Fields:

- `inbox_id` `bigserial`
- `device_id`
- `chat_id`
- `message_id`
- `delivery_state` enum: `pending`, `leased`, `acked`, `failed`
- `lease_owner` `text`, optional
- `lease_expires_at`, optional
- `acked_at`, optional
- `created_at`

### Attachment Blob

Metadata for encrypted file objects.

Fields:

- `blob_id` `text`
- `storage_backend` enum: `local_fs`
- `relative_path` `text`
- `size_bytes` `bigint`
- `sha256` `bytea`
- `mime_type` `text`
- `created_by_device_id`
- `upload_status` enum: `pending_upload`, `available`
- `upload_completed_at`, optional
- `created_at`
- `deleted_at`, optional

### Attachment Blob Chat Ref

Authorizes a stored encrypted blob for one or more chats.

Fields:

- `blob_id`
- `chat_id`
- `created_at`

### History Sync Job

Tracks background backfill from one trusted device to another.

Fields:

- `job_id` `uuid`
- `account_id`
- `source_device_id`
- `target_device_id`
- `chat_id`, optional
- `job_type` enum: `initial_sync`, `chat_backfill`, `device_rekey`
- `job_status` enum: `pending`, `running`, `completed`, `failed`, `canceled`
- `cursor_json`
- `created_at`
- `updated_at`

## PostgreSQL Schema Outline

### Tables

- `accounts`
- `devices`
- `device_log`
- `chats`
- `chat_account_members`
- `chat_device_members`
- `mls_group_states`
- `device_key_packages`
- `device_link_intents`
- `messages`
- `device_inbox`
- `attachment_blobs`
- `attachment_blob_chat_refs`
- `history_sync_jobs`
- `idempotency_keys`
- `auth_challenges`

### Required Indexes

### accounts

- unique index on `handle` where not null

### devices

- index on `account_id`
- index on `(account_id, device_status)`

### device_log

- index on `(account_id, device_log_seq)`

### chats

- index on `(chat_type, created_at)`

### chat_account_members

- unique index on `(chat_id, account_id)`
- index on `(account_id, membership_status)`

### chat_device_members

- unique index on `(chat_id, device_id)`
- index on `(device_id, membership_status)`
- index on `(chat_id, membership_status)`

### mls_group_states

- unique index on `chat_id`

### device_key_packages

- index on `(device_id, status)`
- index on `(status, published_at)`

### device_link_intents

- unique index on `link_intent_id`
- unique index on `link_token`
- unique partial index on `pending_device_id` where not null
- index on `(account_id, status)`
- index on `(expires_at)`

### messages

- unique index on `message_id`
- unique index on `(chat_id, server_seq)`
- index on `(chat_id, created_at)`
- index on `(sender_device_id, created_at)`

### device_inbox

- index on `(device_id, delivery_state, inbox_id)`
- index on `(message_id)`

### attachment_blobs

- unique index on `blob_id`
- index on `(upload_status, created_at)`

### attachment_blob_chat_refs

- unique index on `(blob_id, chat_id)`
- index on `(chat_id)`

### history_sync_jobs

- index on `(target_device_id, job_status)`
- index on `(account_id, job_status)`

### idempotency_keys

- unique index on `(scope, key)`

### auth_challenges

- index on `(device_id, expires_at)`

## Ephemeral State

The following state is not persisted as regular chat history in `v0`:

- typing indicators
- websocket presence heartbeats
- transient upload progress

This state may be kept in memory by the backend and may be lost on reconnect or restart.

## Blob Storage Layout

Blob storage is an internal backend module with a simple filesystem implementation.

### BlobStore Interface

- `put(blob_id, stream, metadata) -> BlobRef`
- `get(blob_id) -> stream`
- `head(blob_id) -> BlobMetadata`
- `delete(blob_id)`

### Local Filesystem Layout

Root directory:

```text
blobs/
  sha256/
    ab/
      cd/
        abcdef...<full-blob-id>.blob
  tmp/
```

Rules:

- `blob_id` is content-addressed using the encrypted blob bytes.
- uploads go to `tmp/` first and are atomically moved into place after hash verification
- the server never stores plaintext attachments

### Attachment Encryption

Clients encrypt attachments before upload.

Per attachment:

- random `file_key`
- random nonce or IV
- encrypted payload uploaded to blob storage
- descriptor sent inside an MLS application message

Attachment descriptor fields inside the encrypted message:

- `blob_id`
- `mime_type`
- `size_bytes`
- `sha256`
- `file_key`
- `nonce`
- optional preview metadata

## Transport

### HTTP

Used for:

- bootstrap
- authentication
- key package publication
- chat creation and membership operations
- attachment upload and download
- websocket session setup

### WebSocket

Used for:

- device session establishment
- low-latency inbox delivery
- acks
- typing and receipt updates
- background sync coordination

The WebSocket channel carries server envelopes only. Decryption happens entirely on the client.

### Authentication

`v0` uses device-authenticated sessions.

Request model:

- client requests a short-lived server challenge
- device signs the challenge with its transport private key
- server validates that the device is active and mints a short-lived access token

The account root key is not used for routine session auth. It is used only for device trust and account-level actions.

## API Surface

The API is versioned under `/v0`.

## Auth and Bootstrap

### `POST /v0/auth/challenge`

Request:

- `device_id`

Response:

- `challenge`
- `expires_at`

### `POST /v0/auth/session`

Request:

- `device_id`
- `challenge`
- `signature`

Response:

- `access_token`
- `expires_at`
- `account_id`
- `device_status`

## Account and Device Management

### `POST /v0/accounts`

Creates a new account and first trusted device.

Request:

- account profile data
- first device metadata
- signed account root bundle
- first batch of `KeyPackage` objects

Response:

- `account_id`
- `device_id`
- initial `account_sync_chat_id`

### `GET /v0/accounts/me`

Returns current account profile and device list.

### `POST /v0/devices/link-intents`

Creates a pending device-link intent from an authenticated trusted device.

Response:

- `link_intent_id`
- `qr_payload`
- `expires_at`

### `POST /v0/devices/link-intents/{link_intent_id}/complete`

Called by the new device after scanning the QR and establishing the bootstrap channel.

Request:

- new device metadata
- transport public key
- credential identity
- initial `KeyPackage` batch

Response:

- `pending_device_id`
- `bootstrap_payload_b64`

### `GET /v0/devices/{device_id}/approve-payload`

Returns the canonical bootstrap payload that must be signed with the account root key in order to approve a pending device.

Response:

- pending device metadata
- `credential_identity_b64`
- `transport_pubkey_b64`
- `bootstrap_payload_b64`

### `POST /v0/devices/{device_id}/approve`

Called by an already trusted device to activate the pending device.

Request:

- `account_root_signature_b64` over the canonical `bootstrap_payload_b64`
- optional encrypted `transfer_bundle_b64` for the new device

Response:

- device becomes `active`
- history sync jobs are scheduled

### `GET /v0/devices/{device_id}/transfer-bundle`

Returns the encrypted transfer bundle previously uploaded during approval.

Rules:

- only the target authenticated device can fetch it
- payload remains opaque to the server

### `POST /v0/devices/{device_id}/revoke`

Revokes a device.

Request:

- reason
- account-root-signed revoke action

Response:

- device becomes `revoked`
- server-side inbox and chat membership access are cut off immediately
- MLS cleanup commits remain a follow-up coordination step

### `GET /v0/devices`

Returns all devices for the authenticated account.

## History Sync

### `GET /v0/history-sync/jobs`

Returns orchestration jobs assigned to the authenticated source device.

### `POST /v0/history-sync/jobs/{job_id}/complete`

Marks a history sync job as completed and optionally updates its cursor payload.

## Key Packages

### `POST /v0/key-packages:publish`

Publishes a batch of `KeyPackage` objects for the authenticated device.

### `GET /v0/accounts/{account_id}/key-packages`

Returns reservable `KeyPackage` references for all active devices of the target account.

### `POST /v0/key-packages:reserve`

Returns reservable `KeyPackage` references for the explicitly requested devices of the target account.

Server rules:

- packages are leased atomically
- expired or reserved packages are not returned twice

## Chats

### `POST /v0/chats`

Creates a new direct message or group chat.

Request:

- `chat_type`
- participants by `account_id`
- initial group metadata
- initial MLS `Commit` and `Welcome` references

Response:

- `chat_id`
- current epoch

### `GET /v0/chats`

Lists chats visible to the authenticated device.

### `GET /v0/chats/{chat_id}`

Returns chat metadata, membership, and the latest group epoch metadata.

### `POST /v0/chats/{chat_id}/members:add`

Adds one or more accounts or devices to the chat.

Request:

- target account IDs or device IDs
- MLS `Commit`
- `Welcome` payload references

### `POST /v0/chats/{chat_id}/members:remove`

Removes accounts or devices from the chat.

Request:

- target account IDs or device IDs
- MLS `Commit`

### `POST /v0/chats/{chat_id}/devices:add`

Adds one or more devices of an already active account to the chat.

Request:

- target device IDs
- reserved key package IDs for those devices
- MLS `Commit`
- `Welcome` payload references

### `POST /v0/chats/{chat_id}/devices:remove`

Removes one or more devices from the chat without changing account-level membership.

Request:

- target device IDs
- MLS `Commit`

## Messages and Inbox

### `POST /v0/chats/{chat_id}/messages`

Appends a message or commit to a chat and fans it out to recipient device inboxes.

Request:

- `message_id`
- `epoch`
- `message_kind`
- `content_type`
- `ciphertext`
- `aad_json`
- idempotency key

Response:

- `server_seq`
- `accepted_at`

Rules:

- server validates sender device is an active member of the chat
- server serializes commit application per chat
- idempotent retries return the existing accepted message

### `GET /v0/inbox?limit=...&after_inbox_id=...`

Poll API for queued messages for the authenticated device.

Rules:

- returns `pending` items plus items whose previous lease has expired
- does not mutate delivery state on the server

### `POST /v0/inbox/lease`

Returns a leased batch of inbox items for delivery workers or websocket sessions.

Request:

- optional `lease_owner`
- optional `after_inbox_id`
- optional `limit`
- optional `lease_ttl_seconds`

Response:

- effective `lease_owner`
- `lease_expires_at_unix`
- leased inbox items

Rules:

- only `pending` or expired leased items can be claimed
- lease claim is atomic and uses row-level locking
- lease ownership is advisory for `v0`; final acceptance still happens through `ack`

### `POST /v0/inbox/ack`

Marks inbox items as delivered and accepted by the client.

### `GET /v0/chats/{chat_id}/history?before_server_seq=...&limit=...`

Returns server-stored encrypted history for the chat.

This endpoint is only for active chat members and returns server ciphertext only. It does not make a newly linked device a valid chat member by itself.

## Attachments

### `POST /v0/blobs/uploads`

Creates or reuses an upload slot scoped to a chat and returns upload constraints.

### `PUT /v0/blobs/{blob_id}`

Stores the encrypted attachment blob and marks it available for download.

### `GET /v0/blobs/{blob_id}`

Streams the encrypted blob to an authenticated device that is authorized by chat membership.

### `HEAD /v0/blobs/{blob_id}`

Returns blob metadata as headers.

## WebSocket Session

### Connect

`GET /v0/ws` with bearer token.

### Server Frames

- `inbox_items`
- `device_log_update`
- `chat_state_update`
- `history_sync_update`
- `session_replaced`

### Client Frames

- `ack`
- `typing_update`
- `presence_ping`
- `history_sync_progress`

## Sequence Flows

## 1. Register First Device

1. Client generates:
   - `account_root` key
   - device transport key
   - MLS credential identity
   - initial `KeyPackage` batch
2. Client calls `POST /v0/accounts`.
3. Server creates:
   - `account`
   - first `device`
   - `account sync chat`
   - `account sync MLS group state`
4. Server stores published `KeyPackage` objects.
5. Client receives account bootstrap response and opens a WebSocket session.

## 2. Create Direct Message Chat

1. Sender looks up active devices and available `KeyPackage` objects for the target account.
2. Sender creates a new MLS group locally containing:
   - all sender devices that should be in the chat
   - all target account devices
3. Sender uploads initial `Commit` and `Welcome` references via `POST /v0/chats`.
4. Server creates `chat`, membership rows, and inbox entries for all recipient devices.
5. Devices process the welcome and join the chat.

## 3. Send Application Message

1. Sender device creates MLS application ciphertext.
2. Sender calls `POST /v0/chats/{chat_id}/messages`.
3. Server appends the message, allocates `server_seq`, and enqueues an inbox entry for each active recipient device.
4. Online devices receive delivery via WebSocket or poll.
5. Device decrypts, applies replay checks using client payload `msg_id`, persists locally, and acks the inbox item.

## 4. Add New Device to an Existing Account

1. Existing trusted device creates a `link_intent`.
2. New device scans the QR and uploads its device metadata and `KeyPackage` batch.
3. Existing trusted device fetches `GET /v0/devices/{device_id}/approve-payload`, signs `bootstrap_payload_b64` with the account root key, and submits `POST /v0/devices/{device_id}/approve`.
4. Server marks the new device `active` and appends a `device_log` event.
5. Existing trusted device adds the new device to:
   - the `account sync group`
   - every active chat group where that account currently participates
6. Server stores the resulting commits and welcome references.
7. Existing trusted device begins history backfill jobs for the new device.
8. New device gradually reaches steady state as chats finish syncing.

## 5. Revoke Device

1. Trusted device submits a revoke action signed with the account root key.
2. Server marks the target device as `revoked` and emits a `device_log` event.
3. Trusted devices schedule removal commits across:
   - account sync group
   - every active chat containing the revoked device
4. Once the relevant epochs advance, the revoked device no longer receives future chat content.

## 6. Attachment Send

1. Client encrypts the file locally.
2. Client uploads the encrypted blob.
3. Client sends an MLS application message containing the attachment descriptor.
4. Recipient downloads the encrypted blob and decrypts it locally.

## Concurrency and Ordering Rules

- `messages` table is the canonical per-chat ordering source through `server_seq`.
- chat commits are serialized per `chat_id`.
- only active chat devices can append chat messages.
- account device lifecycle changes are serialized per `account_id`.
- inbox leasing is time-bounded and idempotent.

## Client-Side Rules

- Treat server history as opaque encrypted transport data.
- Trust a chat only if local MLS state and current device log agree.
- Do not show a newly linked device as fully synchronized until:
  - account sync group joined
  - active chat memberships established
  - initial history sync finished
- Search is local-only.

## Compose Layout for Single-Node Mode

Services:

- `app`
- `postgres`

Volumes:

- `postgres-data`
- `blob-data`

Environment:

- `DATABASE_URL`
- `BLOB_ROOT`
- `APP_BASE_URL`
- `JWT_SIGNING_KEY`
- `TLS_MODE`

Ports:

- app `8080`
- postgres `5432`

## Open Questions

- Whether `v0` should expose handle-based discovery or start with invitation links only.
- Whether message ciphertext should remain in `PostgreSQL` beyond `v0`.
- Whether device approval should require direct local proximity only or support remote approval.
- Whether group membership changes should be server-orchestrated jobs or purely client-driven flows with server validation.
- Whether the first implementation should support more than one active `macOS` session per device.

## Immediate Next Artifacts

- API schema in `OpenAPI`
- `PostgreSQL` migrations
- backend module layout
- `Rust core` FFI surface for the `macOS` app
- sequence diagrams for register, link-device, and send-message
