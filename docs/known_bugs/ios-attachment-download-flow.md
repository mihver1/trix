# iOS: Attachment Rows Skip Explicit Download/Open Flow

Status: Needs reproduction check.

## Summary

iOS attachment rows should preserve the explicit product flow from legacy Trix:
show attachment metadata, download when needed, then preview/open/share through
OS controls. Rows must not silently fail or skip the user-visible download/open
state.

## Expected behavior

- Received attachment row shows filename/type/size when available.
- If bytes are not local, the row offers a download action.
- After download, image attachments can preview in app.
- User can open or share downloaded files through OS controls.
- Errors are specific enough to debug media failures.

## Legacy reference

- Legacy iOS has attachment import, download/open, and inline preview behavior
  in `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`.
- Legacy inline preview support lives in
  `apps/ios/TrixiOS/Features/Chats/ConsumerInlineAttachmentPreview.swift`.

## Current Matrix state

- `MatrixRoomService.downloadAttachment(...)` exists.
- `MatrixTimelineView` has attachment row, preview, share/export paths.
- This item should be treated as a regression guard and checked against current
  Matrix UI before changing code.

## Implementation requirements

- Keep media transfer in `TimelineViewModel` and `MatrixRustSDKAdapter`.
- Keep SwiftUI rows responsible only for user actions and display state.
- Do not log attachment bytes or decrypted media.

## Acceptance criteria

- A received file attachment requires an explicit download before open/share.
- A received image attachment can be downloaded and previewed.
- Downloaded attachment state survives normal view updates.
- Failure states show actionable errors.

## Verification plan

- Build iOS Matrix target.
- Live-test generated text file and PNG image attachments in encrypted DM.
- Repeat after app restart.
- `git diff --check`
