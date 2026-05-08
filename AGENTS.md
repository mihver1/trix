# Agent Instructions

## Project Direction

Trix is pivoting from the legacy custom `trixd`/OpenMLS prototype and the
short-lived Matrix experiment to a small private XMPP + OMEMO messenger.

Target architecture:

- XMPP server: ejabberd first when the centralized control plane is in scope;
  Prosody remains a lightweight fallback for shell-managed spike deployments.
- Federation: disabled for the MVP. Do not expose or rely on XMPP server-to-server
  federation.
- Apple clients: native SwiftUI for iOS and macOS.
- Protocol and E2EE: XMPP for transport and OMEMO for end-to-end encryption,
  using existing reviewed implementations where practical.
- Apple OMEMO spike: because this is a non-commercial app for friends, Tigase
  Martin plus MartinOMEMO is the first candidate if GPL/AGPL obligations are
  explicitly accepted. Still do the license/SBOM check before shipping.
- Server deployment: tiny private self-hosted instance, not a public XMPP
  service.
- Centralized Trix control plane: user provisioning, directory, profiles, group
  membership, diagnostics, and server operations live behind operator-controlled
  APIs or scripts.

There are no live Matrix users to preserve. Do not build a Matrix-to-XMPP bridge
or Matrix data migration path unless the user explicitly reverses this decision.

Do not implement custom cryptography, custom key exchange, or a custom messaging
protocol. Do not manually manipulate OMEMO encryption keys except through a
reviewed OMEMO implementation. If a safe Apple OMEMO library path cannot be
validated for both DMs and group chats, stop and document the blocker instead of
writing crypto in the app.

## Repository Layout

- `server/xmpp/`: new private XMPP server scaffold, deployment notes, and smoke
  checklist.
- `server/`: older Conduit/Matrix server files may remain while the XMPP spike is
  in flight. Treat them as temporary experiment artifacts, not the target MVP.
- `apple/`: current SwiftUI Apple client scaffold. It still contains Matrix-named
  types until the protocol-neutral rename lands. Keep SDK/protocol calls behind
  service protocols and view models.
- `docs/architecture.md`: XMPP + OMEMO target architecture.
- `docs/security.md`: private deployment threat model and E2EE caveats.
- `docs/mvp-checklist.md`: concrete XMPP/OMEMO validation checklist.
- `docs/xmpp-migration/`: migration plan, parity checklist, spike checklist, and
  risk register for the XMPP pivot.
- `apps/ios`, `apps/macos`: legacy Apple clients backed by `trix-core` and
  OpenMLS. Keep their UI and release tooling intact while the new XMPP path is
  brought up.
- `apps/ios/scripts/build-testflight.sh`: current iOS TestFlight path.
- `apps/macos/scripts/archive-testflight.sh`: current macOS TestFlight path.
- `crates/`, `apps/trixd`, `apps/android`, `apps/trix-botd`: legacy prototype
  code. Do not remove during small XMPP MVP slices unless explicitly asked.

## Package Managers

- Rust workspace: `cargo`
- Apple clients: `swift`, `xcodebuild`, `xcodegen`
- Local services: `docker compose` or `podman compose`

## XMPP MVP Commands

Run the private XMPP scaffold locally after it exists:

```bash
cd server/xmpp
cp .env.example .env
docker compose up -d
docker compose logs -f
```

Use `podman compose` for the same commands when Docker is unavailable.

Expected production checks:

```bash
# Client-to-server should be reachable.
nc -vz trix.selfhost.ru 5222

# Server-to-server federation must not be reachable.
nc -vz trix.selfhost.ru 5269
```

Create test accounts only with deployment-local secrets. Never commit passwords,
tokens, private keys, APNs keys, or real user credentials.

## Apple Commands

Generate the current Apple Xcode project:

```bash
cd apple
xcodegen generate
```

Build the current macOS Apple scaffold:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Build the current iOS Apple scaffold:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO
```

These target names are still Matrix-named until the protocol-neutral Apple rename
lands. Do not treat that naming as the product direction.

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
- Keep XMPP and OMEMO calls outside SwiftUI views except trivial wiring.
- Keep UI and session/sync logic separated through service protocols and view
  models.
- Keep documentation accurate when behavior changes.
- Do not hand-edit generated UniFFI files in legacy clients.

## Security Rules

- Never commit real domains beyond the intended placeholder/target domain
  `trix.selfhost.ru`.
- Never commit tokens, passwords, APNs keys, private keys, registration tokens,
  App Store Connect keys, or real user credentials.
- Never log XMPP passwords, auth tokens, SASL material, OMEMO secrets, private
  keys, or full device trust secrets.
- Never log decrypted message bodies in production paths.
- Do not add telemetry.
- Do not weaken OMEMO E2EE for convenience.
- Do not implement "trust all devices silently" as a finished UX. Device trust
  limitations may remain documented MVP TODOs, but the app must make them visible.
- Use Keychain or a reviewed secure store for session material and OMEMO local
  state when available.
- Plaintext DM/group sending must be blocked in Trix product chats.

## Commit Attribution

AI commits MUST include:

```text
Co-Authored-By: <agent name> <agent email>
```

## Definition Of Done

For XMPP MVP tasks:

- Server/client/docs structure remains clear.
- Federation is disabled in config and by deployment checks.
- Apple code builds, or blocked OMEMO integration is represented by protocols,
  mock services, and explicit docs.
- DM and group chat E2EE are mandatory; plaintext sending is impossible in product
  flows.
- No custom crypto is added.
- No secrets are committed.
- Unimplemented MVP items are listed in `docs/mvp-checklist.md`.
- Existing TestFlight scripts are preserved unless explicitly replaced.
- Available build/test/smoke commands are run and exact results are reported.
