# macOS: Attachment Transfer Needs Manual Picker/Open Release Revalidation

Status: Partially fixed; manual release revalidation remains open.

## Summary

The macOS Matrix SDK attachment round trip has been fixed at the service/adapter
level, but the release checklist still requires manual validation of the
sandbox picker, open, share, and export flow through the actual macOS UI.

## Original user-visible symptom

- User attempted to attach a file in a Matrix room on macOS.
- The UI reported "Attachment transfer failed".
- The attachment was not sent or could not be downloaded/opened.

## Current Matrix state

- `MatrixTimelineView` reads selected macOS files while holding the
  security-scoped grant.
- `MatrixRustSDKAdapter` stages uploads into app-owned cache storage and uses
  Matrix SDK media APIs.
- Signed live smoke passed generated text and PNG attachment round trips.
- Manual picker/open/share/export release validation is still unchecked in
  `docs/mvp-checklist.md`.

## Required implementation

- Repeat the attachment flow through the real macOS UI, not only live smoke.
- Validate files outside the repository directory.
- Validate open/share/export after download.
- Fix any UI-only failure while preserving the Matrix SDK media path.

## Boundaries

- Do not disable sandboxing.
- Do not read arbitrary filesystem paths without user selection.
- Do not log file contents, decrypted attachment bytes, or access tokens.
- Preserve iOS attachment behavior.

## Acceptance criteria

- macOS can select and send a text file from outside the project directory.
- macOS can select and send an image file from outside the project directory.
- Received file and image attachments can be downloaded.
- Downloaded attachments can be opened, shared, or exported through OS controls.
- No "Attachment transfer failed" appears for the validated cases.

## Verification plan

- `cd apple && xcodegen generate`
- macOS Matrix `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`
- Run a signed macOS debug app if sandbox behavior requires signing.
- Manual encrypted DM and group attachment validation.
- `git diff --check`
