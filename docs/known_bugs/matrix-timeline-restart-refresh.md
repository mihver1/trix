# Matrix: Timeline Refresh After App Restart

Status: Open.

## Summary

The Matrix Apple app can restore a saved session, list rooms, and refresh the
selected timeline while the scene is active. Feature parity still requires a
reliable timeline refresh after the app is fully quit and relaunched.

## Legacy behavior to match

- Legacy iOS restores the dashboard and conversation state from local stores
  before network recovery finishes.
- Legacy iOS/macOS then refresh through realtime/inbox/history paths and keep
  local read state coherent.
- Legacy behavior is a product reference only. Do not port the custom inbox or
  MLS repair implementation into the Matrix client.

Relevant legacy entry points:

- `apps/ios/TrixiOS/App/AppModel.swift`
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
- `crates/trix-core/src/sync.rs`

## Current Matrix state

- `MatrixSessionStore` can load the saved session.
- `MatrixSyncService.rooms(session:)` and `MatrixRoomService.timeline(...)`
  exist.
- `MatrixAppModel` runs a foreground refresh loop while the app is active.
- `docs/mvp-checklist.md` still leaves "Timeline refresh after app restart" as
  unchecked.

## Required implementation

- On successful session restore, load rooms and the selected room timeline
  without requiring a manual refresh.
- Keep Matrix SDK calls in `MatrixRustSDKAdapter` and route UI state through
  `MatrixAppModel`, `RoomListViewModel`, and `TimelineViewModel`.
- Preserve current foreground polling behavior.
- If the Matrix SDK requires an explicit sync bootstrap before timeline queries,
  hide that inside the service/view-model layer and expose a user-readable error
  only if recovery fails.
- Do not log access tokens, room event bodies, decrypted message bodies, or
  recovery keys.

## Acceptance criteria

- Quit and relaunch iOS with an existing Matrix session: the room list appears
  and opening the last selected room shows current timeline content.
- Quit and relaunch macOS with an existing Matrix session: the same behavior
  works through the macOS split-view UI.
- A message sent by a second account while the app is closed appears after
  relaunch without creating duplicate timeline rows.
- The refresh path does not silently drop encrypted DM rooms.

## Verification plan

- `cd apple && xcodegen generate`
- iOS `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`
- macOS `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`
- Manual or live-smoke relaunch test with two disposable Matrix accounts.
- `git diff --check`
