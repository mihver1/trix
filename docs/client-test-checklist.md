# Client Test Checklist

Manual QA scenarios for all Trix client platforms. Each scenario documents the preconditions,
steps, expected results, and platform coverage.

**Server**: `cargo run -p trixd` (or `docker compose up postgres` + `cargo run -p trixd`).

**Platforms**: iOS, macOS, Android, Bot (Rust/Python/Go).

---

## S1 — Account Lifecycle

**Preconditions**: Server running, no existing account on device.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Generate account root + device keys | Keys are 32 bytes | ✓ | ✓ | ✓ | ✓ |
| 2 | Create account (handle, profile_name, credential_identity) | Returns account_id, device_id, account_sync_chat_id | ✓ | ✓ | ✓ | ✓ |
| 3 | Authenticate with device key | Returns access_token, account matches | ✓ | ✓ | ✓ | ✓ |
| 4 | Fetch /me | Profile matches creation params | · | ✓ | ✓ | ✓ |
| 5 | Update profile (handle, bio) | Updated fields persisted | ✓ | ✓ | ✓ | · |
| 6 | Search account directory | Own account appears in results | ✓ | ✓ | ✓ | · |

**Note**: iOS uses `TrixCoreServerBridge.authenticate()`, macOS uses `TrixAPIClient.authenticate()`,
Android uses `AuthBootstrapCoordinator.createAccount()`.

---

## S2 — Device Management

**Preconditions**: Authenticated account with root-capable device.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Create link intent | Returns link_intent_id + QR payload | ✓ | ✓ | ✓ | · |
| 2 | Complete link intent (new device) | Returns pending_device_id | ✓ | ✓ | ✓ | · |
| 3 | Approve pending device | Device status → active | ✓ | ✓ | ✓ | · |
| 4 | Create + upload transfer bundle | Bundle encrypted for recipient | · | ✓ | ✓ | · |
| 5 | Fetch + decrypt transfer bundle | account_root restored on linked device | ✓ | · | ✓ | · |
| 6 | List devices | Both devices visible, active | · | ✓ | ✓ | · |
| 7 | Revoke linked device | Device status → revoked | ✓ | ✓ | ✓ | · |

---

## S3 — Chat Creation

**Preconditions**: Two authenticated accounts; recipient has published key packages.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Ensure own key packages (≥8) | Key packages published if needed | ✓ | ✓ | ✓ | ✓ |
| 2 | Create DM via control plane | Chat created with MLS group, 2 members, commit+welcome in store | ✓ | ✓ | ✓ | · |
| 3 | Repeat DM create for the same pair | No second DM is created; server returns conflict or client reuses the existing chat after reload | ✓ | ✓ | ✓ | · |
| 4 | Create group chat (3+ participants) | Same as above, chat_type = group | ✓ | ✓ | ✓ | · |
| 5 | List chats | Created chat appears | ✓ | ✓ | ✓ | ✓ |
| 6 | Get chat detail | Members, device_members, epoch visible | · | ✓ | ✓ | ✓ |
| 7 | Second user syncs | Chat appears in their store via inbox/history | ✓ | ✓ | ✓ | ✓ |
| 8 | Second user bootstraps MLS conversation | project_chat_with_facade succeeds, group_id mapped | ✓ | ✓ | ✓ | ✓ |

**Note**: The backend now enforces DM uniqueness by sorted account pair, and `trix-core` also removes legacy duplicate DM projections on load.

---

## S4 — Messaging

**Preconditions**: DM or group chat created, both users have MLS conversation state.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Send text message | server_seq assigned, local store updated | ✓ | ✓ | ✓ | ✓ |
| 2 | Receiver syncs + projects | Decrypted text appears in timeline | ✓ | ✓ | ✓ | ✓ |
| 3 | Send reaction (emoji + target) | Reaction round-trips correctly | · | ✓ | · | · |
| 4 | Send receipt (read/delivered) | Receipt round-trips correctly | · | ✓ | · | · |
| 5 | Send chat event | Event type + JSON round-trips | · | ✓ | · | · |

**Gap**: iOS and Android use `send_message_body()` through `FfiSyncCoordinator` only for text;
reaction/receipt/event types are not exercised in their bridge code.

---

## S5 — Attachments

**Preconditions**: Active chat with MLS state.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Prepare attachment (encrypt) | Encrypted payload + file_key + nonce produced | · | · | · | · |
| 2 | Create blob upload slot | blob_id + upload_url returned | · | · | · | · |
| 3 | Upload encrypted blob | Upload succeeds | · | · | · | · |
| 4 | Send attachment message body | Message with blob_id delivered | ✓ | ✓ | ✓ | ✓ |
| 5 | Receiver downloads + decrypts | Plaintext matches original | ✓ | ✓ | ✓ | ✓ |

**Note**: All platforms use `upload_attachment()` (combined prepare+upload) rather than
separate `ffi_prepare_attachment_upload()` + `create_blob_upload()` + `upload_blob()`.

---

## S6 — Local State & Outbox

**Preconditions**: Authenticated account.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Enqueue outbox message | Item appears with Pending status | · | · | ✓ | · |
| 2 | List outbox messages | Enqueued item visible | · | · | ✓ | · |
| 3 | Mark outbox failure | Status → Failed, failure_message set | · | · | ✓ | · |
| 4 | Clear outbox failure | Status → Pending | · | · | ✓ | · |
| 5 | Remove outbox message | Item removed | · | · | ✓ | · |
| 6 | History store persistence (re-open) | Data survives re-open | ✓ | ✓ | ✓ | ✓ |
| 7 | MLS state persistence (re-open) | Group state survives re-open | ✓ | ✓ | ✓ | ✓ |
| 8 | FfiClientStore integration (encrypted DB) | open → substores → MLS facade | · | ✓ | ✓ | · |

**Gap**: Outbox is Android-only feature currently. iOS and macOS don't use outbox APIs.

---

## S7 — MLS Lifecycle

**Preconditions**: Authenticated account with MLS facade.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Generate + publish key packages | Packages registered on server | ✓ | ✓ | ✓ | ✓ |
| 2 | Ensure own key packages (auto-replenish) | Only publishes if below threshold | ✓ | ✓ | ✓ | · |
| 3 | Create group → add member → welcome | Commit + welcome produced | ✓ | ✓ | ✓ | ✓ |
| 4 | Join from welcome | Epoch matches, members visible | ✓ | ✓ | ✓ | ✓ |
| 5 | Projection pipeline (project_chat_with_facade) | Messages decrypted into timeline | ✓ | ✓ | ✓ | ✓ |
| 6 | MLS facade persistence (save/load) | State survives restart | ✓ | ✓ | ✓ | ✓ |

---

## S8 — Realtime

**Preconditions**: Authenticated account, WebSocket or polling configured.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | WebSocket connect | Hello frame received | ✓ | · | ✓ | · |
| 2 | Receive InboxItems frame | Messages delivered in real-time | · | · | ✓ | · |
| 3 | Ack inbox items | Acked frame received | · | · | ✓ | · |
| 4 | Presence ping/pong | Pong with nonce returned | · | · | · | · |
| 5 | Polling fallback (poll_once) | Inbox items fetched via HTTP | ✓ | · | · | ✓ |
| 6 | Session replaced detection | SessionReplaced event handled | · | · | ✓ | · |

**Gap**: macOS does not use WebSocket or realtime APIs at all — it only polls manually.
iOS uses `poll_once()` only.

---

## S9 — Read States

**Preconditions**: Chat with messages.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | Mark chat as read | unread_count → 0 | ✓ | ✓ | ✓ | · |
| 2 | New message increments unread | unread_count > 0 | ✓ | ✓ | ✓ | · |
| 3 | List chat read states | All chats with read cursors | ✓ | · | · | · |
| 4 | Chat list items ordered by unread | Unread chats first | ✓ | ✓ | ✓ | · |

---

## S10 — History Sync

**Preconditions**: Multi-device account, source device has chat history.

| # | Step | Expected | iOS | macOS | Android | Bot |
|---|------|----------|-----|-------|---------|-----|
| 1 | List history sync jobs | Jobs visible with status | · | ✓ | · | · |
| 2 | Append history sync chunk | Chunk stored server-side | · | · | · | · |
| 3 | Get history sync chunks | Chunks retrievable | · | · | · | · |
| 4 | Complete history sync job | Job status → completed | · | ✓ | · | · |

**Gap**: Only macOS currently implements history sync job listing/completion in a native client. The backend and shared core also support `POST /v0/history-sync/jobs/request` and `POST /v0/history-sync/jobs:request-repair`, and the shared `safe_ffi` e2e suite now covers same-pool repair recovery, but no native client exposes a first-class manual repair trigger yet.
Append/get chunks are not used by any client.

---

# FFI Audit Findings Report

Generated by `scripts/audit-ffi-usage.sh` on 2026-03-21.

## Coverage Summary

- This document is a point-in-time snapshot.
- For the current exported surface, live client usage, orphaned callables, and platform gaps, run `make ffi-parity-audit`.

3. **Consider exposing `create_blob_upload` + `upload_blob`** separately in iOS/Android for large file upload progress tracking.

## Key Architecture Differences Between Clients

### iOS vs macOS Persistent State
- **iOS** uses manual `FfiLocalHistoryStore.newPersistent()` + `FfiSyncCoordinator.newPersistent()` + `FfiMlsFacade.newPersistent()` in `TrixCorePersistentBridge`. Does NOT use `FfiClientStore`.
- **macOS** also uses manual store management (`makeLocalHistoryStore` / `makeSyncCoordinator` / `makePersistentMlsFacade`). Does NOT use `FfiClientStore`.
- **Android** uses `FfiClientStore.open()` which wraps all three stores + encrypted SQLite. This is the intended "happy path" API.

**Recommendation**: Migrate iOS and macOS to `FfiClientStore.open()` for encrypted DB support and simplified lifecycle.

### Outbox
- **Android** is the only platform implementing local outbox (`enqueue_outbox_message`, `mark_outbox_failure`, etc.)
- **iOS** and **macOS** send messages synchronously via `send_message_body()` without local queue.

**Recommendation**: Outbox is important for offline-first UX. iOS and macOS should adopt it.

### Realtime
- **Android** uses `FfiRealtimeDriver.next_websocket_event()` with auto-ack for real-time delivery.
- **iOS** uses `FfiRealtimeDriver.poll_once()` only — no WebSocket.
- **macOS** has no realtime at all — manual refresh only.

**Recommendation**: All platforms should support WebSocket with polling fallback.

### Message Body Types
- **macOS** exercises all 5 content types (text, reaction, receipt, attachment, chatEvent) through `TypedMessageBody`.
- **iOS** exercises text and attachment through bridge; reaction/receipt/chatEvent are debug-only.
- **Android** exercises text and attachment only.

**Recommendation**: Ensure all platforms handle all content types uniformly through `send_message_body()`.

### Error Handling
- **macOS** implements `parseServerError()` to extract HTTP status codes from FFI error strings — a workaround for the flat `TrixFfiError::Message(String)` error type.
- **Android** wraps all FFI calls in `try/catch(TrixFfiException)`.
- **iOS** uses Swift `throws` directly.

**Recommendation**: Consider a richer `TrixFfiError` enum with structured error codes to eliminate client-side string parsing.

### FfiClientStore Adoption
- Only **Android** uses `FfiClientStore.open()` with encrypted SQLite (`database_key`).
- iOS and macOS create unencrypted persistent stores.

**Recommendation**: High priority — all platforms should use `FfiClientStore` for encrypted local storage.
