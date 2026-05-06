# iOS: DM Rooms Are Missing From The Room List

## Summary

On iOS, direct-message rooms do not appear in the room list while group chats do.
This is a functional blocker: users cannot reliably find or open DMs.

## User-visible symptom

- User has one or more encrypted DM rooms.
- iOS room list shows group chats.
- DM rooms are absent, even after sync/foreground refresh/relaunch.

## Expected behavior

- Joined DMs and joined group rooms should both appear in the room list.
- Pending DM invites should appear in the invite section.
- DM rooms should have a clear title derived from the other participant when
  Matrix SDK state provides it.
- DM filtering should not depend on legacy protocol concepts.

## Investigation notes

- Start in `MatrixRustSDKAdapter.rooms(session:)`,
  `MatrixRustSDKAdapter.invitations(session:)`,
  `RoomListViewModel`, and `MatrixRoomSummary`.
- Check how Matrix SDK `Room.isDirect()`, `Room.membership()`,
  `Room.isEncrypted()`, and room list entries are mapped.
- Check whether DMs are filtered out by `isDirect`, missing display names,
  membership state, encryption state, or a bad room category condition.
- Verify room list snapshots include both push-front and push-back updates from
  the SDK room list listener.
- Check the mock service separately only after the real SDK path is understood.

## Implementation requirements

- The source of truth must be Matrix SDK room state.
- Do not create local fake DM rooms to compensate for a sync mapping bug.
- Do not bypass encryption or room membership checks.
- Preserve pending invite handling for both DMs and groups.
- Keep SwiftUI views consuming view-model summaries, not SDK room objects.

## Verification plan

- Use live accounts with at least one encrypted DM and one encrypted group.
- Run `just matrix-ios-run`.
- Confirm both DM and group rooms appear after login/restore.
- Create a new encrypted DM from iOS and confirm it appears.
- Accept a DM invite from iOS and confirm it appears.
- Relaunch and confirm DMs persist in the list.
- Run the iOS and macOS build checks after changes.

## Acceptance criteria

- iOS room list shows joined DMs and groups together or in the intended product
  grouping.
- Pending DM invites are visible and actionable.
- DMs remain visible after foreground refresh and app restart.
