# macOS: Navigation And Settings Structure Is Wrong

## Summary

The macOS Matrix app currently pushes too much account/settings/device state
into the left sidebar. The expected desktop structure is a three-column chat
layout plus a separate settings window, consistent with the legacy product
direction.

## User-visible symptom

- Left sidebar contains chat navigation and settings/account/recovery content.
- Settings are not separated from the messaging workspace.
- The desktop layout does not provide a proper three-column structure.

## Expected behavior

- Main macOS window should use a three-column structure:
  1. Primary navigation / room list.
  2. Timeline / conversation.
  3. Context/detail column where appropriate, such as room info, members,
     attachments, or selected conversation details.
- App/account settings should live in a separate settings window or settings
  scene, not permanently in the chat sidebar.
- Device verification and recovery should be reachable from settings/account
  surfaces without taking over the room list.

## Reference boundary

- Use legacy Trix macOS as the behavior and layout reference. Reading legacy
  code is allowed to understand existing behavior and structure.
- Do not copy legacy implementation code.
- Do not change legacy macOS TestFlight tooling.

## Investigation notes

- Start in `apple/Sources/Shared/Views/MatrixRootView.swift` and the macOS app
  entry point under `apple/Sources/macOS`.
- Check whether the current `NavigationSplitView` is shared across iOS/macOS in
  a way that prevents desktop-specific columns.
- Check how account/device verification/recovery UI is currently embedded.
- Evaluate whether macOS should use a platform-specific root view while reusing
  shared row/timeline/settings subviews.

## Implementation requirements

- Keep room list and timeline view models reusable.
- Add macOS-specific scene/window structure only where product behavior requires
  it.
- Do not move Matrix SDK calls into view code.
- Settings window must not expose secret values in logs or persistent plaintext
  state.
- Preserve iOS navigation expectations; do not force a desktop split layout on
  iPhone.

## Verification plan

- Run `just matrix-macos-run`.
- Confirm the main window has three functional columns at a normal desktop
  width.
- Open settings through the macOS menu/toolbar/app command and confirm it opens
  as a separate settings window or scene.
- Confirm account, device verification, and recovery actions are available from
  settings.
- Confirm the left sidebar is reserved for navigation/rooms, not settings
  content.
- Resize the window and verify columns collapse gracefully.

## Acceptance criteria

- macOS main window uses a three-column chat structure.
- Settings are separate from the left sidebar.
- Device/recovery flows remain accessible and safe.
- iOS navigation remains phone-appropriate.
