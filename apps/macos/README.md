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
- trusted-device approval can include an encrypted transfer bundle so a newly linked Mac can import shared account-root material on reconnect
- background inbox sync via polling fallback plus APNs wake-up pushes for local notifications
- local session persistence in `Application Support`
- secret material persisted in `Keychain`
- persistent local history store and sync cursor state under `Application Support/com.softgrid.trixapp/workspaces/<account-id>/`
- stale restore paths now preserve reconnect vs relink-required recovery states instead of silently dropping back into a blank bootstrap form
- advanced operational tooling under `Settings > Advanced`
- repo-level shared `strings.yaml` catalog for chat/user-facing copy, generated into `Sources/TrixMac/Generated/TrixStrings.generated.swift`

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

Upload directly instead of producing a local export payload:

```bash
TRIX_ASC_DESTINATION=upload ./scripts/archive-testflight.sh
```

Use explicit App Store Connect API key auth when the local Xcode account state is not enough:

```bash
export TRIX_ASC_AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123XYZ.p8"
export TRIX_ASC_AUTH_KEY_ID="ABC123XYZ"
export TRIX_ASC_AUTH_ISSUER_ID="00000000-0000-0000-0000-000000000000"
TRIX_ASC_DESTINATION=upload ./scripts/archive-testflight.sh
```

Useful overrides:

```bash
TRIX_MACOS_BUILD_NUMBER=42 \
TRIX_TESTFLIGHT_INTERNAL_ONLY=1 \
TRIX_ASC_DESTINATION=upload \
./scripts/archive-testflight.sh
```

That script now:

- regenerates the shared Swift string file, checked-in Swift bridge, and fresh universal `trix-core` archive before `xcodebuild archive`
- keeps automatic signing in place instead of forcing a manual distribution identity or provisioning profile
- validates locally exported `.app` or `.pkg` payloads by checking that the embedded provisioning profile is a Store profile and that `com.apple.developer.aps-environment=production`
- skips the local validation step only when `TRIX_ASC_DESTINATION=upload` produces no local distributable to inspect

Regression coverage for the archive driver lives in:

```bash
./scripts/test-archive-testflight.sh
```

## Shared Strings

- shared user-facing chat copy lives in the root [`strings.yaml`](../../strings.yaml) catalog
- refresh generated outputs manually with `make strings-generate`
- the macOS Xcode target prebuild also regenerates [`Sources/TrixMac/Generated/TrixStrings.generated.swift`](./Sources/TrixMac/Generated/TrixStrings.generated.swift) before the bridge/universal-library steps
- do not hand-edit the generated Swift file; edit `strings.yaml` instead

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
