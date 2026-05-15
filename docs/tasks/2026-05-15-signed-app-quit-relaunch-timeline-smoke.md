# Task: Full Signed-App Quit/Relaunch Timeline Smoke

You are the next coding agent working in the Trix repo. Prove timeline restore
through a real signed app process quit and relaunch, not just an in-process
service restart.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/scripts/archive-testflight.sh`
- `apple/project.yml`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Services/KeychainTrixSessionStore.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/TrixTimelineCacheStore.swift`

`timeline-restart` currently logs in, optionally sends a generated OMEMO DM,
loads timeline state, creates a fresh `XMPPMartinService` in the same process,
restores, and checks overlapping item IDs. The MVP item still requires a full
signed app process quit/relaunch.

## Goal

Add and run a repeatable smoke that launches a signed app bundle, creates or
loads encrypted timeline state, quits the OS process, relaunches the app, and
proves the timeline restores without retyping the password.

## Non-Goals

- Do not treat in-process `XMPPMartinService` recreation as sufficient.
- Do not solve older sender-side messages that were not encrypted for the
  current device. That remains the separate self-history/recovery blocker.
- Do not print generated message bodies, credentials, OMEMO material, or
  decrypted content.

## Implementation Plan

1. Keep the existing `timeline-restart` mode, but add a process-level smoke
   path. Prefer macOS first because it can launch an app bundle directly with
   environment variables and automatic signing.
2. Add paired live-smoke modes or a small wrapper script under `apple/scripts/`.
   A practical split is:
   - `timeline-relaunch-seed`: log in through the same session persistence path
     the app uses, optionally send one generated OMEMO DM, load the timeline,
     write only a scrubbed message ID/count marker to a temp file, and exit
     without clearing the saved session.
   - `timeline-relaunch-verify`: start in a new process, restore the saved
     Keychain session, load the same timeline, require overlap with the marker,
     then optionally clean up the smoke-only session state.
3. Use the real app executable from a signed build or archive. The smoke must
   prove two process IDs or two separate launches.
4. Keep the smoke-only state isolated from normal user state where practical.
   If you use the default session store to match production, add explicit
   cleanup and document the risk.
5. Capture only `TRIX_XMPP_LIVE_SMOKE` status lines. Do not print message text.
6. Update `apple/README.md` with the process-level smoke command and env vars.
7. Update `docs/mvp-checklist.md` only after the signed app relaunch proof
   passes.

## Acceptance Criteria

- The smoke launches a signed app process, exits it, launches a second app
  process, and proves session restore plus timeline overlap.
- The second launch does not require retyping the password.
- The proof includes `before`, `after`, and `overlap` counts or an equivalent
  scrubbed marker.
- The command path is repeatable and documented.
- No secrets or decrypted message bodies are printed.
- The existing in-process `timeline-restart` mode still works.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
bash -n apple/scripts/*.sh
git diff --check
```

Then run the new signed-app quit/relaunch smoke with disposable live
credentials. If signing, device access, or credentials are unavailable, report
the exact blocker and leave the MVP item unchecked.
