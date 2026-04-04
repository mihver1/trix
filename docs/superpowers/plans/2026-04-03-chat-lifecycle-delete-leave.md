# Chat lifecycle delete/leave — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement server + core + FFI + clients for **leave** (`this_device` / `all_my_devices`), **DM global delete**, **DM re-open on peer message** with history cutoff for the returning side, **`left` vs `removed`** membership semantics, and **local store wipe** rules per spec `docs/superpowers/specs/2026-04-03-chat-lifecycle-delete-leave-design.md`.

**Architecture:** Extend Postgres schema for DM terminal state and optional per-account history cutoff; add HTTP handlers delegating to new `db` transactions that mirror existing epoch + MLS commit patterns; extend `ServerApiClient` + `SyncCoordinator` with control methods that call `MlsFacade::remove_members` (and add paths for re-open); add `LocalHistoryStore` APIs to fully drop chat state on initiating devices; surface FFI + regenerate bindings; add minimal UI actions on macOS/iOS/Android.

**Tech Stack:** Rust (`trix-types`, `trix-server`, `trix-core`), SQLx migrations, UniFFI/Swift/Kotlin bindings, existing OpenMLS wrapper in `trix-core`, contract gates (`make contract-check`).

---

## File structure

### Likely new / touched (verify paths while implementing)

| Area | Paths |
|------|--------|
| Migration | `migrations/NNNN_chat_lifecycle.sql` (new) |
| Types | `crates/trix-types/src/api.rs`, possibly `model.rs` |
| Server DB | `crates/trix-server/src/db.rs` |
| Server routes | `crates/trix-server/src/routes/chats.rs`, router wiring |
| Transport | `crates/trix-core/src/transport.rs` |
| Sync | `crates/trix-core/src/sync.rs` |
| Storage | `crates/trix-core/src/storage.rs` |
| Messenger | `crates/trix-core/src/messenger.rs` |
| FFI | `crates/trix-core/src/ffi.rs`, UniFFI definitions |
| Contracts | `docs/contracts.md` or generated OpenAPI if present — align |
| Tests | `crates/trix-server/tests/*`, `crates/trix-core/tests/*`, `crates/trix-core/src/*_test` modules |
| macOS | `apps/macos/Sources/TrixMac/App/AppModel.swift`, `WorkspaceView.swift` or sidebar, `TrixMessengerClient.swift` |
| iOS | `apps/ios/TrixiOS/Features/Chats/*`, bridges |
| Android | `apps/android/.../ChatRepository.kt`, `ChatsScreen.kt` |
| Generated | `bindings/*`, app `Generated/` mirrors — **regenerate, do not hand-edit** |

---

## Task 1: Schema + invariants

**Files:**
- Create: `migrations/NNNN_chat_lifecycle.sql`
- Modify: `crates/trix-server/src/db.rs` (types/queries as needed)

- [ ] **Step 1:** Add columns / enum usage per spec: e.g. `chats.closed_at` (or `lifecycle_status`), `chat_account_members.dm_history_cutoff_server_seq` or `reopen_generation` (pick one representation and document in migration comment).
- [ ] **Step 2:** Replace or supplement unique DM pair constraint with **partial unique** on `(dm_member_pair_key)` WHERE `chat_type = 'dm' AND closed_at IS NULL` (adjust names to match final column choice). Ensure `create_chat` conflict check uses the same predicate.
- [ ] **Step 3:** Run migration locally; `cargo sqlx prepare` if the repo uses offline query data (follow existing workflow).

**Verify:** `cargo check -p trix-server` after migration bind updates.

---

## Task 2: `trix-types` API shapes

**Files:**
- Modify: `crates/trix-types/src/api.rs`

- [ ] **Step 1:** Add `LeaveChatRequest { scope: LeaveScope, epoch, commit_message }`, `LeaveScope` enum (`ThisDevice` | `AllMyDevices`), `LeaveChatResponse` (mirror `ModifyChatMembersResponse` field style).
- [ ] **Step 2:** Add `DmGlobalDeleteRequest` / `DmGlobalDeleteResponse` (epoch + commit; response includes `chat_id`, `epoch`, changed ids).
- [ ] **Step 3:** If `ChatEvent` payloads need structured JSON, add serde types under `api` or `model` consistent with existing `ContentType::ChatEvent` usage.

**Verify:** `cargo check -p trix-types`.

---

## Task 3: Server — `leave` transaction

**Files:**
- Modify: `crates/trix-server/src/db.rs`, `crates/trix-server/src/routes/chats.rs`

- [ ] **Step 1:** Implement `leave_chat` (name TBD): **scope `this_device`** — validate actor device active in chat; reject if would orphan MLS (DM one-account-left case: resolve per OpenMLS — may need protocol branch documented in code comments); update `chat_device_members` to `removed`; bump epoch; insert commit like `remove_chat_devices`.
- [ ] **Step 2:** **scope `all_my_devices`** — remove all device rows for `actor_account_id`; set `chat_account_members.membership_status = 'left'`, `left_at = now()`; never use `'removed'` for voluntary leave; bump epoch; MLS commit removing all leaves for that account (reuse leaf index collection patterns from existing code).
- [ ] **Step 3:** **Group vs DM:** allow DM for both scopes; keep “cannot remove last member” semantics for **group** where applicable; for DM after `all_my_devices`, other account stays `active`.
- [ ] **Step 4:** Wire `POST /v0/chats/:id/leave` with auth same as other chat mutations.

**Verify:** New integration tests in `crates/trix-server` (see Task 7).

---

## Task 4: Server — `dm/global-delete` + list/detail filters

**Files:**
- Modify: `crates/trix-server/src/db.rs`, routes

- [ ] **Step 1:** Implement terminal close: both accounts → `left` or dedicated closed state; all devices `removed`; set `closed_at`; clear `dm_member_pair_key` or set pair key only on open rows per partial index design.
- [ ] **Step 2:** Ensure `list_chats_for_device` / `get_chat_detail_for_device` **exclude** closed chats and `left` accounts same as non-member.
- [ ] **Step 3:** `create_chat` for DM: allow new row when no open row for pair.

**Verify:** Tests for “global delete then recreate DM new id”.

---

## Task 5: Server — DM re-open on send

**Files:**
- Modify: `crates/trix-server/src/db.rs` (message create path — locate `create_message` / inbox fanout)

- [ ] **Step 1:** When peer (B) sends **application** message in DM where other account (A) is `left`: transition A to `active`, enqueue add-device / welcome flow (mirror `add_chat_members` or `add_chat_devices` semantics — pick minimal path that matches MLS); set **cutoff** for A so `get_chat_history` for A starts after re-open.
- [ ] **Step 2:** Emit `ChatEvent` system message if product requires (optional in first slice if tests cover server state without it — prefer adding for multi-device).
- [ ] **Step 3:** Idempotent re-open if A already active.

**Verify:** Core integration test or server test with two accounts (Task 7).

---

## Task 6: Push / realtime fanout

**Files:**
- Modify: server paths that resolve recipient devices for a chat (search `chat_device_members` + push)

- [ ] **Step 1:** Exclude devices with `membership_status != 'active'` from chat-targeted notifications.
- [ ] **Step 2:** Regression test or manual checklist entry in plan completion notes.

---

## Task 7: Server integration tests (TDD-friendly)

**Files:**
- Create or modify: `crates/trix-server/tests/*.rs` (follow existing harness)

- [ ] **Step 1:** Group: two devices same account — leave one → list chats differs; leave all → account `left`.
- [ ] **Step 2:** DM: one-way leave all → peer still has chat; peer sends → leaver sees chat in list with cutoff (history endpoint).
- [ ] **Step 3:** DM: global delete → `create_chat` same pair yields new `chat_id`.
- [ ] **Step 4:** Epoch mismatch → `409` / conflict as today.

**Run:** `cargo test -p trix-server`

---

## Task 8: `trix-core` — transport + sync + wipe

**Files:**
- Modify: `crates/trix-core/src/transport.rs`, `sync.rs`, `storage.rs`, `messenger.rs`

- [ ] **Step 1:** Add `ServerApiClient::leave_chat`, `delete_dm_global` HTTP calls.
- [ ] **Step 2:** Add `SyncCoordinator::leave_chat_control` — build MLS remove bundle for one or all local leaves (reuse `collect_leaf_indices_for_devices` / account variant); on success call `leave_chat` API; `refresh_chat_state`; align members.
- [ ] **Step 3:** `LocalHistoryStore::wipe_chat_completely(chat_id)` — remove chat from `state.chats`, messages, cursors, MLS local state keys; persist.
- [ ] **Step 4:** `MessengerClient` high-level methods calling sync + wipe per matrix from spec.

**Verify:** `cargo test -p trix-core` — add tests for wipe + apply_chat_list interaction.

---

## Task 9: FFI + bindings

**Files:**
- Modify: UniFFI `.udl` / proc-macro surface (find canonical definition in `trix-core`)
- Regenerate: `make ffi-bindings-swift` / `make ffi-bindings-kotlin` per `AGENTS.md`

- [ ] **Step 1:** Expose leave + dm global delete on `FfiSyncCoordinator` / `FfiMessengerClient` consistent with existing patterns.
- [ ] **Step 2:** Regenerate bindings; fix Swift/Kotlin compile if needed.

**Verify:** `make contract-check` and targeted `swift test` / Android unit compile as per repo norms.

---

## Task 10: Clients — minimal UI

**Files:**
- macOS: `AppModel.swift`, chat inspector or context menu
- iOS: `ConsumerChatDetailView` or settings row
- Android: `ChatsScreen.kt` / detail screen

- [ ] **Step 1:** Actions: “Leave chat (this device)” / “Leave chat (all my devices)” for group + DM; “Delete DM for both” only when `chat_type == dm`.
- [ ] **Step 2:** After success, reload workspace / apply list so UI matches server; local wipe already done in core.

**Verify:** Manual smoke or existing UI test pattern if any.

---

## Task 11: Docs + gates

**Files:**
- Modify: `docs/contracts.md` (if API is documented there)

- [ ] **Step 1:** Document new endpoints and semantics.
- [ ] **Step 2:** `make check` or `cargo check --workspace`; `make contract-check`.

---

## Execution notes

- Prefer **test-first** for server invariants (leave, global delete, re-open, recreate DM).
- Resolve **OpenMLS single-member DM** during Task 3/5 with a short ADR comment in `db.rs` or `docs/` only if required by behavior — avoid scope creep.
- Keep **kick** paths writing `removed`; **leave** paths writing `left`.

---

## Plan review

**Spec:** `docs/superpowers/specs/2026-04-03-chat-lifecycle-delete-leave-design.md`

After implementation, re-run smoke suites touching clients: `./scripts/client-smoke-harness.sh --suite macos --no-postgres` (and iOS/Android as appropriate per change scope).
