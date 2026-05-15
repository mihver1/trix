# Task: User History Export

You are the next coding agent working in the Trix repo. Add an explicit user
export path for decrypted local history.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixTimelineCacheStore.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`

The app already has per-attachment Open/Share/Export flows after local decrypt.
There is no whole-room or account history export yet.

## Goal

Users can intentionally export their locally available decrypted message history
as `.json` or `.txt`, with a clear warning that the output file is plaintext and
outside Trix encryption.

## Non-Goals

- Do not auto-export, background-export, sync exports to a server, or upload
  exports anywhere.
- Do not fetch older MAM history just because the user started export. Export
  cached/local history unless the UI explicitly adds a separate "sync first"
  action later.
- Do not include decrypted attachment bytes in the first implementation. Export
  attachment metadata only, and make future attachment-bundle export a separate
  task.
- Do not log exported content, destination paths, attachment filenames, room IDs,
  or message bodies.

## Implementation Plan

1. Add an export model and service behind the app/view-model layer:
   - selected room or all cached rooms;
   - format: JSON or plain text;
   - date range if cheap to support;
   - include attachment metadata, not attachment bytes.
2. Reuse the local cache/manifest decision from the search task if it already
   exists. If not, add the minimal encrypted cache enumeration needed for export.
3. Define a stable JSON schema with versioning. Include:
   - export metadata: app export schema version, account JID, generated timestamp;
   - rooms: room ID/name/kind where locally known;
   - messages: message id, room id, sender, timestamp, body, local echo flag,
     delivery state, reactions, and attachment metadata.
4. Define a readable `.txt` format for one room and all-room exports. Keep it
   deterministic enough for tests.
5. Add a confirmation sheet/alert before generating the file. The copy must say
   that the export contains decrypted plaintext and anyone with the file can read
   it.
6. Use platform-native save/share controls:
   - iOS: `fileExporter` or share sheet with a generated temporary file;
   - macOS: `fileExporter`/save panel style flow.
7. Generate into a temporary location only after confirmation. Delete temporary
   files on cancellation when the platform API leaves cleanup to the app.
8. Keep export actions visible but not accidental:
   - room-level export in the timeline menu;
   - optional account/all-history export in Settings after the single-room path is
     reliable.
9. Add tests for JSON schema, text formatting, warning-required state, and export
   scope filtering.
10. Update `docs/security.md` and `apple/README.md` after implementation.

## Acceptance Criteria

- A user can export a selected room as JSON and TXT through an explicit OS save or
  share flow.
- Export requires a visible plaintext warning before file generation.
- Exported JSON is versioned and deterministic enough for regression tests.
- Attachments are represented by metadata only; decrypted attachment bytes are
  not included.
- No export contents or destination paths appear in logs.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run focused JSON/TXT formatter tests. Manual verification should export a
small fake/local room and inspect the resulting file locally, but the report must
not paste message bodies or attachment names.

