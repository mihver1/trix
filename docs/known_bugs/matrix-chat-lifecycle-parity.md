# Matrix: Chat Lifecycle Parity

Status: Open.

## Summary

Legacy Trix exposes conversation lifecycle actions such as leave this device,
leave all devices, and delete a DM for both participants. Matrix rooms have a
different lifecycle model, but the Matrix Apple app still needs user-facing
room leave and clear/delete behavior that maps cleanly to Matrix APIs.

## Legacy behavior to match

- Users can leave group chats.
- Legacy DM global delete ends the DM for both legacy participants.
- macOS exposes leave and DM delete in the main workspace.
- iOS exposes lifecycle actions in the consumer chat UI.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `apps/ios/TrixiOS/App/AppModel.swift`
- `crates/trix-server/src/routes/chats.rs`

## Current Matrix state

- Invite decline uses room leave internally in the adapter.
- No product surface was found for leaving an already joined Matrix room.
- No Matrix equivalent of legacy "DM global delete for both" is exposed.

## Required implementation

- Add an explicit service method for leaving a joined room.
- Add iOS and macOS UI actions for leaving a group room with confirmation.
- Decide and document the Matrix-safe replacement for legacy DM global delete:
  likely leave/hide/forget locally, not remote deletion for both participants.
- If Matrix SDK supports forget-room or local room hiding, expose that as a
  separate "remove from list" action with accurate wording.
- Update docs to avoid promising impossible two-party deletion semantics.

## Boundaries

- Do not invent a custom Matrix event to simulate global delete.
- Do not claim that leaving a DM deletes history from the other user's account.
- Do not remove legacy lifecycle tooling.

## Acceptance criteria

- User can leave an encrypted group room from iOS and macOS.
- The left room disappears or is marked left according to the chosen UX.
- Attempting to send after leave is blocked with a clear state.
- DM remove/delete wording accurately reflects Matrix behavior.
- Docs explain any unavoidable difference from legacy global delete.

## Verification plan

- Build iOS and macOS Matrix targets.
- Live-test leaving a group with at least three accounts.
- Live-test DM remove/hide behavior with two accounts.
- Confirm room list and timeline refresh after restart.
- `git diff --check`
