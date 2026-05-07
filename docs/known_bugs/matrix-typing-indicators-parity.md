# Matrix: Typing Indicators Parity

Status: Open.

## Summary

Legacy clients send typing updates while composing. The Matrix Apple app has no
typing service API and no visible typing indicator.

## Legacy behavior to match

- iOS sends typing state while the composer text changes and stops when the view
  disappears.
- macOS sends typing state while the selected chat draft changes.
- A visible incoming typing indicator was not confirmed in legacy production UI,
  so the required parity target is sending typing updates and showing a simple
  incoming indicator if Matrix SDK makes it available.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
- `crates/trix-types/src/api.rs`

## Current Matrix state

- No `MatrixRoomService` method exists for typing.
- No timeline or room model stores typing users.
- No SwiftUI typing indicator exists in Matrix timeline views.

## Required implementation

- Add a Matrix service method for setting typing state for a room.
- Debounce composer changes so the app does not spam the homeserver.
- Send typing false when the composer is cleared, message is sent, room changes,
  scene goes inactive, or timeline view disappears.
- If Matrix SDK exposes incoming typing state, add a compact indicator in the
  timeline footer or composer area.

## Boundaries

- Do not send typing updates for empty drafts.
- Do not log draft contents.
- Do not build a custom realtime protocol.

## Acceptance criteria

- Typing in an encrypted DM sends typing state through Matrix APIs.
- Typing in an encrypted group sends typing state through Matrix APIs.
- Stopping or leaving the room clears typing state.
- Incoming typing state is visible if supported by the Matrix SDK binding.

## Verification plan

- Run iOS and macOS Matrix builds.
- Test typing in a live encrypted DM with another Matrix client or Trix Matrix
  app instance.
- Test cleanup by navigating away while typing.
- `git diff --check`
