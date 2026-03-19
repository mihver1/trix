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

The repository currently contains a compile-ready scaffold:

- workspace and crate layout
- backend HTTP router with health and version endpoints
- placeholder route groups for auth, accounts, devices, chats, key packages, inbox, and blobs
- initial migration draft
- single-node `docker compose` setup

## Next Steps

- wire `PostgreSQL` access and migrations into `trix-server`
- implement device registration and auth challenge flow
- add `OpenMLS` group state management into `trix-core`
- generate `UniFFI` bindings for the future `macOS` app

