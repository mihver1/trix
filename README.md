# Trix

`Trix` is an experimental native-first end-to-end encrypted messenger workspace. The repository currently combines a Rust backend (`trixd`), a shared Rust core (`trix-core`), a headless bot runtime, a separate macOS admin control app, and native clients for Android, iOS, and macOS.

Confirmed components in the repo today:

- single-binary `Axum` backend with `PostgreSQL`, automatic `sqlx` migrations, local blob storage, rate limiting, cleanup jobs, and websocket inbox delivery
- `v0` API surface for auth, accounts, directory search, device linking and approval, device revoke, key packages, chats, message history, inbox lease and ack, history sync, and blob upload and download
- shared `trix-core` library with `OpenMLS` group state, encrypted local stores, attachment helpers, device-transfer helpers, realtime and sync runtime, and `UniFFI` bindings
- `trix-bot` and `trix-botd` for headless encrypted bot accounts, plus Rust, Python, and Go echo-bot examples

This is still a development prototype, not a production deployment.

## Repository Layout

- `apps/trixd` backend binary entrypoint
- `apps/trix-botd` bot CLI and `JSON-RPC 2.0` stdio daemon
- `apps/android` Android client project
- `apps/ios` iOS client project
- `apps/macos` macOS client project
- `apps/macos-admin` macOS admin control app project
- `crates/trix-server` backend server library
- `crates/trix-core` shared client core, storage, MLS, realtime, and FFI surface
- `crates/trix-bot` headless bot runtime
- `crates/trix-types` shared API and domain types
- `docs/` project documentation
- `examples/bots/` Rust, Python, and Go bot examples
- `migrations/` SQL migrations applied by the server on startup
- `openapi/v0.yaml` current HTTP API contract

## Local Backend Quick Start

`trixd` reads process environment directly. Copying `.env.example` to `.env` is useful, but the file is not auto-loaded by the binary.

1. Prepare local environment variables:

```bash
cp .env.example .env
set -a
source .env
set +a
```

2. Start the bundled local `PostgreSQL` service:

```bash
docker compose up -d postgres
```

3. Run the server:

```bash
cargo run -p trixd
```

4. Check the health endpoint:

```bash
curl http://127.0.0.1:8080/v0/system/health
```

The repo also includes a `Dockerfile` for `trixd` and a `docker-compose.yml` with `postgres` and `app` services.

## Common Commands

```bash
make check
make run-server
make ffi-bindings
cargo test --workspace
swift test --package-path apps/macos-admin
./scripts/client-smoke-harness.sh --suite macos-admin --no-postgres
cargo run -p trix-botd -- stdio
```

## Clients And Bots

- Android details: [apps/android/README.md](apps/android/README.md)
- iOS details: [apps/ios/README.md](apps/ios/README.md)
- macOS details: [apps/macos/README.md](apps/macos/README.md)
- macOS admin details: [apps/macos-admin/README.md](apps/macos-admin/README.md)
- Bot harness: [docs/bot-harness.md](docs/bot-harness.md)
- FFI surface and binding generation: [docs/ffi-bindings.md](docs/ffi-bindings.md)
- Bot examples: [examples/bots/README.md](examples/bots/README.md)

## Additional Docs

- Product and architecture spec: [docs/v0-spec.md](docs/v0-spec.md)
- HTTP API contract: [openapi/v0.yaml](openapi/v0.yaml)
