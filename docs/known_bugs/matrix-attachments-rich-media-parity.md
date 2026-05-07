# Matrix: Rich Attachment And Media Parity

Status: Open.

## Summary

Matrix Apple can send, download, preview, open, share, and export basic file and
image attachments. Legacy clients still have richer media behavior, including
iOS photo/video picker flows, inline previews, GIF/video considerations, and
deeper attachment caching.

## Legacy behavior to match

- iOS supports file import and photo/video picker from the chat composer.
- iOS and macOS show inline attachment previews and open/download controls.
- Legacy has attachment caches and a custom blob path. The Matrix app must use
  Matrix SDK media APIs instead of the legacy blob service.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
- `apps/ios/TrixiOS/Features/Chats/ConsumerInlineAttachmentPreview.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `crates/trix-core/src/attachments.rs`
- `crates/trix-server/src/routes/blobs.rs`

## Current Matrix state

- Matrix media send/download exists through `MatrixRoomService`.
- `MatrixTimelineAttachment` tracks file/image metadata.
- macOS attachment transfer has live SDK round-trip coverage, but manual
  picker/open/share/export release revalidation remains open.

## Required implementation

- Add iOS photo/video picker support if it is missing from the Matrix timeline
  composer.
- Preserve existing file importer behavior on both platforms.
- Improve inline preview behavior for images and supported media without loading
  unbounded data into memory.
- Revalidate and document macOS sandbox picker, open, share, and export flows.
- Keep media transfer inside `MatrixRustSDKAdapter` and view-models.

## Boundaries

- Do not reintroduce legacy blob APIs for Matrix rooms.
- Do not implement custom attachment encryption; Matrix SDK media/E2EE must own
  the protocol behavior.
- Do not log attachment bytes or decrypted media content.

## Acceptance criteria

- iOS can send a file, a photo, and a short video or unsupported-media fallback.
- macOS can send a file and image selected through the sandbox picker.
- Received images preview inline before/after app restart.
- Open/share/export works through OS controls for downloaded attachments.
- Large or unsupported files fail with user-readable errors, not generic
  transfer failures.

## Verification plan

- Run iOS and macOS Matrix builds.
- Live-test text file, PNG/JPEG image, and one non-image file in encrypted DM.
- Live-test the same in encrypted group.
- Manual macOS picker/open/share/export release revalidation.
- `git diff --check`
