# Matrix: User Directory And Profile Parity

Status: Implemented and live-validated for Matrix directory search, exact
profile lookup fallback, account selection, display name editing, and Trix
profile metadata editing.

## Summary

Legacy Trix has a first-class account directory, profile names, handles, bios,
and profile editing. Matrix Apple now uses Matrix SDK-backed directory search
for new DMs, groups, and macOS add-member flows, plus display-name profile
editing. Bio, status, and website are stored as Trix Matrix account data because
the standard Matrix public profile surface used here has no bio field.

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

- `MatrixServiceProtocols` has SDK-backed user directory/profile methods.
- `MatrixNewRoomView` uses searchable account selection for DMs and groups.
- The macOS room inspector uses searchable account selection for add-member.
- iOS and macOS settings can view the current Matrix profile and edit display
  name through Matrix SDK profile APIs.
- iOS and macOS settings can edit Trix bio, status, and website metadata stored
  as Matrix SDK account data.
- Matrix profile avatar URLs are displayed when the SDK returns them.
- Exact `@user:trix.selfhost.ru` or localpart searches fall back to Matrix SDK
  profile lookup when Conduit user-directory search does not return an
  otherwise valid local account.
- Trix metadata is synced through the user's Matrix account data; it is not part
  of the standard public Matrix profile returned for arbitrary users.

## Completed implementation

- Added `MatrixUserDirectoryService` with search, profile lookup, display name
  update, and Trix profile metadata update methods.
- Implemented the Matrix Rust SDK adapter through `Client.searchUsers`,
  `Client.getProfile`, `Client.setDisplayName`, and `Client.setAccountData`.
- Added exact Matrix ID/localpart lookup fallback through `Client.getProfile`
  for local accounts that Conduit does not expose through directory search.
- Added mock directory/profile data for local UI development.
- Added `MatrixUserDirectorySearchViewModel` and shared selection UI.
- Replaced raw ID-only new-room and macOS add-member inputs with directory
  selection.
- Added shared profile settings for name, bio, status, and website editing plus
  read-only avatar URL display.

## Boundaries

- Do not add a custom directory service unless the user explicitly reopens server
  scope.
- Do not commit real user data.
- Do not log passwords, access tokens, or profile payloads containing secrets.

## Acceptance criteria

- iOS and macOS can search users on `trix.selfhost.ru`.
- New DM and group flows can select users from results.
- Add-member flow can select users from results.
- Profile display name can be viewed and edited through Matrix SDK profile APIs.
- Trix bio, status, and website can be viewed and edited through Matrix SDK
  account data.
- Public Matrix profile field boundaries are documented explicitly.
- Live validation covers at least two non-current Matrix accounts through the
  DEBUG `directory-profile` smoke mode.

## Verification plan

- [x] Build iOS Matrix target.
- [x] Build macOS Matrix target.
- [x] Search for at least two disposable Matrix accounts.
- [x] Read and update Matrix profile display name plus Trix bio/status/website
      metadata, then restore it.
- [x] Create a DM from a directory result.
- [x] Create a group from multiple directory results.
- [x] Add a member to an existing group from directory results.
- [x] `git diff --check`

Live result: on May 8, 2026, signed iOS simulator
`TRIX_MATRIX_LIVE_SMOKE_MODE=directory-profile` succeeded against
`trix.selfhost.ru` using local `dev-credentials.txt` environment injection. It
round-tripped display name, bio, status, and website metadata, then restored the
original profile values. It printed only non-secret `TRIX_LIVE_SMOKE` status
lines.
