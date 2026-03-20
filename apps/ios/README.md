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
- pending-device waiting state plus trusted-device approval via `/v0/devices/{device_id}/approve-payload` and `/v0/devices/{device_id}/approve`
- device revoke flow against `/v0/devices/{device_id}/revoke`
- history sync job visibility and completion against `/v0/history-sync/jobs`
- debug key package publication against `/v0/key-packages:publish`
- chat list, detail, history, and inbox flows against `/v0/chats`, `/v0/chats/{chat_id}/history`, `/v0/inbox`, and `/v0/inbox/lease`
- PoC chat creation plus member/device add-remove flows using reserved key packages
- working integration with `/v0/system/health` and `/v0/system/version`
- working `UniFFI` bridge generation for `trix-core`
- `trix-core`-backed account bootstrap, link-intent completion, auth challenge/session, device approval, and revoke flows via generated Swift bindings

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
./scripts/generate-trix-core-bridge.sh
xcodegen generate
```

Build for the simulator:

```bash
./scripts/generate-trix-core-bridge.sh
xcodebuild \
  -project TrixiOS.xcodeproj \
  -scheme TrixiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Notes

- `App Transport Security` is relaxed for this PoC so the client can talk to a local `http://` backend. Tighten this before shipping.
- The app currently defaults to `http://127.0.0.1:8080`, which works for the simulator when the server runs on the same Mac.
- `xcodebuild` requires an installed `iOS Simulator` runtime or device platform in the local `Xcode` setup.
- `./scripts/generate-trix-core-bridge.sh` installs missing Rust iOS targets automatically, regenerates `UniFFI` Swift sources under `TrixiOS/Bridge/Generated`, and rebuilds the local `xcframework` under `Vendor/TrixCoreFFI.xcframework`.
- Linked devices currently store only transport key material locally. They can authenticate once approved, but account-management actions that require the shared account-root key remain disabled on-device.
- Device approval now accepts an optional `transfer_bundle_b64`, and the server exposes `GET /v0/devices/{device_id}/transfer-bundle`. The current iOS bridge still sends `nil` there until transfer-bundle generation/decryption is wired through `trix-core`.
- Inbox leasing is exposed as a debug worker-style tool in the iOS PoC. The normal UI still relies on regular polling and explicit `ack`.
- The messaging screens still use placeholder debug payloads for `Commit`, `Welcome`, message ciphertexts, and key packages. Account/device/auth flows are now on the `trix-core` bridge; MLS conversation state still needs a persistent bridge model before those placeholders can be removed safely.

## Next App Tasks

- replace debug chat payload generation with real MLS state transitions
- decide how to persist `FfiMlsFacade` / MLS signer state across app restarts before moving key packages and chats off placeholders
- decide whether iOS should adopt leased inbox delivery by default or keep it as a worker/debug path
- move shared request/response models to a generated or shared contract source
