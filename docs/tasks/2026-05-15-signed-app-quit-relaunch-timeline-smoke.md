# Task: Full Signed-App Quit/Relaunch Timeline Smoke

This task is closed for the current MVP. On 2026-05-20 the signed macOS
persistent gate ran `timeline-relaunch-seed` and `timeline-relaunch-verify` in
separate processes, restored from the smoke Keychain session, found nonzero
timeline overlap, and cleaned up the smoke marker/session state.

Keep this file as the historical signed-relaunch smoke plan. Reopen it only if
the process-level relaunch proof regresses or the release gate changes.

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

`timeline-restart` logs in, optionally sends a generated OMEMO DM, loads
timeline state, creates a fresh `XMPPMartinService` in the same process,
restores, and checks overlapping item IDs. The process-level proof is handled by
`timeline-relaunch-seed` and `timeline-relaunch-verify`, normally through
`apple/scripts/run-persistent-sync-gate.sh --include-keychain-relaunch`.

## Goal

Maintain a repeatable smoke that launches a signed app bundle, creates or loads
encrypted timeline state, quits the OS process, relaunches the app, and proves
the timeline restores without retyping the password.

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
7. Update `docs/mvp-checklist.md` only after future signed-app relaunch changes
   pass again.

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

For future relaunch-gate changes, run the signed-app quit/relaunch smoke with
disposable live credentials. If signing, device access, or credentials are
unavailable, report the exact blocker for that change rather than editing the
closed MVP item.
