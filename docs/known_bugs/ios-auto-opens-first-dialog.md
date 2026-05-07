# iOS: Opens The First Dialog Automatically

Status: Needs reproduction check.

## Summary

The Matrix iOS app must not automatically open the first room or dialog when the
Chats tab appears. The user should land on the inbox and explicitly choose a
conversation.

## Expected behavior

- On login/session restore, iOS shows the Chats inbox.
- No room is selected automatically on compact iPhone UI.
- Tapping a room opens that room.
- Returning to the inbox does not immediately reopen the first room.

## Investigation notes

- Start in `apple/Sources/Shared/Views/MatrixRootView.swift`.
- Check `MatrixRoomListView`, `RoomListViewModel`, and any selected room binding
  in `MatrixAppModel`.
- Compare against legacy iOS `DashboardView`, where the chat list is the first
  product surface and conversation navigation is explicit.

## Implementation requirements

- Keep iOS compact navigation separate from macOS split selection behavior.
- Do not break macOS where selecting a room in a split view can be appropriate.
- Do not add Matrix SDK calls to SwiftUI views to fix selection state.

## Acceptance criteria

- Fresh login on iPhone simulator shows the inbox, not the first timeline.
- Session restore on iPhone simulator shows the inbox, not the first timeline.
- Incoming room-list refresh does not force-open a room.
- User selection still opens the intended timeline.

## Verification plan

- Build the iOS Matrix app.
- Test fresh login and restored session on `iPhone 17` simulator.
- Add two rooms and verify neither refresh nor invite changes force navigation.
- `git diff --check`
