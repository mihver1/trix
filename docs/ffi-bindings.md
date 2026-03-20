# FFI Bindings

`trix-core` now exposes a `UniFFI` surface and ships a local `uniffi-bindgen` binary.

## Build The Library

```bash
cargo build -p trix-core --lib
```

This produces the Rust library artifacts, including the macOS debug dylib at:

```text
target/debug/libtrix_core.dylib
```

## Generate Swift Bindings

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language swift \
  --out-dir bindings/swift
```

## Generate Kotlin Bindings

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language kotlin \
  --out-dir bindings/kotlin
```

## Generate Both At Once

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language swift \
  --language kotlin \
  --out-dir bindings
```

## Make Targets

```bash
make ffi-bindings
make ffi-bindings-swift
make ffi-bindings-kotlin
make ffi-bindings OUT=/tmp/trix-bindings
```

## Notes

- The exported API is defined in [ffi.rs](/Users/m.verhovyh/Projects/trix/crates/trix-core/src/ffi.rs).
- The crate now builds as `lib`, `cdylib`, and `staticlib`.
- The current FFI surface is synchronous on purpose; client apps should call it off the UI thread.
- `FfiMlsFacade` now supports persistent state via `new_persistent(storage_root)`, `load_persistent(storage_root)`, `save_state()`, and `storage_root()`.
- Persistent MLS state is stored under the provided root as `storage.json` and `metadata.json`.
- `FfiSyncCoordinator` now supports persistent sync state via `new_persistent(state_path)`, plus `state_snapshot()`, `sync_chat_histories()`, `lease_inbox()`, `ack_inbox()`, and `record_chat_server_seq()`.
- Persistent sync state is stored as a JSON snapshot at the provided `state_path`.
- `FfiLocalHistoryStore` now supports persistent local encrypted-envelope history via `new_persistent(database_path)`, plus `list_chats()`, `get_chat()`, `get_chat_history()`, `apply_chat_history()`, and `apply_leased_inbox()`.
- `FfiSyncCoordinator` also exposes high-level convenience flows: `sync_chat_histories_into_store()` and `lease_inbox_into_store()`.
- `FfiLocalHistoryStore` now also exposes projected local timeline APIs: `projected_cursor()`, `project_chat_messages()`, and `get_projected_messages()`.
- `FfiLocalHistoryStore` also persists optional `chat -> MLS group_id` mapping and exposes `chat_mls_group_id()` / `set_chat_mls_group_id()`.
- The projection layer persists decrypted/application results separately from raw encrypted envelopes, so clients can build timeline UIs without replaying MLS on every screen load.
- `trix-core` now exposes a typed message body model through `ffi_serialize_message_body()` and `ffi_parse_message_body()`.
- `FfiServerApiClient` now exposes `search_account_directory(query, limit, exclude_self)` for authenticated handle/profile discovery.
- `FfiServerApiClient` also exposes `get_account(account_id)` and `update_account_profile(...)`.
- `FfiChatSummary` and `FfiChatDetail` now include `participant_profiles`, so clients can render chat lists and membership UIs without extra directory round-trips.
- `FfiChatSummary` and `FfiChatDetail` also include `pending_message_count` and optional `last_message`, so list UIs can show transport backlog and latest encrypted envelope without extra history calls.
- `pending_message_count` is intentionally transport-level backlog, not user-read state.
- `FfiLocalHistoryStore` now exposes local read-state APIs:
  - `chat_read_cursor()`
  - `chat_unread_count(self_account_id?)`
  - `get_chat_read_state(self_account_id?)`
  - `list_chat_read_states(self_account_id?)`
  - `mark_chat_read()`
  - `set_chat_read_cursor()`
- Local unread is derived from the projected timeline, excludes MLS control traffic and receipt payloads, and can optionally exclude messages sent by the current account.
- `FfiLocalHistoryStore` now also exposes high-level local view-model APIs:
  - `list_local_chat_list_items(self_account_id?)`
  - `get_local_chat_list_item(chat_id, self_account_id?)`
  - `get_local_timeline_items(chat_id, self_account_id?, after_server_seq?, limit?)`
- These methods merge stored chat metadata, participant profiles, local unread state, derived `display_title`, sender display names, outgoing flags, and message preview text so clients do not need to reimplement that stitching layer.
- Attachment helpers are now exposed in two layers:
  - low-level free functions:
    - `ffi_prepare_attachment_upload(payload, params)`
    - `ffi_build_attachment_message_body(blob_id, prepared)`
    - `ffi_decrypt_attachment_payload(body, encrypted_payload)`
  - high-level server helpers on `FfiServerApiClient`:
    - `upload_attachment(chat_id, payload, params)`
    - `download_attachment(body)`
- `upload_attachment(...)` performs client-side attachment encryption, computes encrypted blob sha256, creates/uploads the blob, and returns a ready-to-send attachment `FfiMessageBody`.
- `download_attachment(...)` downloads the encrypted blob and decrypts it locally using the attachment descriptor fields from the message body.
- In the attachment descriptor, `size_bytes` is the plaintext file size; blob upload size and `sha256` are derived from the encrypted payload.
- `FfiLocalProjectedMessage` now includes parsed `body` and `body_parse_error`, so clients can render typed text/reaction/receipt/attachment/chat-event items directly from the projected timeline.
- `FfiSyncCoordinator` now also exposes `send_message_body()`, which performs `MessageBody -> MLS encrypt -> POST /messages -> local store -> projected timeline` in one core call.
- `FfiChatDetail` now includes `device_members` with `device_id`, `account_id`, `leaf_index`, and `credential_identity`, so clients can resolve removals against MLS leaf indices without a parallel side channel.
- `FfiSyncCoordinator` now also exposes high-level control-plane flows:
  - `create_chat_control()`
  - `add_chat_members_control()`
  - `remove_chat_members_control()`
  - `add_chat_devices_control()`
  - `remove_chat_devices_control()`
- These control flows reserve key packages, generate MLS commit/welcome payloads, call the server, refresh local store state, and synthesize projected control events for locally-originated commits.
- Kotlin generation works without `ktlint`, but UniFFI will print a non-fatal formatting warning if `ktlint` is not installed.
- Kotlin sources are generated under `bindings/uniffi/trix_core/`.
