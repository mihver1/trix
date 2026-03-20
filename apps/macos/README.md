# Trix macOS Client

`apps/macos` now contains the first runnable macOS client slice as a `SwiftPM` app target.

## Current Scope

- `SwiftUI` macOS app entrypoint
- server handshake via `/v0/system/health` and `/v0/system/version`
- first-device account bootstrap against `/v0/accounts`
- challenge/session sign-in using `trix-core` UniFFI key material and transport client
- local session persistence in `Application Support`
- secret material persisted in `Keychain`
- persistent local history store and sync cursor state under `Application Support/TrixMac/workspaces/<account-id>/`
- post-auth snapshot for `/v0/accounts/me`, `/v0/devices`, `/v0/chats`, inbox, key packages, and history sync jobs

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

`TrixMac` links against `../../target/debug/libtrix_core.a`, so rebuild `trix-core` when Rust FFI changes. Keep the Rust build on `MACOSX_DEPLOYMENT_TARGET=14.0` to match the app target and avoid linker version warnings.

## Bindings

Swift bindings are checked into `apps/macos`:

- `Sources/TrixMac/Generated/trix_core.swift`
- `Sources/trix_coreFFI/trix_coreFFI.h`
- `Sources/trix_coreFFI/module.modulemap`

To regenerate them, follow [docs/ffi-bindings.md](/Users/m.verhovyh/.codex/worktrees/e1d0/trix/docs/ffi-bindings.md).

## Next Steps

- move persistent MLS facade and conversation restore behind `trix-core`
- project encrypted local history into typed timeline items through the new projected-message APIs
- add real transfer-bundle handling during device approval
- replace manual operational panels with user-facing chat and sync UX
- add a release build path for shipping `trix-core` artifacts outside local debug workflows
