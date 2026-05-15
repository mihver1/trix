# Task: Per-Room Mute And Notification Profiles

You are the next coding agent working in the Trix repo. Add local per-room
notification preferences without changing the wake-only APNs contract.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/ViewModels/RoomListViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/App/TrixAPNsCoordinator.swift`

The Apple client accepts only wake-only push payloads and schedules generic local
notifications after inactive sync. Unread state is local and should be cleared
only on explicit room open.

## Goal

Users can set notification behavior per room, starting with:

- default behavior;
- muted: no local banner/sound for that room;
- mentions only: local notification only when the app can identify a mention from
  decrypted local message metadata/content.

Unread counts and timeline sync should continue to work regardless of profile.

## Non-Goals

- Do not put room notification preferences, room names, message bodies, mention
  text, or mute state into APNs payloads.
- Do not change ejabberd push payloads for this task unless a future server-side
  push-rule task explicitly scopes it.
- Do not make muted rooms disappear or mark them read.
- Do not surface decrypted message text in local notifications.
- Do not require the mentions XEP task to be complete before storing the
  `mentionsOnly` profile; if mention detection is unavailable, treat it as
  suppressing non-mention notifications and document the limitation.

## Implementation Plan

1. Add a local `TrixRoomNotificationProfile` model:
   - `default`;
   - `muted`;
   - `mentionsOnly`.
2. Add an encrypted local store keyed by account JID and room ID. Notification
   preferences reveal social graph/behavior metadata, so do not store them in a
   plaintext JSON file.
3. Expose profile state through `TrixAppModel` or a small settings view model.
4. Add UI:
   - room header/menu entry for notification settings;
   - visible muted indicator in room list and/or header;
   - settings sheet with the three profiles.
5. Integrate with inactive notification handling:
   - keep accepting only wake-only remote payloads;
   - after local sync, decide whether to schedule a generic local notification
     based on the room profile;
   - muted rooms do not schedule local banner/sound;
   - mentions-only rooms notify only when local decrypted state can determine a
     mention for the current account.
6. Keep badge/unread behavior explicit:
   - unread count still increments/preserves for muted rooms;
   - local notification suppression must not call `markRead`.
7. If `TrixRemoteNotificationPayload.roomID` is present and valid, use it as a
   hint only. If it is missing, infer changed rooms from the before/after room
   summaries without exposing plaintext.
8. Keep local notification text generic:
   - default: existing encrypted-message/unread wording;
   - mention: generic wording such as "You were mentioned in an encrypted
     message";
   - never include room name if the product decides room names are sensitive in
     lock-screen notifications.
9. Add tests for:
   - profile persistence/isolation by account and room;
   - muted room suppresses local notification but keeps unread;
   - background sync does not mark muted rooms read;
   - wake-only payload validation still rejects plaintext fields.
10. Update `docs/security.md` and `apple/README.md` after implementation.

## Acceptance Criteria

- Users can set default, muted, and mentions-only profiles per room.
- Muted rooms still sync and accumulate unread state but do not produce local
  notification banners/sounds.
- APNs payload shape remains wake-only and plaintext-free.
- Local notification copy remains generic and plaintext-free.
- Room notification profile data is stored locally with encryption at rest.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run notification handling tests or a local fake wake-only push path that
proves muted rooms suppress only local presentation, not sync or unread state.

