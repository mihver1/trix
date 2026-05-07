# Matrix: Group Membership Management Parity

Status: Open.

## Summary

Legacy macOS has rich group participant management, and iOS has creation plus
debug member/device controls. Matrix Apple can create encrypted groups and has
service methods for members/invite/remove; macOS has a basic inspector, while
iOS lacks a full participant management surface.

## Legacy behavior to match

- Create DMs and groups from directory-selected accounts.
- View group participants.
- Add people to an existing group.
- Remove people from an existing group.
- Surface member/device membership changes clearly.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Home/DashboardView.swift`
- `apps/ios/TrixiOS/Features/Chats/ChatDetailView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `crates/trix-server/src/routes/chats.rs`

## Current Matrix state

- `MatrixRoomMembershipService` exposes `members`, `inviteUser`, and
  `removeUser`.
- `MatrixRoomBootstrapService` creates encrypted groups and handles invites.
- macOS Matrix inspector can list people and add/remove by Matrix ID.
- iOS Matrix does not expose equivalent post-creation group management.
- There is no directory-backed add-member flow.

## Required implementation

- Add a shared group-member view model that loads members and performs invite or
  remove through `MatrixRoomMembershipService`.
- Add iOS group participant UI reachable from the timeline/header/settings.
- Keep macOS inspector behavior and align it with the shared view model.
- Replace raw Matrix ID-only flows with directory-backed selection once the
  Matrix directory task is implemented; until then, keep raw ID entry validated.
- Surface invite, joined, left, banned, and unknown member states if available.

## Boundaries

- Do not bypass Matrix room permissions or power levels.
- Do not implement custom membership state.
- Do not silently grant admin privileges or trust devices.

## Acceptance criteria

- iOS can list group members, invite a Matrix user, and remove an invited/joined
  user when Matrix permissions allow it.
- macOS continues to list, invite, and remove group members.
- Permission failures are shown as actionable errors.
- Member list updates after refresh and app restart.

## Verification plan

- Build iOS and macOS Matrix targets.
- Live-test a three-account encrypted group.
- Add a fourth account from iOS and macOS.
- Remove that account and confirm all clients update.
- `git diff --check`
