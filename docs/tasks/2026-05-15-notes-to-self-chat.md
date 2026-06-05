# Task: Notes To Self Chat

You are the next coding agent working in the Trix repo. Add a first-class
notes-to-self chat backed by a real encrypted DM to the user's own JID.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/RoomListViewModel.swift`
- `apple/Sources/Shared/Views/TrixRoomSearchView.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

The app can create encrypted direct rooms by JID. Room-list directory results
currently exclude the current user. Direct-message send paths require trusted
OMEMO devices. MartinOMEMO's built-in `forSelf` encode path includes trusted
own devices in the encrypted stanza; do not add the account JID as a separate
recipient just to force sender-side replay.

## Goal

Users have an obvious "Notes to Self" chat that behaves like a normal encrypted
conversation with their own account. Messages should sync through XMPP/MAM and be
decryptable after restart when OMEMO recipient keys are available.

## Non-Goals

- Do not implement notes as a local-only notebook.
- Do not bypass OMEMO trust or allow plaintext sending to self.
- Do not silently trust all own devices as a finished UX.
- Do not leak note bodies or attachment names in notifications, logs, or room
  previews beyond the existing local encrypted app surfaces.

## Implementation Plan

1. Validate the current self-JID behavior in MartinOMEMO before adding UI:
   - create/open a direct room where `inviteeUserID == session.userID`;
   - send an encrypted text message;
   - reload timeline from MAM/cache;
   - verify the encrypted stanza has a local recipient key and decrypts after a
     fresh service restore.
2. If the existing trust pre-check blocks self-JID incorrectly, fix it behind
   `XMPPMartinService` by using reviewed MartinOMEMO store/session APIs. Do not
   hand-edit OMEMO keys.
3. Add `TrixAppModel.openNotesToSelf()`:
   - find an existing direct summary for the current JID if present;
   - otherwise create an encrypted direct room to `session.userID`;
   - select the room and load its timeline.
4. Add a room-list affordance:
   - a pinned "Notes to Self" row or toolbar action;
   - do not rely on directory search returning the current user.
5. Give the self room a stable display name such as `Notes to Self` while keeping
   the room ID as the normalized account JID.
6. Keep send/attachment availability gates identical to normal DMs. If own OMEMO
   device state is unavailable, show the existing trust blocker instead of
   falling back.
7. Add a live smoke mode, for example `notes-to-self`:
   - login;
   - open/create notes room;
   - send encrypted text;
   - restart/restore service;
   - load timeline and verify overlap/decryptability;
   - optionally validate a second signed-in device can read the same note after
     trust;
   - print scrubbed status lines only.
8. Update `docs/security.md` and `apple/README.md` after implementation.

## Acceptance Criteria

- The app exposes a visible Notes to Self entry point.
- The notes chat is backed by XMPP/MAM and normal OMEMO encryption, not local-only
  storage.
- Text sends to self fail closed when OMEMO is unavailable.
- Restart/MAM/cache validation proves at least same-device decryptability.
- No note content, attachment names, or OMEMO material appears in logs or smoke
  output.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run a scrubbed `notes-to-self` live smoke when credentials are available.
If self-JID OMEMO cannot be made safe with MartinOMEMO APIs, document the blocker
instead of adding a plaintext/local-only workaround.
