# Client Test Checklist

Manual QA scenarios for all Trix client platforms. Each scenario documents the preconditions,
steps, expected results, and platform coverage.

**Server**: `cargo run -p trixd` (or `docker compose up -d postgres` + `cargo run -p trixd`).

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

**Note**: Native onboarding is now task-first across iOS, macOS, and Android: server URL + health check, create/link mode switch, and a separate pending-approval state instead of folding approval back into the blank bootstrap form.

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
| 2 | Sender refreshes, reopens, or reprojects after the send completes | The sender still sees the sent body in the projected timeline instead of an unavailable/loading placeholder | ✓ | ✓ | ✓ | · |
| 3 | Receiver syncs + projects | Decrypted text appears in timeline | ✓ | ✓ | ✓ | ✓ |
| 4 | Send reaction (emoji + target) | Reaction round-trips correctly | · | ✓ | · | · |
| 5 | Advance the receiver read cursor and let sender converge delivery/read ticks | Sender shows delivered then read decoration on the outgoing message | ✓ | ✓ | ✓ | · |
| 6 | Send chat event | Event type + JSON round-trips | · | ✓ | · | · |

**Gap**: Raw reaction and chat-event composition are still exercised only through macOS or debug surfaces. The primary iOS, macOS, and Android chat UIs now send best-effort read receipts automatically when their read cursor advances and render delivery/read ticks on outgoing messages. If a just-sent local text falls back to a "still loading on this device" style placeholder after refresh or repair, treat that as a regression in projected self-message durability.

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
| 6 | Render inline image preview for supported image attachments | Timeline shows preview before full open/share flow | ✓ | ✓ | ✓ | · |

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
| 8 | FfiClientStore integration (encrypted DB) | open → substores → MLS facade | ✓ | ✓ | ✓ | · |

**Gap**: Outbox is Android-only feature currently. iOS and macOS don't use outbox APIs, although all three native clients now preserve stored-device recovery state instead of forcing users back through blank onboarding when the backend is temporarily unreachable.

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
| 2 | Receive InboxItems frame | Messages delivered in real-time | ✓ | · | ✓ | · |
| 3 | Ack inbox items | Acked frame received | · | · | ✓ | · |
| 4 | Presence ping/pong | Pong with nonce returned | · | · | · | · |
| 5 | Polling fallback (poll_once) | Inbox items fetched via HTTP | ✓ | · | · | ✓ |
| 6 | Session replaced detection | SessionReplaced event handled | · | · | ✓ | · |

**Gap**: macOS does not use foreground realtime APIs at all and still refreshes manually. iOS now runs a foreground realtime event loop and falls back to incremental polling recovery after disconnect or background handoff, while Android still has the broadest raw websocket/session-replaced coverage.

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

**Gap**: Only macOS currently implements history sync job listing/completion in a native client. The backend and shared core also support `POST /v0/history-sync/jobs/request` and `POST /v0/history-sync/jobs:request-repair`. `trix-core` now auto-requests per-chat `chat_backfill` for unavailable conversations and keeps bounded `timeline_repair` windows coalesced while repair is in flight, but no native client exposes a first-class manual repair trigger or repair-status UI yet. Append/get chunks are not used by any client.

---

# FFI Audit Findings Report

Generated by `scripts/audit-ffi-usage.sh` on 2026-03-21. Where later platform changes invalidated the transport notes, this document now carries manual corrections and `make ffi-parity-audit` remains the current source of truth.

## Coverage Summary

- This document is a point-in-time snapshot.
- For the current exported surface, live client usage, orphaned callables, and platform gaps, run `make ffi-parity-audit`.

3. **Consider exposing `create_blob_upload` + `upload_blob`** separately in iOS/Android for large file upload progress tracking.

## Key Architecture Differences Between Clients

### iOS vs macOS Persistent State
- **iOS** now opens `FfiClientStore.open()` with a per-device database key in `TrixCorePersistentBridge` and falls back to standalone history/sync/MLS stores only while migrating older roots.
- **macOS** now opens `FfiClientStore.open()` per workspace via `makeWorkspaceClientStore(...)` and keeps a legacy fallback only when pre-unified workspace state must still be read.
- **Android** uses `FfiClientStore.open()` on top of `state-v1.db` and remains the reference encrypted SQLite path.

**Recommendation**: Keep converging migration/fallback code on the single `FfiClientStore` steady-state path and retire legacy standalone store creation once old workspaces are no longer supported.

### Outbox
- **Android** is the only platform implementing local outbox (`enqueue_outbox_message`, `mark_outbox_failure`, etc.)
- **iOS** and **macOS** send messages synchronously via `send_message_body()` without local queue.

**Recommendation**: Outbox is important for offline-first UX. iOS and macOS should adopt it.

### Realtime
- **Android** uses `FfiRealtimeDriver.next_websocket_event()` with auto-ack for real-time delivery.
- **iOS** now uses the shared messenger client's realtime event stream for the foreground path and `getNewEvents()` for incremental recovery/polling fallback.
- **macOS** has no realtime at all — manual refresh only.

**Recommendation**: macOS should adopt the shared realtime path; iOS and Android already cover websocket-first delivery with polling-style recovery at different abstraction layers.

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
- **Android**, **iOS**, and **macOS** all open `FfiClientStore` for their primary encrypted local-store path.
- iOS and macOS still carry legacy fallback/migration code so older standalone history/sync/MLS roots can be upgraded in place.

**Recommendation**: Keep the unified encrypted store path as the only steady-state runtime and remove legacy fallback once migration compatibility is no longer required.
