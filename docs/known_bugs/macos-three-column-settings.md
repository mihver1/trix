# macOS: Navigation And Settings Structure

Status: Needs reproduction check.

## Summary

macOS should keep a desktop-appropriate navigation structure: room list,
timeline, and inspector/settings should be predictable and should not collapse
into an iOS-style tab experience. Settings must expose account, verification,
notification, device, and diagnostic surfaces as parity work lands.

## Expected behavior

- Main macOS window keeps conversation navigation efficient.
- Selecting a room shows the timeline and room inspector.
- Account/settings surfaces are reachable without hiding the room list
  unexpectedly.
- Notification/device/profile/diagnostic settings have stable homes.

## Current Matrix state

- `MatrixMacRootView` has a split-view layout and room inspector.
- The inspector already includes conversation metadata, people, common chats,
  shared media, and room metadata sections.
- Upcoming parity work may add more settings and must not make navigation
  inconsistent.

## Required implementation

- Audit current macOS navigation before changing code.
- Preserve split-view behavior unless a concrete bug is reproduced.
- Place new profile, push, device, and diagnostics surfaces in predictable
  settings/inspector locations.
- Keep iOS and macOS shared logic in view models, but allow platform-specific
  layout.

## Boundaries

- Do not force iOS tab layout onto macOS.
- Do not move SDK calls into SwiftUI views.
- Do not remove existing room inspector sections without replacing their
  product function.

## Acceptance criteria

- macOS has stable room list, timeline, and inspector/settings navigation.
- New parity surfaces do not hide or duplicate each other.
- Keyboard/mouse workflows remain usable for repeated chat work.

## Verification plan

- Build macOS Matrix target.
- Manual pass through room selection, settings, inspector, member management,
  attachment open/share/export, and window resizing.
- `git diff --check`
