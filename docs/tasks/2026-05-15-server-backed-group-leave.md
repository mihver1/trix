# Task: Server-Backed Group Leave

You are the next coding agent working in the Trix repo. Replace the current
local-only group leave with a real Martin MUC leave path, then live-validate it.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `docs/security.md`
- `docs/architecture.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/MockTrixService.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/ViewModels/RoomListViewModel.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

The current UI says group leave is local-only and calls `forgetRoomLocally`.
The service protocol has member list, invite, and remove operations, but no
server-backed leave operation.

## Goal

A user can leave a private MUC group through the Apple app. The app sends a real
MUC leave through Martin, removes the group from local navigation after success,
and does not claim to delete the group for other members.

## Non-Goals

- Do not destroy the room for everyone.
- Do not add Matrix lifecycle behavior.
- Do not hand-roll custom crypto, key exchange, or OMEMO state mutation.
- Do not pretend local hiding is server-backed. If Martin cannot provide a safe
  leave path, document that blocker and keep the checklist open.

## Implementation Plan

1. Inspect Martin's available MUC leave APIs in the resolved Swift package after
   `xcodegen generate` or a build fetches packages. Prefer a reviewed Martin
   `MucModule` or `RoomProtocol` leave operation.
2. Add a service boundary method, for example
   `leaveGroup(roomID:session:)`, to `TrixRoomMembershipService`.
3. Implement the method in `XMPPMartinService`:
   - Normalize and validate the room as a MUC JID.
   - Ensure the current connection is joined or join enough to issue the leave.
   - Send the Martin MUC leave operation.
   - After success, remove the room from in-memory known group state and
     Keychain group cache so it disappears from room list reloads.
   - Preserve secret-safe logging and do not touch OMEMO keys directly.
4. Update mocks and view models so UI flows call the server-backed method.
5. Update `TrixTimelineView` copy and action labels from local-only language to
   accurate server-backed wording. The confirmation should say the user stops
   receiving group updates unless re-added, while other members keep the group.
6. Add a scrubbed live smoke mode, for example `group-leave`, in
   `XMPPLiveSmokeRunner`:
   - Use three accounts.
   - Create a private MUC with owner, peer, and third.
   - Pick a non-owner account as the leaver to avoid owner-transfer ambiguity.
   - Validate all accounts joined before leave.
   - Leave through the new service method.
   - Reload/reconnect the leaver and require the room to be absent or not
     joined.
   - Confirm the remaining accounts still have the group.
   - Print only IDs/status counts, never message bodies or credentials.
7. Update `apple/README.md` with the new live-smoke mode and its required env
   variables.
8. Update `docs/mvp-checklist.md` only after the smoke passes.

## Acceptance Criteria

- iOS and macOS shared UI call a server-backed group leave operation.
- The old local-only confirmation copy is gone for group leave.
- Leaving a group does not destroy it for peers.
- Sending after leave is blocked because the room is no longer joined/visible.
- The group cache is cleaned only after server leave succeeds.
- A three-account live smoke proves leave and remaining-member behavior.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
bash -n apple/scripts/archive-testflight.sh server/xmpp/scripts/*.sh
git diff --check
```

Also run the new `group-leave` live smoke against disposable accounts on
`trix.selfhost.ru` or the local XMPP scaffold. Report the exact scrubbed status
lines and leave the checklist open if live validation cannot be completed.
