# Bot Examples

These examples all target the same `trix-botd stdio` contract, except the Rust example, which uses `trix-bot` directly.

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

See `docs/bot-harness.md` for the runtime model and JSON-RPC contract.
