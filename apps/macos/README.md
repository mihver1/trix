# Trix macOS Client

`apps/macos` now contains the closed-beta macOS client slice as a `SwiftPM` app target backed by `trix-core` UniFFI.

## Current Scope

- `SwiftUI` macOS app entrypoint
- task-first first-device onboarding and linked-device restore with explicit server availability checks
- challenge/session sign-in using `trix-core` UniFFI key material and transport client
- directory-backed DM/group creation
- local FFI chat list, timeline, read-state, and outgoing delivery/read tick decoration
- text and attachment messaging with optimistic local send rows
- inline previews for common image attachment types with Quick Look full preview on open
- profile editing, device approval/revoke and notification settings
- background inbox sync via polling fallback plus APNs wake-up pushes for local notifications
- local session persistence in `Application Support`
- secret material persisted in `Keychain`
- persistent local history store and sync cursor state under `Application Support/com.softgrid.trixapp/workspaces/<account-id>/`
- stale restore paths now preserve reconnect vs relink-required recovery states instead of silently dropping back into a blank bootstrap form
- advanced operational tooling under `Settings > Advanced`

## Layout

```text
apps/macos/
  Package.swift
  Sources/TrixMac/
    App/
    Features/
    Bridge/
    Support/
  Tests/TrixMacTests/
```

## Run

```bash
cd apps/macos
./scripts/build-trix-core-universal.sh
swift build
swift test
swift run TrixMac
```

You can also open `Package.swift` in `Xcode` and run the `TrixMac` target as a regular macOS app.

`Package.swift` resolves `libtrix_core.a` from `../../target/macos-universal/<Configuration>/` by default. `./scripts/build-trix-core-universal.sh` prepares that archive for the active Swift build configuration. Override that lookup with `TRIX_CORE_ARTIFACTS_PATH=/abs/path/containing/libtrix_core.a` when you want to pin a specific Rust artifact directory instead.

Keep the Rust build on `MACOSX_DEPLOYMENT_TARGET=14.0` to match the app target and avoid linker version warnings. The repo-standard smoke entrypoint for this package is:

```bash
./scripts/client-smoke-harness.sh --suite macos --no-postgres
```

## Closed Beta Build

Build a self-contained `.app` bundle:

```bash
cd apps/macos
./scripts/build-beta.sh
```

That script:

- builds `trix-core` in release mode
- builds the macOS client in release mode
- packages `dist/TrixMac.app`
- optionally codesigns when `CODESIGN_IDENTITY` is set
- optionally notarizes when `NOTARYTOOL_PROFILE` is set

Useful overrides:

```bash
TRIX_CORE_ARTIFACTS_PATH=/abs/path/to/target/release \
TRIX_MARKETING_VERSION=0.1.0-beta.2 \
TRIX_BUILD_VERSION=$(git rev-parse --short HEAD) \
./scripts/build-beta.sh
```

## TestFlight Archive

Archive and export for App Store Connect / TestFlight:

```bash
cd apps/macos
./scripts/archive-testflight.sh
```

That script now refreshes the checked-in Swift bridge and rebuilds the fresh universal `trix-core` archive before running `xcodebuild archive`, so TestFlight exports do not reuse stale FFI artifacts.

## Bindings

Swift bindings are checked into `apps/macos`:

- `Sources/TrixMac/Generated/trix_core.swift`
- `Sources/trix_coreFFI/trix_coreFFI.h`
- `Sources/trix_coreFFI/module.modulemap`

To regenerate them, follow [../../docs/ffi-bindings.md](../../docs/ffi-bindings.md).

## Remaining Gaps

- group rename still needs a server/API contract; member/device admin is already wired
- non-image attachment preview/open flows still rely on Quick Look or open-in-place behavior and need more polish
- APNs delivery still depends on `trixd` being configured with valid `TRIX_APNS_*` credentials and matching app entitlements
- the beta build script packages/signs/notarizes, but distribution and update hosting stay manual
