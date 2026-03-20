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
- real MLS key package publication through the persistent `trix-core` bridge against `/v0/key-packages:publish`
- chat list, detail, history, and inbox flows against `/v0/chats`, `/v0/chats/{chat_id}/history`, `/v0/inbox`, and `/v0/inbox/lease`
- PoC chat creation plus member/device add-remove flows using reserved key packages
- working integration with `/v0/system/health` and `/v0/system/version`
- working `UniFFI` bridge generation for `trix-core`
- `trix-core`-backed account bootstrap, link-intent completion, auth challenge/session, device approval, and revoke flows via generated Swift bindings
- persistent `trix-core` local state under app storage for MLS signer state, local chat history, and inbox sync cursors
- manual local history sync and inbox leasing into the `trix-core` store from the Messaging PoC screen
- typed debug message-body compose and preview through `trix-core` FFI serialization/parsing for text, reaction, receipt, and chat-event payloads

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
- The app now stores `trix-core` state under `Application Support/TrixiOS/CoreState/<account_id>/<device_id>/`, including `mls/`, `history-store.sqlite`, and `sync-state.sqlite`.
- Existing installs that still point at legacy `history-store.json` / `sync-state.json` paths are migrated in place by `trix-core` on first load.
- Inbox leasing is exposed both as a raw debug worker-style path and as a `trix-core` local-store sync path in the iOS PoC.
- The messaging screens now serialize debug application payloads through the typed `trix-core` message-body helpers, but `Commit`, `Welcome`, and real MLS ciphertext generation still remain placeholders until the full conversation bridge lands.
- `main` now exposes projected local timeline APIs in `trix-core`; the iOS app already regenerates those bindings, but it still needs persistent conversation/group state before it can project encrypted application and commit messages locally.

## Next App Tasks

- replace debug chat payload generation with real MLS state transitions
- move create-chat, member changes, and message send flows onto persistent `FfiMlsFacade` group state
- wire `FfiLocalHistoryStore.project_chat_messages()` into chat screens once iOS persists/load MLS conversations per chat
- decide whether iOS should adopt leased inbox delivery by default or keep it as a worker/debug path
- move shared request/response models to a generated or shared contract source
