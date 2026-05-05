# Development Setup

## Prerequisites

- Docker or a compatible `docker compose`.
- Xcode with iOS and macOS SDKs.
- XcodeGen.
- Swift 6-capable toolchain.
- Rust and Cargo only when working on legacy code.

## Server

Start Conduit locally:

```bash
cd server
docker compose up -d conduit
curl http://127.0.0.1:6167/_matrix/client/versions
```

Use `podman compose` for the same commands when Docker is unavailable.

The local Conduit config still uses `server_name = "trix.selfhost.ru"` so test
Matrix IDs match the intended private deployment. For real devices, run behind
TLS and use `https://trix.selfhost.ru`.

## Apple

Generate the project:

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

The app uses the pinned Matrix Rust SDK Swift package through
`MatrixRustSDKAdapter`. A mock service remains available for local UI
development by constructing `MatrixAppModel(matrixService: MockMatrixService())`
in previews or test harnesses.

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
