# Trix

`Trix` is a native-first end-to-end encrypted messenger prototype built around:

- `Rust` backend as a single binary
- `PostgreSQL` for metadata and delivery state
- local filesystem blob storage for encrypted attachments
- `OpenMLS` as the planned group-crypto layer
- `macOS` as the first client platform
- headless `E2EE` bot accounts via `trix-bot`

## Repository Layout

- `apps/trixd` backend binary
- `apps/trix-botd` bot CLI and `JSON-RPC` stdio daemon
- `apps/macos` macOS app scaffold and integration notes
- `crates/trix-bot` headless bot runtime
- `crates/trix-core` shared client core scaffold
- `crates/trix-server` backend server library scaffold
- `crates/trix-types` shared domain and API types
- `examples/bots` Rust, Python, and Go bot examples
- `docs/bot-harness.md` bot harness runtime and IPC contract
- `docs/v0-spec.md` architecture and product spec
- `migrations/` initial PostgreSQL schema draft
- `openapi/v0.yaml` API contract scaffold

## Quick Start

1. Copy `.env.example` to `.env`.
2. Start local infrastructure with `docker compose up postgres`.
3. Run `cargo run -p trixd`.

## Bot Harness

`Trix` now includes a `v1` bot harness that runs bots as ordinary single-device encrypted clients:

- `crates/trix-bot` is the direct Rust API.
- `apps/trix-botd` exposes CLI and `JSON-RPC 2.0` over stdio for Python, Go, or other runtimes.
- `examples/bots` contains echo-bot examples for Rust, Python, and Go.

See `docs/bot-harness.md` for setup and `docs/ffi-bindings.md` for the binding surface.

## Current State

The repository currently contains a compile-ready scaffold plus the first working backend vertical slice:

- workspace and crate layout
- backend HTTP router with health and version endpoints
- `PostgreSQL` bootstrap and automatic migrations on startup
- working `create account`, `auth challenge`, `auth session`, `accounts/me`, and `devices` endpoints
- Ed25519 verification for device auth challenge flow
- JWT-based device session tokens
- persistent local history, projection, and MLS state in `trix-core`
- control-plane chat membership flows on top of `OpenMLS`
- headless `E2EE` bot runtime with websocket/polling sync and `JSON-RPC` stdio bindings
- initial migration draft
- single-node `docker compose` setup

## Next Steps

- implement device linking and revocation flows for all client types
- extend bot events beyond text-only delivery
- add mobile clients on top of the same `trix-core` primitives
- harden production ops around blob storage, retries, and observability
