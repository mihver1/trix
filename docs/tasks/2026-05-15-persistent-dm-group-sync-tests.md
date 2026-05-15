# Task: Persistent DM And Group Sync Tests

You are the next coding agent working in the Trix repo. Turn the existing live
DM/group sync coverage into a repeatable persistent test gate.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/TrixTimelineCacheStore.swift`
- `apple/Sources/Shared/Services/TrixGroupRoomCacheStore.swift`
- `apple/Sources/Shared/Services/TrixOMEMOStore.swift`
- `apple/Tests/Shared/`

Existing live modes include `timeline-restart`, `dm-e2ee`, `group-e2ee`,
`dm-attachment`, and `group-attachment`. `timeline-restart` currently covers DM
MAM/cache/service restore. The checklist still asks for persistent tests around
encrypted DM/group sync.

## Goal

Add a repeatable test or script gate that exercises encrypted DM and group sync
across restart/persistence paths and can be run by future agents without
reconstructing the command chain from memory.

## Non-Goals

- Do not require committed credentials.
- Do not print decrypted message bodies, credentials, OMEMO keys, attachment
  filenames, media keys, or APNs tokens.
- Do not turn this into a Matrix or legacy `trix-core` test.
- Do not mark the checklist complete with only a mock/unit test; the requested
  coverage is around the existing live encrypted sync behavior.

## Implementation Plan

1. Decide the test shape after inspecting the existing runner:
   - Prefer a shell wrapper under `apple/scripts/` that builds the macOS app and
     runs live smoke modes with scrubbed output.
   - The wrapper should self-skip with a clear message when required credential
     env vars are missing, so it can live in the repo without secrets.
2. Keep `timeline-restart` as the DM persistence case. Require it to report
   MAM/cache counts and `overlap > 0`.
3. Add group persistence coverage. Either:
   - add a new `group-timeline-restart` live mode that creates or uses a private
     MUC, sends one generated OMEMO group message, reloads MAM/cache, restores a
     fresh service instance, and requires overlap after restart; or
   - extend an existing group mode without weakening its current send/decrypt
     checks.
4. Make all generated message bodies opaque and unprinted. Status lines may
   include generated IDs, counts, role names, and boolean flags.
5. Use disposable live accounts from env vars:
   - owner user/password
   - peer user/password
   - third user/password for group coverage
   - optional server URL
   - explicit allow-send and allow-trust gates
6. Document the wrapper in `apple/README.md`, including self-skip behavior and
   the exact env var names.
7. Update `docs/mvp-checklist.md` only after the wrapper passes with live
   credentials for both DM and group sync.

## Acceptance Criteria

- A single documented command can run persistent encrypted sync coverage.
- The DM path uses `timeline-restart` or an equivalent restart/cache/MAM proof.
- The group path proves encrypted MUC timeline sync after restart or a fresh
  service restore.
- Missing credentials produce an explicit skip, not a false pass claiming MVP
  completion.
- Passing live output is scrubbed and includes enough counts to diagnose
  failures.
- The task updates `docs/mvp-checklist.md` with dated evidence only after a
  credentialed pass.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
bash -n apple/scripts/*.sh
git diff --check
```

Then run the new persistent sync wrapper with live disposable credentials. In
the final report, include exact pass/fail status lines and whether any step was
self-skipped.
