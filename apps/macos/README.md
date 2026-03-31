# Trix macOS Client

`apps/macos` now contains the closed-beta macOS client slice as a `SwiftPM` app target backed by `trix-core` UniFFI.

## Current Scope

- `SwiftUI` macOS app entrypoint
- first-device onboarding and linked-device restore
- challenge/session sign-in using `trix-core` UniFFI key material and transport client
- directory-backed DM/group creation
- local FFI chat list, timeline and read-state
- text and attachment messaging with optimistic local send rows
- profile editing, device approval/revoke and notification settings
- background inbox sync via polling fallback plus APNs wake-up pushes for local notifications
- local session persistence in `Application Support`
- secret material persisted in `Keychain`
- persistent local history store and sync cursor state under `Application Support/com.softgrid.trixapp/workspaces/<account-id>/`
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
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build -p trix-core --lib
cd apps/macos
swift build
swift run TrixMac
```

You can also open `Package.swift` in `Xcode` and run the `TrixMac` target as a regular macOS app.

By default `TrixMac` links against `../../target/debug/libtrix_core.a`. Override that with `TRIX_CORE_ARTIFACTS_PATH=/abs/path/to/target/release` when you want a release Rust artifact instead.

Keep the Rust build on `MACOSX_DEPLOYMENT_TARGET=14.0` to match the app target and avoid linker version warnings.

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

## Bindings

Swift bindings are checked into `apps/macos`:

- `Sources/TrixMac/Generated/trix_core.swift`
- `Sources/trix_coreFFI/trix_coreFFI.h`
- `Sources/trix_coreFFI/module.modulemap`

To regenerate them, follow [docs/ffi-bindings.md](/Users/m.verhovyh/.codex/worktrees/e1d0/trix/docs/ffi-bindings.md).

## Remaining Gaps

- group rename still needs a server/API contract; member/device admin is already wired
- attachment preview/open flows are basic and still need more polish
- APNs delivery still depends on `trixd` being configured with valid `TRIX_APNS_*` credentials and matching app entitlements
- the beta build script packages/signs/notarizes, but distribution and update hosting stay manual
