# Matrix: User Directory And Profile Parity

Status: Open.

## Summary

Legacy Trix has a first-class account directory, profile names, handles, bios,
and profile editing. Matrix Apple currently requires manual Matrix user IDs for
new DMs, groups, and macOS add-member flows.

## Legacy behavior to match

- New chat flows search people by name or handle.
- Directory results show profile name, handle, and bio where available.
- Profile settings let the user edit display name and bio.
- Search excludes the current account and only returns usable active accounts.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Home/DashboardView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `apps/ios/TrixiOS/App/AppModel.swift`
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
- `crates/trix-server/src/routes/accounts.rs`

## Current Matrix state

- `MatrixNewRoomView` asks for raw Matrix user IDs.
- `RoomListViewModel` validates that IDs are on `trix.selfhost.ru`.
- No Matrix directory/profile service exists in `MatrixServiceProtocols`.
- `docs/mvp-checklist.md` leaves basic profile surfaces unchecked.

## Required implementation

- Add Matrix service methods for user search and profile get/update, using
  Matrix SDK APIs or Matrix client-server APIs through SDK-supported paths.
- Add a reusable directory search view model.
- Replace raw ID-only DM/group creation with searchable account selection.
- Replace macOS raw add-member entry with searchable account selection.
- Add profile settings for display name and avatar/bio only if supported. If
  Matrix has no bio equivalent in the chosen API, document the limitation and do
  not invent a custom profile field.

## Boundaries

- Do not add a custom directory service unless the user explicitly reopens server
  scope.
- Do not commit real user data.
- Do not log passwords, access tokens, or profile payloads containing secrets.

## Acceptance criteria

- iOS and macOS can search users on `trix.selfhost.ru`.
- New DM and group flows can select users from results.
- Add-member flow can select users from results.
- Profile display name can be viewed and edited if Matrix SDK/API support exists.
- Unsupported legacy profile fields are documented explicitly.

## Verification plan

- Build iOS and macOS Matrix targets.
- Search for at least two disposable Matrix accounts.
- Create a DM from a directory result.
- Create a group from multiple directory results.
- Add a member to an existing group from directory results.
- `git diff --check`
