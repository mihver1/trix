# iOS: Matrix UI Lacks Legacy Product Parity

Status: Partially fixed; keep as aggregate regression item.

## Summary

The iOS Matrix UI has moved beyond scaffold state, but several legacy product
surfaces still remain incomplete. This document is an aggregate tracker; use the
specific parity documents in this folder for implementation.

## Current Matrix state

- iOS has Chats and Settings tabs.
- Room list, invite actions, timeline rows, composer, attachments, account
  state, and verification/recovery surfaces exist.
- Missing or partial areas include reactions, read/delivery receipts, typing,
  push, directory/profile, device management, group participant management, and
  timeline restart refresh.

## Required implementation

- Do not solve this as one broad rewrite.
- Implement the specific parity documents one at a time.
- Keep Matrix SDK calls behind services/view models.
- Preserve the current native SwiftUI product shape.

## Acceptance criteria

- All iOS-relevant open parity documents are resolved or explicitly deferred by
  the user.
- The iOS app can perform the core messenger flows without scaffold language.
- The Settings tab exposes account/profile/device/push/diagnostic surfaces that
  are in scope for the Matrix MVP.

## Verification plan

- Run the standard iOS Matrix build.
- Manual iPhone pass through login, room list, DM, group, send text, send media,
  reactions, receipts, push, settings, directory, and device surfaces as they are
  implemented.
- `git diff --check`
