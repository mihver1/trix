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
- The room list has a production SwiftUI flow for creating encrypted DMs and
  private encrypted group rooms with two or more invitees.
- Pending Matrix invites are listed separately and can be accepted or declined.
- Plain text send goes through the Matrix SDK timeline send API.
- File and image attachments can be picked from the timeline composer and sent
  through Matrix SDK timeline attachment APIs. Timeline file/image events can be
  downloaded through Matrix SDK media APIs, with image preview plus OS
  open/share/export actions shown in app.
- While the app scene is active, a foreground refresh loop periodically reloads
  rooms, pending invites, and the selected timeline through the Matrix service
  boundary.
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
- When the Matrix SDK reports no eligible device for interactive SAS, the UI
  shows an explicit blocked state and exposes Matrix SDK recovery actions
  instead: set up recovery through `enableRecovery` when recovery is disabled,
  or confirm an existing recovery key through `recoverAndFixBackup` when
  recovery is enabled or incomplete.
- Generated recovery keys are shown only in the UI for the user to save; the
  app does not log recovery keys, recovery confirmations, SAS values, access
  tokens, or decrypted message bodies.
- DEBUG builds include a live smoke runner, enabled only with
  `TRIX_MATRIX_LIVE_SMOKE=1`, for validating login, restore, encrypted DM
  creation, encrypted send/receive, device verification flow, and cleanup
  against the live homeserver.
- Device verification production validation, group-message live validation,
  attachment live validation/open-share polish, APNs notifications, and
  TestFlight packaging are visible as TODO items.

## Service Boundary

The SwiftUI views depend on view models, not SDK calls.

- `MatrixSessionStore`: secure session persistence.
- `MatrixAuthService`: login/logout/session restore.
- `MatrixSyncService`: room list.
- `MatrixRoomService`: room timeline, text send, attachment send, and
  attachment download.
- `MatrixRoomBootstrapService`: encrypted DM creation, invite list, invite
  accept/decline, and live validation join helpers.
- `MatrixDeviceVerificationService`: read-only verification/recovery state,
  explicit Matrix SDK session verification actions, and Matrix SDK recovery
  setup/confirmation actions.
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
3. Add persistent tests around recovery/key backup state.
4. Keep tokens and decrypted message bodies out of logs.
5. Live-validate encrypted group room messaging and invite acceptance.
6. Live-validate encrypted attachment round trips and add OS share/export.
7. Add APNs notifications through a Matrix push gateway.
8. Add persistent tests around encrypted room sync, invite handling, device
   verification/recovery state, and logout cleanup.

Do not add custom cryptography while implementing the adapter.

## Live Smoke

The live smoke runner is intended for development only. It reads credentials
from environment variables, stores the admin session in a dedicated Keychain
service, and prints only `TRIX_LIVE_SMOKE ...` status lines. Do not paste
passwords, access tokens, or decrypted message bodies into logs.

As of May 5, 2026, an earlier live iOS device verification smoke against
`https://trix.selfhost.ru` reached request, accept, SAS start, matching
challenge, and `SessionVerificationController` `didFinish`, but the Matrix SDK
did not report `verificationState == verified` within the smoke timeout. A
later signed-simulator rerun after the recovery UI slice reported
`verificationState=unverified`, `hasDevicesToVerifyAgainst=false`,
`isLastDevice=false`, `backupState=unknown`, `backupExistsOnServer=false`,
`recoveryState=disabled`, and an own user identity present with
`hasMasterKey=true`. Element X gates interactive device verification on
`hasDevicesToVerifyAgainst`; Trix now does the same in both the UI and SDK
adapter. When live diagnostics report no eligible device, the smoke exits after
confirming that blocked state instead of forcing an interactive SAS flow.
Recovery/key backup remains an explicit live-validation path, but the
production UI now surfaces the safe SDK-backed recovery setup/confirmation path
for that blocked state.

Modes:

- `TRIX_MATRIX_LIVE_SMOKE_MODE=login`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=restore`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=encrypted-dm`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=encrypted-attachment`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=device-verification`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=recovery`
- `TRIX_MATRIX_LIVE_SMOKE_MODE=cleanup`

Use a signed simulator build for this path. `CODE_SIGNING_ALLOWED=NO` is fine
as a compile check, but the unsigned simulator app can fail Keychain operations.
The encrypted attachment mode creates an encrypted DM, sends a generated
attachment through the Matrix SDK timeline API, waits for the test account to
see the file event, downloads it through the SDK media API, and compares bytes
without printing filenames, payloads, passwords, access tokens, registration
tokens, SAS values, recovery keys, or decrypted message bodies.
The device verification mode prints non-secret diagnostics for SDK
`verificationState`, eligible-device flags, backup/recovery state, and own-user
identity state.

The recovery mode is DEBUG-only and intentionally mutates recovery/key backup
state. It refuses to run unless all of these are set through the environment:

- `TRIX_MATRIX_LIVE_SMOKE_RECOVERY_USER_ID`
- `TRIX_MATRIX_LIVE_SMOKE_RECOVERY_PASSWORD`
- `TRIX_MATRIX_LIVE_SMOKE_ALLOW_RECOVERY_MUTATION=1`

It also refuses `@admin:trix.selfhost.ru` and any account matching
`TRIX_MATRIX_LIVE_SMOKE_ADMIN_USER_ID`. When allowed, it logs in with the
dedicated recovery account, requires initial SDK `recoveryState=disabled`, calls
`enableRecovery`, keeps the generated recovery key only in process memory, logs
only non-secret recovery/backup snapshots, logs in a second session, calls
`recoverAndFixBackup` with the in-memory key, and reports the final
recovery/backup snapshot. It must not print recovery keys, passwords, access
tokens, SAS values, registration tokens, or decrypted message bodies.

On May 6, 2026, the recovery live smoke created and consumed
`@recovery-smoke-20260506092649-7c56b1:trix.selfhost.ru` for validation. Recovery
setup smoke accounts are one-shot because a successful run leaves SDK recovery
enabled. A fresh next-run account,
`@recovery-smoke-20260506093024-d2736f:trix.selfhost.ru`, is stored as the active
recovery smoke account in the local Keychain under
`com.softgrid.trixmatrix.live-smoke` / `recovery-user-id`; its password is stored
under `com.softgrid.trixmatrix.live-smoke.recovery-password`.

The signed iOS simulator recovery smoke succeeded with only non-secret
`TRIX_LIVE_SMOKE` lines. The setup session started with `recoveryState=disabled`,
called `enableRecovery`, and reached `verificationState=verified`,
`backupState=enabled`, `backupExistsOnServer=true`, and `recoveryState=enabled`.
The confirmation session started with `recoveryState=incomplete` and
`backupExistsOnServer=true`, called `recoverAndFixBackup` with the in-memory key,
and finished with `verificationState=verified`, `backupState=enabled`,
`backupExistsOnServer=true`, and `recoveryState=enabled`.

## Known Build Note

With Xcode 26.3 and MatrixRustSDK 26.04.01, the macOS simulator/local build
links successfully but emits warnings that some prebuilt `libmatrix_sdk_ffi.a`
objects were built for macOS 26.2 while the app deployment target is macOS 14.0.
Resolve that before treating the macOS target as release-ready.
