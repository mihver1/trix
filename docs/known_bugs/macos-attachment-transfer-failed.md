# macOS: Attachment Transfer Failed

## Summary

On macOS, sending or downloading a file attachment fails with
"Attachment transfer failed". This blocks media/file workflows on the desktop
client even though the SDK-backed attachment path exists.

## Status

Code fix implemented on May 6, 2026. A signed macOS debug app now passes the
live SDK attachment round trip with safe credentials for a generated text file
and a generated PNG image. Keep manual picker/open/share/export release
revalidation open until the flow is repeated through the actual macOS UI.

## User-visible symptom

- User attempts to attach a file in a Matrix room on macOS.
- The UI reports "Attachment transfer failed".
- The attachment is not sent or cannot be downloaded/opened.

## Expected behavior

- macOS should allow the user to choose a file through a sandbox-compatible file
  picker.
- The app should read the selected file with appropriate sandbox permissions.
- `MatrixRoomService.sendAttachment(...)` should send the file through Matrix
  SDK timeline APIs.
- Download should fetch bytes through Matrix SDK media APIs and then expose
  open/share/export behavior where available.

## Investigation notes

- Start in `MatrixTimelineView.swift` for file picker and selected URL handling.
- Check macOS sandbox entitlements and file access. The current macOS Matrix
  target has user-selected read-only entitlement; confirm the file picker grants
  scoped access for the selected URL.
- Check whether security-scoped resource access is required around file reads.
- Check `TimelineViewModel.sendAttachment(...)` and
  `MatrixRustSDKAdapter.sendAttachment(...)` for platform-specific errors.
- Inspect the surfaced error without logging file contents, access tokens, or
  decrypted event bodies.

## Fix notes

- `MatrixTimelineView` reads selected macOS files while holding the
  security-scoped grant and coordinates the read through `NSFileCoordinator`.
- `MatrixRustSDKAdapter` stages macOS uploads into app-owned cache storage and
  passes `UploadSource.file(...)` to the Matrix SDK instead of depending on a
  user-selected URL after the picker grant ends.
- Image uploads now include the Matrix Rust SDK FFI-required image metadata:
  dimensions, byte size, MIME type, and a valid 1x1 blurhash.
- macOS downloads now use Matrix SDK `getMediaFile(...)` with an app-owned temp
  directory before the UI previews, opens, shares, or exports the bytes.
- iOS keeps the existing in-memory upload/download behavior.

## Implementation requirements

- Keep file selection in SwiftUI/AppKit-facing code and transfer logic in
  service/view-model layers.
- Do not read arbitrary filesystem paths outside user-selected file grants.
- Do not disable sandboxing to make transfer work.
- Do not log selected file contents or decrypted attachment bytes.
- Preserve iOS attachment behavior while fixing macOS.

## Verification plan

- Run `just matrix-macos-run`.
- Send a small text file from macOS to an encrypted DM.
- Send a small image file from macOS to an encrypted DM.
- Confirm the other account receives both attachment events.
- Download/open the same attachments from macOS.
- Repeat with a file outside the project directory, selected through the picker.
- Run macOS build and `git diff --check`.

## Verification performed

- `cd apple && xcodegen generate`
- `cd apple && xcodebuild -project TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO`
- `cd apple && xcodebuild -project TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- `just matrix-macos-build automatic`
- `codesign -d --entitlements :- /tmp/trixmatrix-macos-dd/Build/Products/Debug/Trix.app`
  confirmed app sandbox, network client, and user-selected read-only file
  access entitlements on the signed debug app.
- Signed macOS live smoke with `TRIX_MATRIX_LIVE_SMOKE_MODE=login` passed.
- Signed macOS live smoke with `TRIX_MATRIX_LIVE_SMOKE_MODE=encrypted-attachment`
  passed: generated text file send/receive/download matched 65 bytes, and
  generated PNG image send/receive/download matched 177 bytes.

## Acceptance criteria

- macOS attachment send no longer fails with "Attachment transfer failed" for
  Matrix SDK file and image attachment round trips.
- Download flow works for received file and image attachments.
- Manual picker/open/share/export validation remains before release.
- The fix keeps sandboxing and Matrix SDK media APIs intact.
