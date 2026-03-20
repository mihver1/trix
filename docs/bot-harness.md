# Bot Harness

`Trix` now includes a `v1` headless bot harness for ordinary end-to-end encrypted accounts.

## Model

- Bots are ordinary single-device accounts with `platform="bot"`.
- The backend does not have bot-only endpoints, permissions, or plaintext delivery paths.
- Rust integrations use the `trix-bot` crate directly.
- Python, Go, and other runtimes integrate through `trix-botd stdio` using `JSON-RPC 2.0`.

## Components

- `crates/trix-bot`
  - bot lifecycle
  - encrypted/plaintext identity store
  - auth refresh
  - history sync
  - websocket with polling fallback
  - deduped text/unsupported event emission
- `apps/trix-botd`
  - CLI entrypoints: `init`, `run`, `publish-key-packages`, `stdio`
  - versioned IPC namespace: `bot.v1.*`
- `trix-core`
  - inbound bootstrap from `welcome_ref`
  - persisted `chat -> MLS group_id` mapping for externally created chats
  - headless projection path for decrypted local timelines

## State And Secrets

The bot runtime stores its local state under `state_dir`:

- `history-store.json`
- `sync-state.json`
- `runtime-state.json`
- `mls/`
- `identity.enc.json` by default
- `identity.json` only when `plaintext_dev_store=true`

Encrypted identity storage uses `Argon2id + ChaCha20-Poly1305`. The master secret is read from the env var named by `master_secret_env`, or `TRIX_BOT_MASTER_SECRET` by default.

## CLI

Initialize or load a bot state directory:

```bash
export TRIX_BOT_MASTER_SECRET=dev-secret

cargo run -p trix-botd -- init \
  --server-url http://127.0.0.1:8080 \
  --state-dir ./.trix-bot \
  --profile-name "Echo Bot" \
  --handle echo-bot
```

Development plaintext mode:

```bash
cargo run -p trix-botd -- init \
  --server-url http://127.0.0.1:8080 \
  --state-dir ./.trix-bot-dev \
  --profile-name "Echo Bot" \
  --handle echo-bot \
  --plaintext-dev-store
```

Stream runtime events as newline-delimited JSON:

```bash
cargo run -p trix-botd -- run \
  --state-dir ./.trix-bot \
  --server-url http://127.0.0.1:8080
```

Manually republish key packages:

```bash
cargo run -p trix-botd -- publish-key-packages \
  --state-dir ./.trix-bot \
  --server-url http://127.0.0.1:8080 \
  --count 32
```

## JSON-RPC Stdio Contract

Launch the daemon:

```bash
cargo run -q -p trix-botd -- stdio
```

Requests:

- `bot.v1.init`
- `bot.v1.start`
- `bot.v1.stop`
- `bot.v1.list_chats`
- `bot.v1.get_timeline`
- `bot.v1.send_text`
- `bot.v1.publish_key_packages`

Notifications:

- `bot.v1.ready`
- `bot.v1.text_message`
- `bot.v1.connection_changed`
- `bot.v1.unsupported_message`
- `bot.v1.error`

Minimal request example:

```json
{"jsonrpc":"2.0","id":1,"method":"bot.v1.init","params":{"server_url":"http://127.0.0.1:8080","state_dir":"./.trix-bot","profile_name":"Echo Bot","handle":"echo-bot","master_secret_env":"TRIX_BOT_MASTER_SECRET","plaintext_dev_store":false}}
```

Minimal notification example:

```json
{"jsonrpc":"2.0","method":"bot.v1.text_message","params":{"chat_id":"c31a1ca0-2ae5-4cf9-a4ab-0da06a68f0cb","message_id":"63ffed4a-7df7-4f80-a3bc-61f9f3fdf479","server_seq":14,"sender_account_id":"93b2a745-10aa-4e7e-93b5-c2e8423054cc","sender_device_id":"c1b5464d-0a3f-4a54-bbf4-6f624eeb3e32","text":"hello bot","created_at_unix":1742474480}}
```

## Examples

Repo-local examples live under `examples/bots/`:

- `python/trixbot_client.py` and `python/echo_bot.py`
- `go/trixbot/client.go` and `go/cmd/echo-bot/main.go`
- `crates/trix-bot/examples/echo_bot.rs`

## Scope

`v1` intentionally excludes:

- multi-device bot accounts
- attachments, reactions, receipts, and admin control flows in the event surface
- webhook-only or server-side bot execution
- automatic key-package low-watermark replenishment
