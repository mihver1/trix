# macOS: Matrix UI Lacks Legacy Product Parity

Status: Partially fixed; keep as aggregate regression item.

## Summary

The macOS Matrix app has a native split-view shape and a useful room inspector,
but it still lacks several legacy product surfaces. This document is an
aggregate tracker; implement the specific parity documents instead of doing a
broad rewrite.

## Current Matrix state

- macOS room list, timeline, composer, attachment rows, settings, room
  inspector, people section, common chats, shared media, and metadata surfaces
  exist.
- Missing or partial areas include reactions, read/delivery receipts, typing,
  push settings, directory/profile, device management, lifecycle actions,
  diagnostics, and TestFlight packaging.

## Required implementation

- Keep the current macOS split-view foundation.
- Route SDK behavior through services and view models.
- Implement parity gaps through the specific known-bug documents.
- Avoid duplicating iOS-only navigation patterns on macOS.

## Acceptance criteria

- All macOS-relevant open parity documents are resolved or explicitly deferred.
- macOS can perform daily messenger flows without relying on debug surfaces.
- Settings and inspector surfaces expose the Matrix MVP account, room, device,
  notification, and diagnostic state.

## Verification plan

- Run macOS Matrix build.
- Manual macOS pass through login, room list, DM, group, text, media, reactions,
  receipts, push/settings, directory, member management, and diagnostics as they
  are implemented.
- `git diff --check`
