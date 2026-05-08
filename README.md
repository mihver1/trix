# Trix

Trix is being pivoted into a small private XMPP + OMEMO end-to-end encrypted
messenger for a closed group of friends.

The MVP direction is:

- Server: private XMPP, with ejabberd as the first product candidate because the
  MVP needs centralized account, group, push, and diagnostics control. Prosody
  remains a lightweight fallback for shell-managed spike deployments.
- Federation: disabled.
- Apple clients: native SwiftUI for iOS and macOS.
- Protocol and E2EE: XMPP transport with mandatory OMEMO encryption for DMs and
  group chats.
- Apple OMEMO spike: Tigase Martin plus MartinOMEMO first, with GPL/AGPL
  obligations explicitly accepted or rejected for this non-commercial friends app.
- Control plane: Trix-owned operator APIs/scripts for users, directory, profiles,
  groups, diagnostics, and server operations.
- Deployment model: a tiny self-hosted server, not a public federated service.

This project is not a custom cryptography project, not a custom messaging
protocol, and not an Electron, React Native, Flutter, or web client project.

There are no live Matrix users to preserve. The Matrix experiment may remain in
the tree temporarily as implementation reference, but the target MVP does not
need a Matrix bridge, Matrix data migration, or parallel Matrix operation.

## Current Repository Shape

- `server/xmpp/` is the target location for the private XMPP server scaffold,
  deployment notes, and smoke checklist.
- `server/` still contains older Conduit/Matrix files while the XMPP path is
  being brought up. Treat them as temporary experiment artifacts.
- `apple/` contains the current SwiftUI Apple client scaffold for iOS and macOS.
  It still has Matrix-named targets and types until the protocol-neutral rename
  lands. New protocol work should keep calls behind service protocols and view
  models.
- `docs/architecture.md` explains the XMPP + OMEMO direction.
- `docs/security.md` captures the private deployment threat model.
- `docs/mvp-checklist.md` lists the validation work needed before real use.
- `docs/xmpp-migration/` tracks the migration plan, parity checklist, spike
  checklist, and risk register.
- `apps/ios` and `apps/macos` are the existing native clients backed by the
  legacy `trix-core`/OpenMLS stack.
- `apps/ios/scripts/build-testflight.sh` and
  `apps/macos/scripts/archive-testflight.sh` remain the current TestFlight
  publication paths.

The legacy Rust backend, OpenMLS client core, Android client, bot runtime, and
interop harnesses are still present. They are kept so existing build and release
workflows remain inspectable during the pivot.

## XMPP Spike

Do not start a full Apple rewrite until the XMPP/OMEMO spike proves:

- an Apple-safe OMEMO implementation path exists for both iOS and macOS;
- encrypted DMs work across at least two devices;
- encrypted group chats work through members-only, non-anonymous MUC rooms;
- MAM can restore encrypted history after restart;
- HTTP upload plus encrypted media round-trips without plaintext server storage;
- federation is disabled and verified.

The first smoke should use disposable local accounts only.

## Run The XMPP Server

After the XMPP scaffold is present:

```bash
cd server/xmpp
cp .env.example .env
docker compose up -d
docker compose logs -f
```

Use `podman compose` instead of `docker compose` on hosts where Docker is not
installed.

Production federation checks:

```bash
nc -vz trix.selfhost.ru 5222
nc -vz trix.selfhost.ru 5269
```

Port `5222` should be reachable for client-to-server traffic. Port `5269` should
not be reachable for server-to-server federation.

## Run The Apple Client

The current Apple project is still Matrix-named until the protocol-neutral rename
lands:

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

The next Apple milestone is to rename the service boundary from `Matrix*` to
protocol-neutral `Trix*`, keep the mock service, then add an `XMPPAdapter` after
the OMEMO spike passes.

## MVP Status

Current target work:

- XMPP server scaffold and local smoke environment.
- Apple OMEMO feasibility spike.
- Protocol-neutral Apple service boundary.
- Mandatory encrypted DM send/receive.
- Mandatory encrypted group send/receive.
- Directory-backed DM/group creation.
- Centralized operator control plane.
- Push notifications through APNs without plaintext payloads.
- TestFlight archive path for the new iOS and macOS clients.

Not production-ready:

- Apple OMEMO implementation path is not yet validated.
- Group OMEMO over MUC is not yet validated.
- Federation-off deployment checks are not yet automated.
- Push, directory/control-plane, and TestFlight paths are not yet rebuilt for
  XMPP.

## Documentation

- [docs/architecture.md](docs/architecture.md)
- [docs/security.md](docs/security.md)
- [docs/mvp-checklist.md](docs/mvp-checklist.md)
- [docs/development-setup.md](docs/development-setup.md)
- [docs/xmpp-migration/](docs/xmpp-migration/)
- [server/xmpp/](server/xmpp/)
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

Do not hand-edit generated UniFFI outputs. Do not remove existing TestFlight
scripts unless a replacement release path exists.
