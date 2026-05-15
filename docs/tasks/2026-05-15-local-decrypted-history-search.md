# Task: Local Decrypted History Search

You are the next coding agent working in the Trix repo. Add local search over
decrypted Apple timeline history without adding server-side search.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixTimelineCacheStore.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/ViewModels/RoomListViewModel.swift`
- `apple/Sources/Shared/Views/TrixRoomSearchView.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`

The Apple XMPP path already stores decrypted `TrixTimelineItem` values in a
bounded local cache encrypted with an app-local cache key. Room-list search
currently covers room names, room IDs, and directory results only.

## Goal

Users can search locally available decrypted history across the current room and
known cached rooms. Search must work after relaunch for cached messages and must
not contact the XMPP server or any Trix server endpoint.

## Non-Goals

- Do not add server-side history search.
- Do not trigger MAM fetches solely because the user typed a search query.
- Do not index or search undecryptable archived ciphertext.
- Do not log search terms, snippets, matching message text, attachment filenames,
  room IDs, or local cache paths.
- Do not mark rooms read because search loaded cached history or showed a result.

## Implementation Plan

1. Add a local search abstraction, for example `TrixLocalHistorySearchService` or
   `TrixHistorySearchStore`, behind the app/view-model layer. It may read the
   existing encrypted timeline cache, but it must not call `service.timeline(...)`
   or `service.rooms(...)` from query execution.
2. Decide how to enumerate searchable rooms. If `TrixTimelineCacheStore` cannot
   safely enumerate cache files by account/room, add an encrypted per-account
   cache manifest updated whenever timeline items are saved.
3. Index or scan only locally decrypted `TrixTimelineItem` fields:
   - message body;
   - sender display/JID if already available locally;
   - attachment display metadata from the encrypted descriptor if already in the
     cached item.
4. Keep the first implementation simple and bounded. A normalized in-memory
   index rebuilt from the encrypted cache is acceptable if it is fast enough for
   the bounded cache size. Persist a derived index only if it is encrypted at rest
   and invalidated when cache items change.
5. Add search models:
   - query text;
   - scope: current room and all cached rooms;
   - result rows with room name, timestamp, sender, short snippet, and message id.
6. Add UI without replacing the existing room-list directory search:
   - current-room search affordance in `TrixTimelineView`;
   - optional all-history entry point from room list or app search;
   - tapping a result opens the room and scrolls/highlights the message if the
     item is still in the local timeline.
7. Ensure loading search results does not call `RoomListViewModel.markRead(...)`
   unless the user explicitly opens the room as a normal chat view.
8. Add tests with a fake encrypted cache containing two rooms. Assert that query
   execution returns expected snippets and does not invoke network/service mocks.
9. Update docs only after behavior exists:
   - `docs/security.md`: local decrypted search index/cache behavior and logging
     constraints;
   - `apple/README.md`: user-facing capability and verification note.

## Acceptance Criteria

- Search returns cached decrypted messages across at least the current room and
  known cached rooms.
- No XMPP/MAM/directory/server request is made while typing or executing a search.
- Search survives app relaunch for messages already in the encrypted local cache.
- Result rendering never prints message bodies, snippets, filenames, queries, or
  local paths to logs.
- Search result navigation does not clear unread state unless the user explicitly
  opens the room.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Add focused unit tests or view-model tests for the local search store. If live
credentials are available, run a scrubbed `timeline-restart` smoke first to
populate local cache, then verify local search manually without printing message
content.

