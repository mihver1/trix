# Development Setup

## Prerequisites

- Docker or a compatible `docker compose`.
- Xcode with iOS and macOS SDKs.
- XcodeGen.
- Swift 6-capable toolchain.
- Rust and Cargo only when working on legacy code or a Rust control-plane slice.

## XMPP Server

After the XMPP scaffold is present, start the local private server:

```bash
cd server/xmpp
cp .env.example .env
docker compose up -d
docker compose logs -f prosody
```

Use `podman compose` for the same commands when Docker is unavailable.

The local server should model the production constraints:

- client-to-server enabled;
- server-to-server federation disabled;
- MUC enabled for private groups;
- MAM enabled for encrypted history replay;
- HTTP file sharing/upload enabled for encrypted attachments;
- no public registration.

Create test users only with local disposable credentials. Do not commit generated
passwords, admin tokens, APNs keys, private keys, or real user data.

## Apple

The current Apple project is still Matrix-named until the protocol-neutral rename
lands. Generate the project:

```bash
cd apple
xcodegen generate
```

Build macOS:

```bash
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixMac \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Build iOS:

```bash
xcodebuild \
  -project TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build CODE_SIGNING_ALLOWED=NO
```

The next Apple implementation step is to rename the service/model boundary from
`Matrix*` to `Trix*`, keep the mock service for local UI development, and add an
`XMPPAdapter` only after the OMEMO spike proves the Apple stack.

## XMPP/OMEMO Spike

Before product implementation, validate with disposable accounts:

- login/session restore;
- encrypted DM send/receive;
- encrypted group send/receive in a members-only, non-anonymous MUC room;
- second device for one account;
- restart and replay encrypted history through MAM;
- encrypted attachment upload/download with byte equality;
- federation-off deployment check.

If this spike cannot pass without custom crypto, stop and document the blocker.

## Legacy Workflows

The previous prototype is still present. Use legacy commands only when editing
legacy files:

```bash
cargo check -p trix-core
cargo test -p trix-core
swift test --package-path apps/macos
./scripts/client-smoke-harness.sh --list-suites
```

Existing TestFlight scripts are still in:

- `apps/ios/scripts/build-testflight.sh`
- `apps/macos/scripts/archive-testflight.sh`
