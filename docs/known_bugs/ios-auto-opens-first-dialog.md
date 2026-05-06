# iOS: Opens The First Dialog Automatically

## Summary

On iOS, the Matrix client automatically jumps into the first dialog after the
room list loads. This is wrong for phone UX. The app must show the room list as
the stable landing surface after login/session restore and must only open a
conversation after explicit user selection or an intentional deep link.

## User-visible symptom

- Launch or restore the iOS app.
- After rooms sync, the first room/dialog becomes selected and opened without a
  tap.
- The user loses room-list context and cannot start from a neutral inbox state.

## Expected behavior

- iOS should land on the room list after login and after session restore.
- No room should be opened automatically just because it is first in the list.
- If a previously selected room is restored, that must be a deliberate product
  decision and should not override a fresh launch unless the state is explicit.
- If sync removes the selected room, the app should clear selection or return to
  the list instead of selecting another room opportunistically.

## Investigation notes

- Start in `apple/Sources/Shared/App/MatrixAppModel.swift` and
  `apple/Sources/Shared/Views/MatrixRootView.swift`.
- Check `selectedRoomID` handling during login, restore, room reload, invite
  acceptance, foreground refresh, and selected-room reconciliation.
- Check whether `RoomListViewModel.reload(...)` or root navigation code selects
  `rooms.first` as a fallback.
- Verify that any split-view behavior on macOS is not being applied blindly to
  iOS navigation.

## Implementation requirements

- Keep navigation state in app/view-model layers; do not call Matrix SDK from
  SwiftUI views except trivial wiring.
- Preserve macOS desktop behavior only if it is intentional for a split-view
  layout. The iOS fix must be platform-aware if needed.
- Do not add a fake local room selection cache that can drift from Matrix SDK
  room state.
- Do not hide sync failures by selecting another room silently.

## Verification plan

- Build with `cd apple && xcodegen generate`.
- Build iOS with:
  `xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO`
- Run the app with `just matrix-ios-run` or an equivalent signed simulator
  build/install/launch path.
- Log in to an account with multiple rooms.
- Quit and relaunch.
- Confirm the app lands on the room list and does not open the first room until
  the user taps it.
- Confirm accepting an invite or creating a room may navigate only when that
  action explicitly produces the selected room.

## Acceptance criteria

- Fresh iOS launch after restore shows the room list with no unintended room
  push.
- Foreground refresh does not switch the active room unexpectedly.
- If the currently selected room disappears, iOS returns to the list instead of
  jumping to the first remaining room.
