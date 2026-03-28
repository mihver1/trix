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

Archive, export, validate, and upload for TestFlight from the terminal:

```bash
cd apps/ios

# Use a monotonically increasing build number for every upload.
export TRIX_IOS_BUILD_NUMBER=42

# Archive + export only.
./scripts/build-testflight.sh

# Validate with an Apple ID and app-specific password.
export TRIX_APPLE_ID="you@example.com"
export TRIX_APP_SPECIFIC_PASSWORD="app-specific-password"
./scripts/build-testflight.sh --validate

# Upload an archive with the same xcodebuild/App Store Connect key flow as macOS.
export TRIX_ASC_AUTH_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABC123XYZ.p8"
export TRIX_ASC_AUTH_KEY_ID="ABC123XYZ"
export TRIX_ASC_AUTH_ISSUER_ID="00000000-0000-0000-0000-000000000000"
./scripts/build-testflight.sh --upload

# Or, if Xcode is already signed in on this Mac, upload without adding any
# private credentials to the repo or shell history.
./scripts/build-testflight.sh --upload

# If you already have an IPA, the script falls back to altool upload.
export TRIX_APPLE_ID="you@example.com"
export TRIX_APP_SPECIFIC_PASSWORD="app-specific-password"
./scripts/build-testflight.sh --ipa build/testflight/export/Trix.ipa --upload
```

The TestFlight driver writes release artifacts under `build/testflight/`:

- `TrixiOS.xcarchive`
- exported `.ipa` under `build/testflight/export/`
- archive result bundle at `build/testflight/TrixiOS-archive.xcresult`
- `archive.log`, `export.log`, `validate.log`, and `upload.log`

The script also:

- regenerates the `UniFFI` bridge and the Xcode project before archiving unless `--skip-bridge` or `--skip-xcodegen` is passed
- runs `ios-unit` prechecks by default unless `--skip-prechecks` is passed
- uses `-allowProvisioningUpdates` by default unless `TRIX_IOS_ALLOW_PROVISIONING_UPDATES=0`
- supports `TRIX_TESTFLIGHT_INTERNAL_ONLY=1` to mark the upload for internal TestFlight testing only
- can re-validate or upload an existing `.ipa` with `--ipa path/to/Trix.ipa`

With a fresh archive, `--upload` uses the same `xcodebuild -exportArchive` upload path as `apps/macos/scripts/archive-testflight.sh`. If Xcode is signed in locally, you can use that account state directly without checking any private credentials into git.

If you prefer explicit App Store Connect API key auth, set `TRIX_ASC_AUTH_KEY_PATH` / `TRIX_ASC_AUTH_KEY_ID` / `TRIX_ASC_AUTH_ISSUER_ID`.

If you rely on directory-based key discovery, inline auth strings, Apple ID/app-specific-password auth, or an existing `.ipa`, the script falls back to `altool`.

If you pass `--ipa`, upload falls back to `altool`, because `xcodebuild` uploads archives rather than `.ipa` files.

If you want both validation and the mac-style upload path, run:

```bash
./scripts/build-testflight.sh --validate --upload
```

That combination exports once for validation and then runs a second `xcodebuild -exportArchive` pass for the actual upload.

If your team uses manual signing or a different export method, point `TRIX_IOS_EXPORT_OPTIONS_PLIST` at another plist before running the script.

To avoid putting the app-specific password in shell history, store it in the keychain once and reuse the keychain item for both validate and upload:

```bash
xcrun altool \
  --store-password-in-keychain-item TRIX_APPSTORE_PASSWORD \
  -u "$TRIX_APPLE_ID" \
  -p "$TRIX_APP_SPECIFIC_PASSWORD"

TRIX_ALTOOL_KEYCHAIN_ITEM=TRIX_APPSTORE_PASSWORD \
./scripts/build-testflight.sh --validate

TRIX_ALTOOL_KEYCHAIN_ITEM=TRIX_APPSTORE_PASSWORD \
./scripts/build-testflight.sh --ipa build/testflight/export/Trix.ipa --upload
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
