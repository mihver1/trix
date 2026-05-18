# Trix

Trix is a small private XMPP + OMEMO end-to-end encrypted messenger for a
closed group of friends.

The MVP direction is:

- Server: private XMPP, with ejabberd as the first product candidate because the
  MVP needs centralized account, group, push, and diagnostics control. Prosody
  remains a lightweight fallback for shell-managed spike deployments.
- Federation: disabled.
- Apple clients: native SwiftUI for iOS and macOS.
- Protocol and E2EE: XMPP transport with mandatory OMEMO encryption for DMs and
  group chats.
- Apple OMEMO implementation: Tigase Martin plus MartinOMEMO first, with
  GPL/AGPL obligations explicitly accepted or rejected for this non-commercial
  friends app.
- Control plane: Trix-owned operator APIs/scripts for users, directory,
  profiles, groups, diagnostics, and server operations.
- Deployment model: a tiny self-hosted server, not a public federated service.

This project is not a custom cryptography project, not a custom messaging
protocol, and not an Electron, React Native, Flutter, or web client project.

There are no live Matrix users to preserve. The legacy custom `trixd`/OpenMLS
prototype and short-lived Matrix experiment are not target architecture and have
been removed from the active repo surface.

## Current Repository Shape

- `server/xmpp/` contains the private XMPP server scaffold, deployment notes,
  operator scripts, restore checks, and smoke checklist.
- `apple/` contains the current SwiftUI Apple client scaffold for iOS and macOS.
  It still has `TrixMatrix*` target and project names for command compatibility.
  Source code should stay protocol-neutral and keep SDK/protocol calls behind
  service protocols and view models.
- `apps/trix-push-gateway/` contains the private APNs sender and XEP-0114 XMPP
  push component used by the XMPP deployment.
- `crates/trix-push/` contains APNs payload/client support for the push gateway.
- `docs/architecture.md` explains the XMPP + OMEMO direction.
- `docs/security.md` captures the private deployment threat model.
- `docs/mvp-checklist.md` lists the validation work needed before real use.
- `docs/tasks/` contains implementation tasks for the current XMPP MVP.
- `docs/xmpp-migration/` remains as planning history and risk context for the
  pivot.

## Run The XMPP Server

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

The current Apple project is still `TrixMatrix`-named until the compatibility
rename lands:

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

## Run The Push Gateway

Use deployment-local credentials only. Do not put real values in the repository.

```bash
TRIX_PUSH_GATEWAY_TOKEN='...' \
TRIX_APNS_TEAM_ID='...' \
TRIX_APNS_KEY_ID='...' \
TRIX_APNS_TOPIC='com.softgrid.trixapp' \
TRIX_APNS_PRIVATE_KEY_PATH='/absolute/path/to/AuthKey_ABC123XYZ.p8' \
cargo run -p trix-push-gateway
```

## MVP Status

Current target work:

- XMPP server scaffold and local smoke environment.
- Apple OMEMO feasibility and Martin/MartinOMEMO integration.
- Mandatory encrypted DM send/receive.
- Mandatory encrypted group send/receive.
- Directory-backed DM/group creation.
- Centralized operator control plane.
- Push notifications through APNs without plaintext payloads.
- TestFlight archive path for the new iOS and macOS clients.

Not production-ready:

- Apple OMEMO implementation path still needs signed-device validation.
- Group OMEMO over MUC still needs end-to-end smoke coverage.
- Push, directory/control-plane, and release smokes still need full closeout.

## Documentation

- [docs/architecture.md](docs/architecture.md)
- [docs/security.md](docs/security.md)
- [docs/mvp-checklist.md](docs/mvp-checklist.md)
- [docs/tasks/](docs/tasks/)
- [docs/xmpp-migration/](docs/xmpp-migration/)
- [server/xmpp/](server/xmpp/)
- [apple/README.md](apple/README.md)
- [apps/trix-push-gateway/README.md](apps/trix-push-gateway/README.md)
