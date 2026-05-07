# Matrix: Unread, Read, And Delivery Decorations Parity

Status: Open.

## Summary

Legacy Trix has unread badges, local read cursors, best-effort read receipts,
and outgoing receipt decorations. Matrix Apple currently has room-level unread
counts only and no explicit mark-read/read-receipt surface.

## Legacy behavior to match

- Chat lists show unread badges.
- Opening a conversation marks it read locally.
- The app sends a best-effort read receipt for the latest readable incoming
  message.
- Outgoing messages show receipt state where available.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Home/DashboardView.swift`
- `apps/ios/TrixiOS/App/AppModel.swift`
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
- `crates/trix-core/src/storage.rs`

## Current Matrix state

- `MatrixRoomSummary.unreadCount` exists and is rendered in the room list.
- `MatrixTimelineItem` has no read, delivery, or receipt status.
- `MatrixRoomService` has no mark-read or receipt method.
- `docs/mvp-checklist.md` lists unread/read/delivery decorations as unchecked.

## Required implementation

- Add an explicit Matrix service method for marking a room/timeline event read,
  backed by Matrix SDK receipt APIs.
- Trigger mark-read when the selected timeline is loaded and the latest readable
  event changes.
- Add receipt/decorations to `MatrixTimelineItem` or an adjacent view model
  model.
- Render outgoing read/delivery state without confusing it with local echo.
- Keep room-list unread badges and update them after mark-read.
- Handle encrypted DM and group timelines.

## Boundaries

- Do not reintroduce legacy encrypted receipt messages.
- Do not show fake delivered/read state when Matrix SDK does not provide it.
- Do not mark rooms read while they are not visible.

## Acceptance criteria

- Opening a room clears the unread badge after Matrix sync confirms the read
  marker.
- A second device/account can observe the read receipt through normal Matrix
  client behavior.
- Outgoing message decoration distinguishes local echo from read/delivery state.
- Reopening the app keeps unread state coherent.

## Verification plan

- Run iOS and macOS Matrix builds.
- Live-test with two accounts in an encrypted DM.
- Live-test with three accounts in an encrypted group.
- Confirm unread badge clearing and receipt decoration after restart.
- `git diff --check`
