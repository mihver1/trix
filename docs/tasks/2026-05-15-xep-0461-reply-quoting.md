# Task: XEP-0461 Reply And Quote Preview

You are the next coding agent working in the Trix repo. Add quote replies using
XEP-0461 without leaking quoted plaintext outside OMEMO.

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
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

Current text sends create a `Message` with `id`, `type`, `to`, and encrypted
`body`. Reactions already prove the codebase can attach server-visible XMPP
metadata to a message-id target, but replies need a timeline model and UI.

## Goal

Users can reply to a specific DM or MUC timeline item. The outgoing message has
an XEP-0461 `<reply/>` reference, and the timeline renders a compact local quote
preview above the new message.

## Non-Goals

- Do not add full message threads here. XEP-0201 is a separate task.
- Do not include decrypted quote text as plaintext outer stanza content.
- Do not use a plaintext fallback body unless you have proven it is inside the
  OMEMO-encrypted payload and not visible to the server.
- Do not support replying to unavailable/deleted messages beyond a safe
  "message unavailable" preview.

## Implementation Plan

1. Verify Martin's `Message`/`Element` API can add the XEP-0461 element before
   OMEMO encoding and whether that element remains outside or inside the OMEMO
   stanza. Document the result in code comments or docs.
2. Extend `TrixTimelineItem` with optional reply metadata, for example target
   message id, target sender, and locally computed preview text. Keep decoding
   backward compatible for existing timeline cache files.
3. Add service API such as `sendText(_:roomID:replyTo:session:)` while keeping
   the old `sendText` wrapper.
4. For outgoing replies:
   - Add XEP-0461 `<reply xmlns='urn:xmpp:reply:0' id='...' to='...'/>`.
   - Use a stable target id from the timeline item. If local ids do not match
     MAM or MUC stanza ids, first add a stable-id mapping rather than shipping
     brittle replies.
   - Store quote preview locally from the existing timeline item.
5. For incoming replies:
   - Parse `<reply/>` metadata.
   - Resolve preview from local timeline/cache by id where possible.
   - Render a safe missing-target state when the original item is unavailable.
6. Add UI affordances on iOS and macOS shared timeline:
   - message context menu action "Reply";
   - composer reply banner with cancel;
   - quote preview in the sent/received bubble.
7. Add live smoke mode `dm-reply` first. Add `group-reply` only after stable MUC
   ids are confirmed.
8. Update `docs/security.md` to state that reply target ids and JIDs are
   server-visible metadata, while quote text remains encrypted/local.

## Acceptance Criteria

- DM quote reply sends and receives between two accounts.
- The reply target metadata survives restart/MAM reload.
- Quote preview text is never sent as visible plaintext metadata.
- Missing target messages render gracefully.
- Existing text, attachment, reaction, and timeline restart behavior still
  works.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed live smoke for `dm-reply`, and for `group-reply` if group
stable ids were implemented.
