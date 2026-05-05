# Trix Matrix Apple Client

This is the first Apple client scaffold for the Matrix pivot. It is a native
SwiftUI project with iOS and macOS targets.

The app now builds against a pinned `matrix-rust-components-swift` release and
uses a small adapter boundary around the SDK. A mock service remains available
for local UI development through dependency injection.

## Targets

- `TrixMatrixiOS`: iOS SwiftUI app.
- `TrixMatrixMac`: macOS SwiftUI app.

Generate the Xcode project:

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

## Current Behavior

- Hardcoded homeserver URL: `https://trix.selfhost.ru`.
- Login form accepts Matrix user ID and password.
- Matrix Rust SDK password login is wired through `MatrixRustSDKAdapter`.
- Session restore runs on app launch.
- Matrix SDK session data is stored under Application Support/Caches with the
  opaque SDK store ID persisted in Keychain alongside the SDK session.
- Matrix SDK clients are built with automatic cross-signing bootstrap enabled
  so password logins can create the SDK user identity required by session
  verification; this does not silently trust devices.
- Room list and room timeline are shown through view models backed by Matrix
  SDK sync/timeline APIs.
- The room list has a production SwiftUI flow for creating encrypted DMs.
- Pending Matrix invites are listed separately and can be accepted or declined.
- Plain text send goes through the Matrix SDK timeline send API.
- Encrypted rooms are handled by Matrix SDK E2EE; no custom crypto is
  implemented here.
- Device verification state is read from the Matrix SDK and surfaced in the
  account UI; the app does not silently trust devices or auto-approve
  verification.
- Device verification actions are wired through the Matrix SDK session
  verification controller: request, accept, start SAS, compare, approve,
  decline, and cancel.
- The UI starts SAS from the requesting device after the existing device
  accepts the request, matching the live SDK behavior observed on Conduit.
- DEBUG builds include a live smoke runner, enabled only with
  `TRIX_MATRIX_LIVE_SMOKE=1`, for validating login, restore, encrypted DM
  creation, encrypted send/receive, device verification flow, and cleanup
  against the live homeserver.
- Device verification, key backup/recovery, push, media, and group room
  creation are visible as TODO items.

## Service Boundary

The SwiftUI views depend on view models, not SDK calls.

- `MatrixSessionStore`: secure session persistence.
- `MatrixAuthService`: login/logout/session restore.
- `MatrixSyncService`: room list.
- `MatrixRoomService`: room timeline and text send.
- `MatrixRoomBootstrapService`: encrypted DM creation, invite list, invite
  accept/decline, and live validation join helpers.
- `MatrixDeviceVerificationService`: read-only verification state plus
  explicit Matrix SDK session verification actions.
- `RoomListViewModel`: room list state.
- `TimelineViewModel`: timeline state.
- `DeviceVerificationViewModel`: device verification state and action state.
- `MatrixAppModel`: app-level orchestration.

## Matrix Rust SDK Integration

The dependency is pinned in `project.yml`:

```swift
.package(
    url: "https://github.com/matrix-org/matrix-rust-components-swift",
    exact: "26.04.01"
)
```

The remaining production tasks are:

1. Decide whether a dev-only homeserver URL override is allowed for local
   testing before DNS/TLS is live.
2. Finish production gating for device verification state after SAS completes.
3. Add key backup/recovery state and UX.
4. Keep tokens and decrypted message bodies out of logs.
5. Add production group room creation and group invite UX.
6. Add persistent tests around encrypted room sync, invite handling, device
   verification state, and logout cleanup.

Do not add custom cryptography while implementing the adapter.

## Live Smoke

The live smoke runner is intended for development only. It reads credentials
from environment variables, stores the admin session in a dedicated Keychain
service, and prints only `TRIX_LIVE_SMOKE ...` status lines. Do not paste
passwords, access tokens, or decrypted message bodies into logs.

As of May 5, 2026, the live iOS device verification smoke against
`https://trix.selfhost.ru` reaches request, accept, SAS start, matching
challenge, and finish. The Matrix SDK did not report `verificationState ==
verified` within the smoke timeout, so the app still treats SDK verified-state
as the production gate rather than replacing it with a local flag.

Modes:

- `TRIX_MATRIX_LIVE_SMOKE_MODE=login`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=restore`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=encrypted-dm`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=cleanup`

Use a signed simulator build for this path. `CODE_SIGNING_ALLOWED=NO` is fine
as a compile check, but the unsigned simulator app can fail Keychain operations.

## Known Build Note

With Xcode 26.3 and MatrixRustSDK 26.04.01, the macOS simulator/local build
links successfully but emits warnings that some prebuilt `libmatrix_sdk_ffi.a`
objects were built for macOS 26.2 while the app deployment target is macOS 14.0.
Resolve that before treating the macOS target as release-ready.
