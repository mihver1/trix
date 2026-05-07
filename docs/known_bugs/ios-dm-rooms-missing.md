# iOS: DM Rooms Are Missing From The Room List

Status: Fixed in current code; keep as regression guard.

## Summary

Direct Matrix rooms must appear in the iOS room list after sync and after app
restart. A previous blocker was that relying on one SDK room source was not
enough to discover all DMs.

## Expected behavior

- Existing encrypted DMs appear in the Chats list.
- Newly created encrypted DMs appear without manual app restart.
- DMs discovered from `m.direct` account data are not filtered out.
- Room list refresh does not duplicate the same DM.

## Current Matrix implementation notes

- `MatrixRustSDKAdapter` merges room-list listener snapshots, `client.rooms()`,
  and `m.direct` account data before filtering.
- `RoomListViewModel` reloads rooms through the Matrix service boundary.

## Regression boundaries

- Do not replace the merged room discovery path with `client.rooms()` only.
- Do not special-case DMs in SwiftUI views.
- Do not log access tokens or raw account data.

## Acceptance criteria

- Live account with at least one existing DM sees it in iOS Chats.
- New DM created from iOS appears in the list.
- DM created by another client appears after refresh.
- Behavior holds after app restart.

## Verification plan

- Build iOS Matrix target.
- Live-test existing DM, newly created DM, and DM created externally.
- Confirm no duplicate room rows.
- `git diff --check`
