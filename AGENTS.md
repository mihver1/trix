# Agent Instructions

## Package Manager
- Rust workspace: `cargo`
- Apple clients: `swift` and `xcodebuild`
- Local services: `docker compose` (`./scripts/client-smoke-harness.sh` auto-detects `podman compose` first)

## Commit Attribution
- AI commits MUST include:
```text
Co-Authored-By: <agent name> <agent email>
```

## File-Scoped Commands
- TODO: no repo-native file-path lint/typecheck commands are documented; prefer the smallest crate, package, or smoke suite below.
- Rust crate checks: `cargo check -p trix-core`, `cargo test -p trix-core`
- macOS package tests: `swift test --package-path apps/macos`
- macOS admin tests: `swift test --package-path apps/macos-admin`
- macOS admin Xcode build/test: `xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO`, `xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" test`
- macOS admin build/run: `swift build --package-path apps/macos-admin`, `swift run --package-path apps/macos-admin`
- Smoke suites: `./scripts/client-smoke-harness.sh --list-suites`
- macOS smoke: `./scripts/client-smoke-harness.sh --suite macos --no-postgres`
- Targeted smoke: `./scripts/client-smoke-harness.sh --suite macos-admin --no-postgres`
- iOS unit smoke: `./scripts/client-smoke-harness.sh --suite ios-unit --no-postgres`
- iOS server smoke: `./scripts/client-smoke-harness.sh --suite ios-server --stop-postgres`
- iOS UI smoke: `./scripts/client-smoke-harness.sh --suite ios-ui --stop-postgres`
- Android smoke: `./scripts/client-smoke-harness.sh --suite android-unit --suite android-ui`

## Common Commands
- Start local Postgres: `docker compose up -d postgres`
- Default client smoke pack: `./scripts/client-smoke-harness.sh`
- Run backend: `cargo run -p trixd` or `make run-server`
- Contract gates: `make contract-check`
- Workspace check: `cargo check --workspace` or `make check`
- Workspace tests: `cargo test --workspace`
- Generate Swift bindings: `make ffi-bindings-swift`
- Generate Kotlin bindings: `make ffi-bindings-kotlin`
- Generate UniFFI bindings: `make ffi-bindings`
- Audit FFI parity: `make ffi-parity-audit`
- Verify checked-in UniFFI bindings: `./scripts/verify-uniffi-bindings.sh`
- Run bot daemon over stdio: `cargo run -q -p trix-botd -- stdio`

## Workflows
- Local backend: copy `.env.example` to `.env`, export it with `set -a; source .env; set +a`; the example file carries the admin auth env required by the current `trixd` startup path. Then verify `curl http://127.0.0.1:8080/v0/system/health` and `curl http://127.0.0.1:8080/v0/system/version`
- Physical-device backend: set a reachable `TRIX_PUBLIC_BASE_URL` and usually `TRIX_BIND_ADDR=0.0.0.0:8080` before generating link QR payloads. See `docs/server-operations.md`
- Client smoke harness: default pack runs `client-scenarios`, `safe-ffi`, `bot-runtime`, `macos`, `android-unit`; use `--no-postgres` or `--stop-postgres` when needed. See `docs/client-smoke-harness.md`
- Server-backed iOS smoke: `ios-server` / `ios-ui` auto-start local compose services, rebuild the `app` service, and require `jq` plus `curl` when not using `--no-postgres`. See `docs/client-smoke-harness.md`
- Bot harness: `trix-botd` supports `init`, `run`, `publish-key-packages`, `stdio`; export `TRIX_BOT_MASTER_SECRET` before `init`. See `docs/bot-harness.md`
- macOS admin: regenerate the Xcode project after `project.yml` changes with `xcodegen generate --spec apps/macos-admin/project.yml`
- Platform-specific iOS, macOS, and Android build/archive flows live in the app READMEs; keep those docs authoritative.

## Key Conventions
- Root commands should stay grounded in `README.md`, `Makefile`, `docs/client-smoke-harness.md`, `docs/contracts.md`, `docs/ffi-bindings.md`, `docs/server-config.md`, `docs/server-operations.md`, `apps/macos-admin/README.md`, and `examples/bots/README.md`
- Do not hand-edit generated UniFFI outputs without rerunning the documented binding workflow
