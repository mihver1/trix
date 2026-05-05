# Agent Instructions

## Project Direction

Trix is pivoting from the legacy custom `trixd`/OpenMLS prototype to a small
private Matrix messenger.

Target architecture:

- Homeserver: Conduit.
- Federation: disabled for the MVP.
- Apple clients: native SwiftUI for iOS and macOS.
- Protocol and E2EE: Matrix Rust SDK through official Swift bindings where
  practical.
- Server deployment: tiny private self-hosted instance, not a public Matrix
  service.

Do not implement custom cryptography, custom key exchange, or a custom
messaging protocol. Do not manually manipulate Matrix encryption keys except via
Matrix SDK APIs.

## Repository Layout

- `server/`: Conduit Docker Compose setup, sample config, reverse proxy
  examples, and server run docs.
- `apple/`: new Matrix Apple client scaffold. It is currently a SwiftUI app
  with service protocols and a mock Matrix implementation.
- `docs/architecture.md`: Matrix pivot architecture.
- `docs/security.md`: private deployment threat model and E2EE caveats.
- `docs/mvp-checklist.md`: concrete validation checklist.
- `docs/development-setup.md`: local setup notes.
- `apps/ios`, `apps/macos`: legacy Apple clients backed by `trix-core` and
  OpenMLS. Keep their UI and release tooling intact while the Matrix path is
  brought up.
- `apps/ios/scripts/build-testflight.sh`: current iOS TestFlight path.
- `apps/macos/scripts/archive-testflight.sh`: current macOS TestFlight path.
- `crates/`, `apps/trixd`, `apps/android`, `apps/trix-botd`: legacy prototype
  code. Do not remove during small Matrix MVP slices unless explicitly asked.

## Package Managers

- Rust workspace: `cargo`
- Apple clients: `swift`, `xcodebuild`, `xcodegen`
- Local services: `docker compose` or `podman compose`

## Matrix MVP Commands

Generate the new Apple Matrix Xcode project:

```bash
cd apple
xcodegen generate
```

Build the new macOS Matrix scaffold:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Build the new iOS Matrix scaffold:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO
```

Run the live iOS smoke path only with temporary credentials passed through
environment variables. Use a signed simulator build for this path; unsigned
simulator builds can fail Keychain access:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/trixmatrix-dd-signed \
  build
```

Live smoke modes are `login`, `restore`, `encrypted-dm`, and `cleanup` through
`TRIX_MATRIX_LIVE_SMOKE_MODE`. The runner must print only `TRIX_LIVE_SMOKE`
status lines and must not print passwords, access tokens, registration tokens,
or decrypted message bodies.

Run Conduit locally:

```bash
cd server
docker compose up -d conduit
curl http://127.0.0.1:6167/_matrix/client/versions
```

Use `podman compose` for the same commands when Docker is unavailable.

Run Conduit with the bundled Caddy example:

```bash
cd server
cp .env.example .env
docker compose --profile caddy up -d
```

## Legacy Commands

Use these when editing legacy code:

```bash
cargo check -p trix-core
cargo test -p trix-core
swift test --package-path apps/macos
swift test --package-path apps/macos-admin
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO
./scripts/client-smoke-harness.sh --list-suites
./scripts/client-smoke-harness.sh --suite macos --no-postgres
./scripts/client-smoke-harness.sh --suite ios-unit --no-postgres
```

Existing TestFlight tooling:

```bash
cd apps/ios
./scripts/build-testflight.sh

cd apps/macos
./scripts/archive-testflight.sh
```

## Formatting And Linting Expectations

- Keep Swift code formatted in the surrounding style.
- Prefer small, direct SwiftUI views and small service objects.
- Keep Matrix SDK calls outside SwiftUI views except trivial wiring.
- Keep UI and session/sync logic separated through service protocols and view
  models.
- Keep documentation accurate when behavior changes.
- Do not hand-edit generated UniFFI files in legacy clients.

## Security Rules

- Never commit real domains beyond the intended placeholder/target domain
  `trix.selfhost.ru`.
- Never commit tokens, passwords, APNs keys, private keys, registration tokens,
  App Store Connect keys, or real user credentials.
- Never log Matrix access tokens.
- Never log decrypted message bodies in production paths.
- Do not add telemetry.
- Do not weaken Matrix E2EE for convenience.
- Do not implement "trust all devices silently" as a finished UX. Device
  verification may remain a documented MVP TODO, but the app must make that
  limitation visible.
- Use Keychain or Matrix SDK secure storage for session material when available.

## Commit Attribution

AI commits MUST include:

```text
Co-Authored-By: <agent name> <agent email>
```

## Definition Of Done

For Matrix MVP tasks:

- Server/client/docs structure remains clear.
- Conduit config and run steps are documented.
- Apple code builds, or blocked SDK integration is represented by protocols,
  mock services, and explicit docs.
- No custom crypto is added.
- No secrets are committed.
- Unimplemented MVP items are listed in `docs/mvp-checklist.md`.
- Existing TestFlight scripts are preserved unless explicitly replaced.
- Available build/test commands are run and exact results are reported.
