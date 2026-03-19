# Trix macOS Client

`apps/macos` now contains the first runnable macOS client slice as a `SwiftPM` app target.

## Current Scope

- `SwiftUI` macOS app entrypoint
- server handshake via `/v0/system/health` and `/v0/system/version`
- first-device account bootstrap against `/v0/accounts`
- challenge/session sign-in using locally generated Ed25519 keys
- local session persistence in `Application Support`
- secret material persisted in `Keychain`
- post-auth snapshot for `/v0/accounts/me`, `/v0/devices`, and `/v0/chats`

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
swift build
swift run TrixMac
```

You can also open `Package.swift` in `Xcode` and run the `TrixMac` target as a regular macOS app.

## Next Steps

- move bootstrap/auth and storage logic behind `trix-core` + `UniFFI`
- replace metadata-only chat view with real message sync/decrypt flow
- add device linking, approval, and revocation UI
- move access token refresh/session policies into a dedicated bridge layer
