# Bot Examples

These examples all target the same `trix-botd stdio` contract, except the Rust example, which uses `trix-bot` directly.
They echo text messages and save incoming files under `state_dir/downloads/`.

## Paths

- `python/echo_bot.py`
- `python/trixbot_client.py`
- `go/cmd/echo-bot/main.go`
- `go/trixbot/client.go`
- `../../crates/trix-bot/examples/echo_bot.rs`

## Common Environment

- `TRIX_SERVER_URL`
- `TRIX_BOT_STATE_DIR`
- `TRIX_BOT_PROFILE_NAME`
- `TRIX_BOT_HANDLE`
- `TRIX_BOT_MASTER_SECRET`
- `TRIX_BOT_MASTER_SECRET_ENV`
- `TRIX_BOT_PLAINTEXT_STORE=1` for local plaintext state
- `TRIX_BOTD_CMD` to override the stdio command used by Python and Go examples

## Quick Start

Initialize a local bot identity:

```bash
export TRIX_BOT_MASTER_SECRET=dev-secret

cargo run -p trix-botd -- init \
  --server-url http://127.0.0.1:8080 \
  --state-dir ./.trix-bot \
  --profile-name "Echo Bot" \
  --handle echo-bot
```

Run the stdio daemon the Python and Go examples expect by default:

```bash
cargo run -q -p trix-botd -- stdio
```

If you need a different launch command, set `TRIX_BOTD_CMD` before starting the example wrapper.

See `docs/bot-harness.md` for the runtime model and JSON-RPC contract.
