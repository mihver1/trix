# Task: XEP-0201 Threaded Replies

You are the next coding agent working in the Trix repo. Add true message-thread
metadata and UI only after quote replies are understood as a separate feature.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

This is not the same as XEP-0461 quote replies. Threads create conversation
substructure; quote replies create a reference and preview inside the main
timeline.

## Goal

Users can start and continue lightweight message threads in group chats. Thread
metadata survives restart and can be rendered without disrupting the main
timeline.

## Non-Goals

- Do not implement this before quote replies unless the product explicitly
  prioritizes threaded group navigation.
- Do not replace XEP-0461 quote replies with threads.
- Do not expose message bodies or quoted snippets in thread metadata.
- Do not build a Slack-like thread product in the first slice.

## Implementation Plan

1. Confirm Martin support for XMPP `<thread/>` elements and how they behave with
   OMEMO encoding. If raw elements are needed, keep them in the service layer.
2. Add stable thread identifiers:
   - new thread id for "start thread";
   - same thread id for replies in that thread;
   - optional parent thread metadata if needed.
3. Extend `TrixTimelineItem` with optional thread metadata and backward
   compatible cache decoding.
4. Add service API:
   - `sendText(_:roomID:thread:session:)`;
   - wrappers so normal send remains unchanged.
5. UI first slice:
   - "Reply in thread" action on group messages;
   - compact thread summary count in main timeline;
   - a simple thread detail view or filtered timeline.
6. Parse incoming thread metadata from live messages and MAM.
7. Decide interaction with XEP-0461:
   - a threaded reply may also quote a parent item;
   - if both are present, render quote preview inside the thread message.
8. Add live smoke `group-thread`:
   - three-account private MUC;
   - send root message;
   - send threaded response;
   - peer and third see thread id/count after decrypt/reload;
   - output only IDs/counts/booleans.
9. Update `docs/security.md` to document that thread ids/parent relationships
   are server-visible metadata.

## Acceptance Criteria

- Thread metadata sends and parses in encrypted group messages.
- Main timeline remains readable and does not hide messages unexpectedly.
- Thread view or filter works on iOS and macOS shared UI.
- Restart/MAM reload preserves thread grouping.
- Normal quote replies and normal sends still work.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed live smoke for `group-thread` if implemented.
