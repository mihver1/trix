# Matrix: Message Reactions Parity

Status: Open.

## Summary

Legacy Trix supports quick emoji reactions, add/remove toggles, and reaction
chips on timeline messages. The Matrix Apple app has no reaction service API,
timeline model fields, or UI.

## Legacy behavior to match

- iOS long-presses a message, chooses a quick emoji, toggles the current user's
  reaction, and shows chips with counts/self-highlight.
- macOS exposes quick reactions from message context menus and shows reaction
  chips.
- Core projection folds reaction events into message decorations instead of
  showing raw reaction messages in the normal timeline.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `crates/trix-core/src/message.rs`
- `crates/trix-core/src/storage.rs`

## Current Matrix state

- `MatrixRoomService` only exposes timeline, text send, attachment send, and
  attachment download.
- `MatrixTimelineItem` contains sender, timestamp, body, local echo, and
  attachment only.
- No reaction TODO or API was found in the current Matrix Swift surface.

## Required implementation

- Add reaction data to the Matrix timeline model using Matrix SDK event data,
  not custom event parsing in SwiftUI views.
- Add service methods for add/remove reaction or a single toggle operation,
  backed by Matrix SDK reaction APIs where available.
- Add iOS quick reaction UI that matches the legacy compact long-press flow.
- Add macOS context menu or inspector affordance for quick reactions.
- Aggregate reaction counts and whether the active account reacted.
- Hide raw reaction events from normal message rendering unless they cannot be
  associated with a target message.

## Boundaries

- Do not implement a custom Matrix reaction protocol.
- Do not manually decrypt or manipulate event content outside Matrix SDK APIs.
- Do not log decrypted message bodies or event payloads.
- Do not add a full custom emoji browser unless required for parity; quick emoji
  reactions are sufficient.

## Acceptance criteria

- User A sends a message in an encrypted DM and encrypted group.
- User B adds a quick emoji reaction from iOS and macOS.
- User B can tap/click the same reaction again to remove it.
- User A sees reaction chips with correct counts.
- The active user's own reaction is visually distinguishable.
- Reactions survive timeline reload and app restart.

## Verification plan

- Run the standard Apple Matrix build chain.
- Exercise reaction add/remove in a live encrypted DM.
- Exercise reaction add/remove in a live encrypted group with three accounts.
- Confirm logs contain no access tokens or decrypted bodies.
- `git diff --check`
