# iOS: Attachment Rows Skip The Explicit Download/Open Flow

## Summary

On iOS, attachment rows appear to hand the file to the user immediately instead
of first offering an explicit media/file download action. The expected UX is a
clear transfer flow: attachment event is visible, the user chooses to download,
progress/state is understandable, and only after download does the app offer
preview/open/share/export.

## User-visible symptom

- User opens a room with a file or media attachment.
- The row behaves as if the local file is already available.
- The UI does not clearly offer "download media/file" before opening/sharing.

## Expected behavior

- Remote attachment event should render as an attachment row with metadata such
  as filename/type/size when available.
- If bytes are not local, the primary action should be download.
- After download succeeds, the row may offer preview, open, share, or export.
- Download errors must be shown in UI without printing decrypted body, access
  token, filename payload contents, or credentials.

## Investigation notes

- Start in `apple/Sources/Shared/ViewModels/TimelineViewModel.swift` and
  `apple/Sources/Shared/Views/MatrixTimelineView.swift`.
- Check how `downloadedAttachment` state is scoped. A single global downloaded
  attachment can make multiple rows look locally available.
- Check `MatrixTimelineItem` / attachment model fields in
  `apple/Sources/Shared/Models/MatrixModels.swift`.
- Check whether file existence is inferred from event metadata instead of actual
  downloaded bytes.
- Keep actual media fetching in `MatrixRoomService.downloadAttachment(...)` and
  `MatrixRustSDKAdapter`, not directly in SwiftUI.

## Implementation requirements

- Model remote-vs-downloaded attachment state per event/attachment, not as an
  accidental global row state.
- The row should not open/share until `downloadAttachment(...)` has succeeded.
- Preserve image preview behavior after download.
- Keep OS open/share/export actions behind downloaded local file state.
- Do not log decrypted attachment data, filenames if considered sensitive,
  access tokens, or media URLs with credentials.

## Verification plan

- Send an encrypted attachment from another account.
- Open the room on iOS before downloading.
- Confirm the row offers download rather than immediate file open/share.
- Tap download and confirm success state.
- Confirm image preview works for images and OS open/share/export works after
  download.
- Repeat with a non-image file.
- Confirm a failed download shows an actionable error state.

## Acceptance criteria

- iOS attachment rows clearly distinguish remote attachment events from local
  downloaded files.
- Download is explicit and per attachment.
- Open/share/export is unavailable until bytes are downloaded.
