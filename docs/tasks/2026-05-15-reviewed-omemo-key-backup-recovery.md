# Task: Reviewed OMEMO Key Backup And Recovery Decision

You are the next coding agent working in the Trix repo. Research and, only if
safe, select a reviewed OMEMO key backup/recovery path for the current
MartinOMEMO/libsignal Apple stack.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `docs/xmpp-migration/apple-omemo-feasibility.md`
- `docs/xmpp-migration/spike-checklist.md`
- `docs/xmpp-migration/risk-register.md`
- `apple/project.yml`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/TrixOMEMOStore.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/DeviceVerificationViewModel.swift`
- `apple/Sources/Shared/Views/TrixLimitationsView.swift`

`docs/security.md` currently states that there is no validated server-side OMEMO
key backup or account recovery path. `XMPPMartinService.setUpRecovery` and
`confirmRecoveryKey` are placeholders that throw `e2eeUnavailable`. The local
store persists registration id, identity key pair, prekeys, signed prekeys,
sessions, identities, and sender keys in Keychain.

## Goal

Produce a concrete decision:

- implement a reviewed backup/recovery path if MartinOMEMO/libsignal provides one
  that fits Trix; or
- leave recovery disabled and document the exact blocker.

## Non-Goals

- Do not invent custom key backup encryption.
- Do not move OMEMO private key material to the server manually.
- Do not store recovery keys or backup passphrases in logs, diagnostics, or
  plaintext files.
- Do not present recovery as available until a live restore proves old ciphertext
  can be decrypted by the recovered device.
- Do not use Signal-specific account-backup primitives directly for OMEMO unless
  the upstream API/docs clearly support this use.

## Research Plan

1. Inspect the exact checked-in dependency versions:
   - Martin `3.2.4`;
   - MartinOMEMO `2.2.3`;
   - transitive libsignal package and version resolved by Xcode.
2. Read upstream source/docs for:
   - MartinOMEMO storage and account/device lifecycle;
   - any backup, export, import, recovery, safety-number, or device-transfer APIs;
   - libsignal Swift bindings exposed through MartinOMEMO;
   - license obligations for any additional backup code path.
3. Determine whether a reviewed recovery flow exists for these data classes:
   - local OMEMO registration id;
   - identity key pair;
   - signed prekeys and prekeys;
   - sessions;
   - sender keys for group messages;
   - local trust decisions.
4. Evaluate candidate designs only if they rely on reviewed APIs:
   - platform Keychain/iCloud Keychain continuity;
   - MartinOMEMO-provided export/import;
   - libsignal-provided backup APIs if applicable to OMEMO state;
   - explicit unsupported/blocker state.
5. Define proof requirements before implementation:
   - device A sends encrypted DM and group messages;
   - device B restores from selected recovery path;
   - B can decrypt old eligible MAM/local-cache ciphertext if the path claims
     history recovery;
   - newly created replacement device does not silently trust unknown devices;
   - no secrets appear in logs.

## Implementation Plan If A Reviewed Path Exists

1. Add a narrow recovery service abstraction under `TrixDeviceVerificationService`
   or a new `TrixRecoveryService`.
2. Implement recovery setup/confirm in `XMPPMartinService` using only the
   selected reviewed APIs.
3. Store recovery UI state in `TrixDeviceVerificationStatus` without storing the
   recovery secret itself in view models longer than necessary.
4. Add iOS/macOS Settings UX:
   - set up recovery;
   - show one-time recovery material;
   - confirm saved recovery material;
   - recover on reinstall/fresh device.
5. Add tests/mocks for all states: disabled, creating, enabled, incomplete,
   downloading/restoring, failed.
6. Add live smoke `omemo-recovery-restore`.
7. Update `docs/security.md`, `docs/mvp-checklist.md`, and
   `docs/xmpp-migration/risk-register.md` with the selected path and limits.

## Implementation Plan If No Reviewed Path Exists

1. Keep `setUpRecovery` and `confirmRecoveryKey` unavailable in the Martin-backed
   service.
2. Improve Settings copy if needed so users understand reinstall creates a new
   OMEMO device and old ciphertext may remain unavailable.
3. Add a short decision record under `docs/tasks/` or `docs/xmpp-migration/`
   summarizing the researched APIs and why Trix is not shipping recovery yet.
4. Keep `docs/security.md` factual and explicit that no custom recovery was
   added.

## Acceptance Criteria

- There is a written decision with upstream source links and exact dependency
  versions.
- If implemented, live restore proves the promised recovery behavior.
- If blocked, the UI and docs remain honest and do not expose broken recovery
  buttons as working features.
- No custom crypto or private-key movement is added.
- No recovery secret, OMEMO private key, sender key, or decrypted message content
  is logged.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

If a recovery implementation lands, also run scrubbed `omemo-recovery-restore`
live smoke and report exact pass/fail states.
