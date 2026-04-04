# Chat lifecycle: delete, leave, and DM reopen — design

## Summary

This design adds explicit **chat lifecycle** semantics for **group** and **DM** chats: **leave one device**, **leave all devices of an account** (product “one-way delete”), **DM global delete** (terminate dialog and allow a **new** DM between the same account pair), and **DM re-open** after one-way leave when the peer sends a message. It builds on existing MLS primitives (`remove_members` / `remove_devices`, epoch-gated control messages) and extends server membership state so voluntary exit is distinct from admin kick.

**Product decisions locked in this spec**

- **Group:** no “global delete for everyone”; only **leave** variants and local history rules.
- **One-way delete** = **leave all devices** of the acting account from the chat, with **full local history wipe** on all of that account’s devices.
- **Group leave, one device:** that device gets **full local wipe** and **no further updates/pushes** for that chat until the device is **manually re-added**; on re-add it may **backfill** history that still exists on the server for the chat (other members’ timeline unchanged).
- **Group leave, all devices** then **manual re-add:** the returning account sees an **empty** timeline (no restoration of pre-leave history for that account).
- **DM global delete:** terminal for **both** sides; **new** `chat_id` on next DM between the same pair (`dm_member_pair_key` must be releasable).
- **DM one-way delete:** leaving account is **out** (all devices removed from MLS for that `chat_id`); **peer keeps** the same `chat_id` and history. When the peer sends again, the leaving account’s clients **see the chat return with no old history**, only **new welcome** and subsequent messages.

## Context

Current codebase (see `crates/trix-server/src/db.rs`, `crates/trix-core/src/sync.rs`):

- **Group member removal** (`remove_chat_members`) applies only to **other** accounts; **cannot remove acting account**.
- **Device removal** (`remove_chat_devices`) removes **sibling** devices only; **cannot remove acting device**.
- **DM** membership mutations are rejected for non-group chats.
- **Local store** (`LocalHistoryStore::apply_chat_list`) can **hide** chats not present in the server list while **retaining** local history until explicitly cleared — new flows require **explicit wipe** after successful leave/delete.
- SQL already defines `membership_status` enum including **`left`**, but Rust paths today primarily use **`removed`** for kicks; voluntary leave should use **`left`** for clarity and auditing.

## Goals

- First-class **leave** and **DM global delete** APIs and sync/FFI paths.
- Correct **MLS** evolution (commits, epoch) aligned with server rows.
- **Deterministic local wipe** rules per operation and device scope.
- **DM re-open** after one-way leave with **history cutoff** for the returning side only.
- **ChatEvent** (or equivalent) payloads so multi-device clients converge without ad hoc rules.

## Non-Goals

- Message-level “delete for everyone” / unsend (separate feature).
- Group-wide “delete chat for all participants” (explicitly out of scope).
- Changing kick semantics beyond distinguishing **`removed`** (kick) vs **`left`** (voluntary).

## Decision summary

Adopt **explicit lifecycle model** (approach 2 from brainstorming):

1. **Account-level:** `active` | `left` (voluntary) | `removed` (kick).
2. **Device-level:** `active` | `removed` (and existing pending states as today).
3. **DM global delete:** terminal chat row + release pair key; new DM = new `chat_id`.
4. **DM one-way:** peer retains chat; server-driven **re-open** on next message from peer with **cutoff** so returning side never sees pre-leave ciphertext stream as current timeline (server filter and/or per-account cursor + local wipe).

---

## Architecture

### 1. States and transitions

**`chat_account_members` (conceptual)**

| State     | Meaning |
|-----------|---------|
| `active`  | Normal participant. |
| `left`    | Voluntarily left (one-way delete / leave all devices). |
| `removed` | Kicked by admin/owner (existing behavior). |

**`chat_device_members`**

- After **leave this device**: that device’s row → `removed`; MLS leaf removed.
- After **leave all my devices**: all rows for that account in this chat → `removed`; account → `left`.

**DM-specific**

- **One-way:** one account `left`, other `active`; same `chat_id` for the peer.
- **Global delete:** both accounts out; chat **closed**; pair key freed for a **new** chat.

### 2. Operation matrix

#### Group

| Action | Server | MLS | Initiator devices | Other participants |
|--------|--------|-----|-------------------|---------------------|
| Leave **this device** | Remove device membership; epoch + commit | Remove one leaf | Full **local wipe** on that device; no list/push for chat | Unchanged |
| Leave **all my devices** | All actor devices removed; account → `left` | Remove all actor leaves | Full local wipe on **all** actor devices | Unchanged |
| Re-add after leave-all | Account + devices added again | add/welcome flow | **Empty** timeline for re-added account (no backfill of pre-leave history for them) | History unchanged on clients that never left |

**Leave one device, then re-add:** that device may **backfill** server history still valid for the chat (per product: yes).

#### DM

| Action | Server | MLS | Side A (initiator) | Side B |
|--------|--------|-----|--------------------|--------|
| One-way (A leaves all devices) | A → `left`, all A devices `removed` | A’s leaves removed | Wipe; chat gone from UI | Same `chat_id`, unchanged |
| B sends after A left | Re-open: A → `active`, A devices re-added | Commit + welcome for A | Chat appears; **no** old history; welcome + new msgs | Keeps full history |
| Global delete | Both out; chat terminal; free `dm_member_pair_key` | All leaves out | Wipe | Wipe |
| New DM after global | `create_chat` → **new** `chat_id` | New MLS group | Fresh | Fresh |

### 3. HTTP API (v0)

New endpoints (names can be unified during implementation):

- **`POST /v0/chats/{chat_id}/leave`**  
  Body: `{ "scope": "this_device" | "all_my_devices", "epoch": u64, "commit_message": … }`  
  Applies to **group and DM**. Validates membership; applies MLS commit; updates rows; sets account `left` when scope is `all_my_devices`.

- **`POST /v0/chats/{chat_id}/dm/global-delete`** (DM only; alternatively one URL with `kind` in JSON)  
  Body: `{ "epoch": u64, "commit_message": … }`  
  Terminates DM for both accounts; clears pair constraint for a future DM.

Responses mirror existing modify patterns: `chat_id`, `epoch`, changed `account_id` / `device_id` lists as appropriate.

**DM re-open** is **not** a separate client action: triggered when **peer** sends an application message while the other side is `left` — server performs membership transition + welcome generation per MLS rules.

### 4. Core / FFI

- **`SyncCoordinator`:** `leave_chat_control` (or split by scope) wrapping MLS `remove_members` / existing device index collection + new HTTP call + refresh + align device members.
- **`MessengerClient`:** `leaveConversation(scope:)`, `deleteDmGlobally()` (or names matching platform style).
- After success: **mandatory local wipe** for affected devices per matrix above.
- Regenerate Swift/Kotlin via documented FFI workflow.

### 5. ChatEvent

Use **`ContentType::ChatEvent`** (or dedicated system channel) with typed payloads, e.g.:

- `participant_left` (account_id, optional device scope)
- `dm_reopened` (account_id returned, epoch)
- `dm_globally_deleted`

Enables multi-device convergence and debugging.

### 6. Data model / migrations

1. Use **`left`** in application code for voluntary account exit; keep **`removed`** for kick.
2. DM **terminal** state: e.g. `chats.closed_at` / `lifecycle_status` + ensure **`dm_member_pair_key`** uniqueness applies only to **non-closed** DMs (partial unique index if supported).
3. **Cutoff for DM re-open:** persist per-account marker (e.g. `reopen_generation` or `history_cutoff_server_seq` on `chat_account_members` for DM) so `get_chat_history` for the returning account excludes pre-reopen messages.
4. Audit all queries that assume only `active` — treat `left` like non-member for listing; retain row for history policy and audits.

### 7. Testing

Minimum scenarios:

- Group: leave one device → second device still in; first gets no pushes; re-add first → backfill behavior.
- Group: leave all → re-add account → empty timeline for them; others unchanged.
- DM: one-way → peer message → re-open; A no old history, B retains; MLS epoch consistent.
- DM: global delete → new DM → new `chat_id`.
- Epoch conflict and concurrent leave + send.

### 8. Rollout order

1. Server + migrations + API.
2. `trix-core` control paths + local wipe.
3. Contract check + FFI + bindings.
4. macOS / iOS / Android UI entry points.
5. External API docs if maintained separately.

## Open implementation notes

- **MLS group size after one-way DM:** when only one account remains represented in the group, implementation must satisfy OpenMLS rules for valid group state until re-open (may require explicit protocol decision — validate during implementation against `MlsFacade` / `openmls` constraints).
- **Push routing:** devices with `removed` membership must be excluded from chat-targeted push fanout for that `chat_id`.

## References

- `crates/trix-server/src/db.rs` — `create_chat`, `remove_chat_members`, `remove_chat_devices`, `list_chats_for_device`
- `crates/trix-core/src/sync.rs` — `remove_chat_members_control`, `remove_chat_devices_control`
- `crates/trix-core/src/storage.rs` — `apply_chat_list`, local hide vs history
- `migrations/0001_init.sql` — `membership_status`, `dm` pair key, `archived_at`
