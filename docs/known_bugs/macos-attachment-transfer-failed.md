# macOS: Attachment Transfer Failed

## Summary

On macOS, sending or downloading a file attachment fails with
"Attachment transfer failed". This blocks media/file workflows on the desktop
client even though the SDK-backed attachment path exists.

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

## Acceptance criteria

- macOS attachment send no longer fails with "Attachment transfer failed" for
  user-selected files.
- Download/open flow works for received file and image attachments.
- The fix keeps sandboxing and Matrix SDK media APIs intact.
