# Trix

Trix is being pivoted into a small private Matrix-based end-to-end encrypted
messenger for a closed group of friends.

The new MVP direction is:

- Homeserver: Conduit.
- Federation: disabled.
- Apple client: native SwiftUI for iOS and macOS.
- Protocol and E2EE: Matrix through the Matrix Rust SDK, using the official
  Swift components where practical.
- Deployment model: a tiny self-hosted server, not a public federated service.

This project is not a custom cryptography project, not a custom messaging
protocol, and not an Electron, React Native, Flutter, or web client project.

## Current Repository Shape

The Matrix pivot is added next to the existing prototype so the current Apple
apps and TestFlight tooling stay available while the protocol layer changes.

- `server/` contains the Conduit Docker Compose setup, example `conduit.toml`,
  Caddy reverse proxy example, and server run notes.
- `apple/` contains a buildable SwiftUI Matrix client scaffold for iOS and
  macOS. It has service protocols, Keychain session storage, room list and
  timeline UI, and a mock Matrix service for local UI development.
- `docs/architecture.md` explains the Conduit plus Matrix Rust SDK direction.
- `docs/security.md` captures the small private deployment threat model.
- `docs/mvp-checklist.md` lists the validation work still needed before real
  use.
- `apps/ios` and `apps/macos` are the existing native clients backed by the
  legacy `trix-core`/OpenMLS stack.
- `apps/ios/scripts/build-testflight.sh` and
  `apps/macos/scripts/archive-testflight.sh` remain the current TestFlight
  publication paths.

The legacy Rust backend, OpenMLS client core, Android client, bot runtime, and
interop harnesses are still present. They are kept so existing build and release
workflows remain inspectable during the pivot, but new protocol work should
prefer the Matrix structure above.

## Run The Conduit Server

For local development:

```bash
cd server
docker compose up -d conduit
curl http://127.0.0.1:6167/_matrix/client/versions
```

`podman compose` can be used instead of `docker compose` on hosts where Docker
is not installed.

For a small VPS with TLS via Caddy:

```bash
cd server
cp .env.example .env
# Edit .env and conduit.toml before first boot.
docker compose --profile caddy up -d
```

Read [server/README.md](server/README.md) before choosing `server_name`.
For the intended deployment, `server_name` is `trix.selfhost.ru` and should be
treated as permanent once real accounts exist.

## Run The Apple Client

The first Matrix Apple scaffold is under `apple/`.

```bash
cd apple
xcodegen generate
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

For iOS simulator builds:

```bash
cd apple
xcodegen generate
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO
```

The scaffold hardcodes `https://trix.selfhost.ru` as the Matrix homeserver URL.
It uses the pinned `matrix-rust-components-swift` package through
`MatrixRustSDKAdapter`; a mock service remains available for local UI previews
and tests. The adapter boundary is documented in [apple/README.md](apple/README.md).

## MVP Status

Working in this first pivot slice:

- Conduit server files exist and can be run with Docker Compose after local
  configuration review.
- Caddy and Nginx reverse proxy examples are included.
- The live VPS deployment at `https://trix.selfhost.ru` responds on the Matrix
  client API and `.well-known` client discovery endpoint.
- SwiftUI Apple client scaffold builds with the pinned Matrix Rust SDK Swift
  package.
- The Apple scaffold has a pinned Matrix Rust SDK Swift dependency and a real
  adapter for password login, session restore, room list, timeline, and text
  send calls.
- Login form, Keychain-backed session persistence, room list, and timeline UI
  are present.
- Production SwiftUI flows exist for encrypted DM creation, private encrypted
  group room creation, and invite accept/decline.
- File/image attachment send and download are wired through Matrix SDK timeline
  and media APIs, with in-app image preview.
- Foreground room, invite, and selected timeline refresh is wired while the app
  scene is active.
- Matrix SDK device verification and recovery state are visible in the UI;
  recovery setup/confirmation is wired through SDK APIs.
- A DEBUG-only live iOS smoke path validates login, session restore, encrypted
  DM creation, encrypted send, encrypted receive, and logout cleanup against
  `trix.selfhost.ru`.
- Unimplemented security-sensitive features are visible in the UI and tracked
  in docs.

Not yet production-ready:

- Device verification verified-state validation after live SAS completion.
- Recovery/key backup persistence tests.
- Push notifications through a Matrix push gateway and APNs.
- Attachment live round-trip validation, OS open/share/export, group message
  live validation, and TestFlight scripts for the new Matrix app.
- Existing TestFlight scripts for `apps/ios` and `apps/macos` are preserved.

## Documentation

- [docs/architecture.md](docs/architecture.md)
- [docs/security.md](docs/security.md)
- [docs/mvp-checklist.md](docs/mvp-checklist.md)
- [docs/development-setup.md](docs/development-setup.md)
- [server/README.md](server/README.md)
- [apple/README.md](apple/README.md)

## Legacy Commands

The old prototype commands are still useful when touching legacy files:

```bash
cargo check -p trix-core
cargo test -p trix-core
swift test --package-path apps/macos
./scripts/client-smoke-harness.sh --list-suites
./scripts/client-smoke-harness.sh --suite ios-unit --no-postgres
```

Do not hand-edit generated UniFFI outputs. Do not remove TestFlight scripts
unless a replacement release path for the Matrix app exists.
