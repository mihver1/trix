# Task: MUC Pinned Messages With Bookmark-Backed State

You are the next coding agent working in the Trix repo. Add pinned messages for
MUCs with clear semantics: per-account bookmark-backed pins first, shared MUC
pins only if a server-backed design is explicitly chosen.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/MockTrixService.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/Views/TrixGroupMembersView.swift`

`XMPPMartinService` already uses `PEPBookmarksModule` to bookmark group rooms.
XEP-0402 is native bookmarks, not a general shared pin-message standard.

## Goal

Users can pin and unpin MUC messages for their own account. Pins survive app
restart and can be restored from bookmark-backed state.

## Non-Goals

- Do not claim bookmark-backed pins are shared room-wide pins.
- Do not add public/federated pin semantics.
- Do not put decrypted message bodies or previews into bookmark extension data.
- Do not require server admin APIs for the per-account first slice.

## Implementation Plan

1. Decide and document v1 semantics:
   - per-account pins synced through XEP-0402 bookmark extension data;
   - or shared group pins through a later Trix control-plane/MUC metadata path.
   Implement only the per-account path unless the user explicitly chooses shared
   pins.
2. Extend the timeline model with pin state and add local cache support.
3. Extend the bookmark persistence path:
   - read existing MUC bookmark for the room;
   - store a compact Trix extension containing pinned message ids and optional
     pinned-at timestamp;
   - preserve standard bookmark fields and unknown data where possible.
4. Do not store plaintext message body, quote preview, attachment filename, or
   decrypted content in bookmark extension data.
5. Add UI:
   - pin/unpin from message context menu;
   - pinned strip or inspector section for current room;
   - tap pin to scroll/select the message if still available;
   - missing-message state if the pinned item is unavailable after MAM/cache
     reload.
6. Add live smoke `muc-pins-bookmark`:
   - create or use a private MUC;
   - send one encrypted message;
   - pin it;
   - restart/fresh service restore;
   - verify pinned id reloads from bookmark-backed state;
   - print only IDs/counts/status.
7. Update `docs/security.md` to document that pinned message ids and pin
   timestamps are server-visible account metadata if stored in PEP bookmarks.

## Acceptance Criteria

- A user can pin/unpin a MUC timeline item.
- Pin state survives restart through bookmark-backed persistence.
- Bookmark data does not include decrypted text or attachment metadata.
- UI clearly behaves as "your pins" unless shared pins are implemented.
- Existing group bookmark/autojoin behavior is preserved.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed live smoke for `muc-pins-bookmark` if implemented.
