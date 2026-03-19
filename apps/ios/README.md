# iOS App Scaffold

This directory contains the current `iOS` client baseline for `Trix`.

The current slice covers:

- native `SwiftUI` app target generated from `XcodeGen`
- configurable backend URL stored in `UserDefaults`
- local device identity persisted in `Keychain`
- account bootstrap against `/v0/accounts`
- device auth challenge/session flow via `/v0/auth/challenge` and `/v0/auth/session`
- authenticated reads from `/v0/accounts/me` and `/v0/devices`
- link-intent creation against `/v0/devices/link-intents`
- link-intent completion against `/v0/devices/link-intents/{link_intent_id}/complete`
- pending-device waiting state for newly linked devices until approval
- device revoke flow against `/v0/devices/{device_id}/revoke`
- history sync job visibility and completion against `/v0/history-sync/jobs`
- working integration with `/v0/system/health` and `/v0/system/version`
- source layout that leaves room for a future `UniFFI` bridge to `trix-core`

## Layout

```text
apps/ios/
  project.yml
  TrixiOS/
    App/
    Bridge/
    Features/
    Networking/
    Security/
    Resources/
```

## Commands

Generate the project:

```bash
cd apps/ios
xcodegen generate
```

Build for the simulator:

```bash
xcodebuild \
  -project TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Notes

- `App Transport Security` is relaxed for this PoC so the client can talk to a local `http://` backend. Tighten this before shipping.
- The app currently defaults to `http://127.0.0.1:8080`, which works for the simulator when the server runs on the same Mac.
- `xcodebuild` requires an installed `iOS Simulator` runtime or device platform in the local `Xcode` setup.
- Linked devices currently store only transport key material locally. They can authenticate once approved, but account-management actions that require the shared account-root key remain disabled on-device.
- The current server API requires `account_root_signature_b64` for `/v0/devices/{device_id}/approve`, but the public pending-device routes do not yet expose the bootstrap payload needed to build that signature on another client.

## Next App Tasks

- add device approval once the pending-device bootstrap material is exposed by the API
- introduce a Swift bridge layer for generated `trix-core` bindings
- move shared request/response models to a generated or shared contract source
