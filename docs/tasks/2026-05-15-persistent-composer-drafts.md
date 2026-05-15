# Task: Persistent Composer Drafts

You are the next coding agent working in the Trix repo. Persist unsent composer
drafts across app restarts without sending them to the server.

## Current Context

Relevant files:

- `docs/security.md`
- `apple/README.md`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Models/TrixModels.swift`

`TrixTimelineView` currently keeps the composer draft in `@State private var
draft = ""`. It is cleared after send and is lost on room switch/relaunch.

## Goal

Text drafts are restored per account and room after room switches and app
relaunches. Drafts stay local, encrypted at rest, and are cleared after a
successful send or explicit discard.

## Non-Goals

- Do not sync drafts to XMPP, the Trix server, iCloud, or any external service.
- Do not persist attachment picker state in this first slice.
- Do not send typing indicators when a draft is restored. Typing state should
  start only after the user edits the restored text.
- Do not log draft text, room IDs, account IDs, local storage paths, or character
  counts tied to specific rooms.

## Implementation Plan

1. Add a local draft store, for example `TrixDraftStore`, keyed by account JID and
   room ID.
2. Store draft contents encrypted at rest. Prefer the same pattern as the
   timeline cache: Application Support file data encrypted by an app-local
   Keychain-held key. Keychain-only storage is acceptable for very small drafts if
   the implementation stays simple and testable.
3. Add app/view-model APIs:
   - `draftText(for roomID:)`;
   - `saveDraft(_:for roomID:)`;
   - `clearDraft(for roomID:)`.
4. Load the draft when `TrixTimelineView` appears or when `room.id` changes.
5. Save with a debounce while the user types. Keep a maximum draft size and trim
   only at storage boundaries, not in the visible composer.
6. Clear the stored draft only after `model.send(text:)` succeeds. If send fails,
   restore or preserve the draft so the user can retry.
7. Add an explicit discard action in the composer or room menu when a draft
   exists.
8. On logout/account clear, remove that account's drafts.
9. Ensure restored drafts do not trigger `sendTypingState(.composing)` until the
   user changes the field.
10. Add tests for per-room isolation, relaunch restore, send-success clear,
    send-failure preserve, and logout clear.

## Acceptance Criteria

- A draft survives room switch and app relaunch for the same account and room.
- Drafts are isolated by account and room.
- Successful send clears the draft; failed send preserves it.
- Restoring a draft does not send typing state.
- Draft text is encrypted at rest and never appears in logs.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Add focused draft-store and composer/view-model tests where the current Apple
test structure allows it.

