# Task: Visual Device Verification Without Raw Fingerprint Strings

You are the next coding agent working in the Trix repo. Replace raw manual
fingerprint comparison as the primary trust UX with a human-checkable visual
verification flow.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `docs/xmpp-migration/spike-checklist.md`
- `apple/project.yml`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/TrixOMEMOStore.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/MockTrixService.swift`
- `apple/Sources/Shared/ViewModels/DeviceVerificationViewModel.swift`
- `apple/Sources/Shared/Views/TrixLimitationsView.swift`
- `apple/Sources/Shared/Views/TrixRoomListView.swift`
- `apple/Sources/macOS/TrixMacRootView.swift`

The current model already has `TrixDeviceVerificationChallenge.emojis` and
`.decimals`, and the UI can render a challenge. The live Martin-backed service
still returns `.idle` for verification flows and throws `e2eeUnavailable` for
request/start/approve/decline. Trust is currently a direct call to
`trustPeerDevice`, which marks an active identity as trusted after showing a
fingerprint.

## Goal

Users can verify another device by comparing a short visual challenge on both
devices. The primary UX should be a phrase, 4-5 emoji-style symbols with labels,
or a deterministic visual card. QR scanning is not the default path.

## Non-Goals

- Do not create a custom cryptographic verification protocol.
- Do not silently trust any device.
- Do not claim a fingerprint-derived phrase is a full SAS exchange if it is only
  a display transform over identity fingerprints.
- Do not expose long raw fingerprints as the primary user action.
- Do not ship QR as the only verification route.

## Implementation Plan

1. Investigate the pinned dependencies in `apple/project.yml`:
   - Martin `3.2.4`;
   - MartinOMEMO `2.2.3`;
   - transitive libsignal Swift bindings.
   Record whether MartinOMEMO exposes a reviewed SAS, safety-number, or
   fingerprint verification API that Trix can call directly.
2. If a reviewed API exists:
   - wire `requestDeviceVerification`, `acceptDeviceVerificationRequest`,
     `startSasDeviceVerification`, `approveDeviceVerification`, and
     `declineDeviceVerification` through `XMPPMartinService`;
   - derive the displayed challenge from the reviewed API output;
   - store the resulting trust state through MartinOMEMO/store APIs.
3. If only libsignal fingerprint/safety-number primitives exist:
   - add a clearly named `fingerprintPhrase` or `visualFingerprint` flow, not
     `SAS`;
   - derive the same phrase/card from both parties' stable identity data using a
     documented, deterministic display transform;
   - keep copy explicit that this is visual fingerprint comparison;
   - require explicit user confirmation before calling `trustPeerDevice`.
4. Prefer display formats in this order:
   - 4-5 symbols with text labels if the existing emoji challenge model can be
     filled safely;
   - 4-6 short dictionary words from a fixed built-in list;
   - deterministic identicon-style card derived from the challenge bytes.
5. Update iOS and macOS Settings security surfaces:
   - show device name/JID/device id context;
   - show the visual phrase/card;
   - hide raw long fingerprint behind a disclosure/debug affordance;
   - make approve/decline states clear and reversible only through later
     revocation.
6. Add mock-service coverage for request, accept, challenge, approve, decline,
   cancel, and failure states.
7. Add a scrubbed two-device live smoke mode such as
   `second-device-visual-verify`:
   - two signed or simulator-backed clients for the same account if feasible;
   - both see matching challenge values;
   - approve changes trust state;
   - send remains blocked before approval and allowed after approval.
8. Update `docs/security.md` and `docs/mvp-checklist.md` with exact security
   properties:
   - no silent trust-all;
   - visual phrase/card replaces raw fingerprint comparison;
   - whether this is reviewed SAS or visual fingerprint comparison.

## Acceptance Criteria

- Raw long fingerprint strings are no longer the primary trust UX.
- The user can compare a short visual challenge and explicitly approve or
  decline.
- Unknown/untrusted devices still block encrypted sends until trust is explicit.
- The UI accurately labels the security level of the chosen primitive.
- Mock and live-smoke paths do not log challenge secrets beyond safe display
  labels, and never log OMEMO private material.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run the scrubbed `second-device-visual-verify` live smoke if credentialed
second-device validation is available.
