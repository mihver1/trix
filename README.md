# Trix

`Trix` is an experimental native-first end-to-end encrypted messenger workspace. The repository currently combines a Rust backend (`trixd`), a shared Rust core (`trix-core`), a headless bot runtime, a separate macOS admin control app, and native clients for Android, iOS, and macOS.

Confirmed components in the repo today:

- single-binary `Axum` backend with `PostgreSQL`, automatic `sqlx` migrations, local blob storage, rate limiting, cleanup jobs, websocket inbox delivery, a separate `/v0/admin/*` control surface, and optional APNs-backed background inbox wake-up pushes for iOS and macOS devices
- `v0` API surface for auth, accounts, directory search, device linking and approval, transfer bundles, device revoke, key packages, chats, message history, inbox lease and ack, history sync backfill and repair, blob upload and download, and operator admin/session/settings/users flows
- shared `trix-core` library with `OpenMLS` group state, encrypted local stores, attachment helpers, device-transfer helpers, safe messenger snapshots/timelines, realtime and sync runtime, and `UniFFI` bindings
- shared `strings.yaml` catalog plus `scripts/generate_strings.rb` for repo-wide user-facing chat strings, generating Android XML resources and iOS/macOS Swift lookup code for `en` and `ru`
- Android, iOS, and macOS consumer clients now share the task-first create/link onboarding model, stored-session recovery that keeps reconnect vs approval/relink states explicit, projected timelines with outgoing delivery/read ticks, attachment send/download, and inline previews for common image types; macOS also ships the beta client and a separate macOS admin app
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
- `deploy/public-test/` ingress and TLS overlay for `trix.artelproject.tech`
- `examples/bots/` Rust, Python, and Go bot examples
- `migrations/` SQL migrations applied by the server on startup
- `openapi/v0.yaml` current HTTP API contract

## Local Backend Quick Start

`trixd` reads process environment directly. Copying `.env.example` to `.env` is useful, but the file is not auto-loaded by the binary. The example file includes both consumer auth config and the admin control-plane credentials required by the current backend startup path.

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

For environment variable meanings, admin credentials, retention knobs, and rollout notes, see [docs/server-config.md](docs/server-config.md).

For APNs key placement and device lifecycle operations, see [docs/server-operations.md](docs/server-operations.md). `trixd` sends only safe wake-up pushes (`content-available` plus a `trix.event=inbox_update` marker), so notification text stays derived on-device from synced encrypted state.

## Common Commands

```bash
make check
make contract-check
make run-server
make strings-generate
cargo check -p trix-core
cargo test -p trix-core
make ffi-bindings
make ffi-bindings-swift
make ffi-bindings-kotlin
make ffi-parity-audit
cargo test --workspace
swift test --package-path apps/macos
swift build --package-path apps/macos-admin
swift run --package-path apps/macos-admin
swift test --package-path apps/macos-admin
./scripts/client-smoke-harness.sh --list-suites
./scripts/client-smoke-harness.sh --suite macos --no-postgres
./scripts/client-smoke-harness.sh --suite macos-admin --no-postgres
./scripts/client-smoke-harness.sh --suite ios-unit --no-postgres
./scripts/client-smoke-harness.sh --suite ios-server --stop-postgres
./scripts/client-smoke-harness.sh --suite ios-ui --stop-postgres
cargo run -q -p trix-botd -- stdio
```

## Clients And Bots

- Android details: [apps/android/README.md](apps/android/README.md)
- iOS details: [apps/ios/README.md](apps/ios/README.md)
- macOS details: [apps/macos/README.md](apps/macos/README.md)
- macOS admin details: [apps/macos-admin/README.md](apps/macos-admin/README.md)
- Bot harness: [docs/bot-harness.md](docs/bot-harness.md)
- Shared client string catalog and generation: [docs/client-localization.md](docs/client-localization.md)
- FFI surface and binding generation: [docs/ffi-bindings.md](docs/ffi-bindings.md)
- Bot examples: [examples/bots/README.md](examples/bots/README.md)

## Additional Docs

- Server config and admin/runtime knobs: [docs/server-config.md](docs/server-config.md)
- Release/pilot contract gates: [docs/contracts.md](docs/contracts.md)
- Client smoke harness: [docs/client-smoke-harness.md](docs/client-smoke-harness.md)
- Manual client QA checklist: [docs/client-test-checklist.md](docs/client-test-checklist.md)
- Onboarding simplification rationale: [docs/onboarding-simplification-review.md](docs/onboarding-simplification-review.md)
- Product and architecture spec: [docs/v0-spec.md](docs/v0-spec.md)
- Server setup, APNs, and device lifecycle: [docs/server-operations.md](docs/server-operations.md)
- HTTP API contract: [openapi/v0.yaml](openapi/v0.yaml)
- Public test ingress and TLS overlay: [deploy/public-test/README.md](deploy/public-test/README.md)
