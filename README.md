# Trix

`Trix` is a native-first end-to-end encrypted messenger prototype built around:

- `Rust` backend as a single binary
- `PostgreSQL` for metadata and delivery state
- local filesystem blob storage for encrypted attachments
- `OpenMLS` as the planned group-crypto layer
- `macOS` as the first client platform

## Repository Layout

- `apps/trixd` backend binary
- `apps/macos` macOS app scaffold and integration notes
- `crates/trix-core` shared client core scaffold
- `crates/trix-server` backend server library scaffold
- `crates/trix-types` shared domain and API types
- `docs/v0-spec.md` architecture and product spec
- `migrations/` initial PostgreSQL schema draft
- `openapi/v0.yaml` API contract scaffold

## Quick Start

1. Copy `.env.example` to `.env`.
2. Start local infrastructure with `docker compose up postgres`.
3. Run `cargo run -p trixd`.

## Current State

The repository currently contains a compile-ready scaffold plus the first working backend vertical slice:

- workspace and crate layout
- backend HTTP router with health and version endpoints
- `PostgreSQL` bootstrap and automatic migrations on startup
- working `create account`, `auth challenge`, `auth session`, `accounts/me`, and `devices` endpoints
- Ed25519 verification for device auth challenge flow
- JWT-based device session tokens
- initial migration draft
- single-node `docker compose` setup

## Next Steps

- add `OpenMLS` group state management into `trix-core`
- implement device linking and revocation flows
- implement chat creation and encrypted message append paths
- generate `UniFFI` bindings for the future `macOS` app
