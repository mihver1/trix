# Task: Encrypted Call Smoke Tests

You are the next coding agent working in the Trix repo. Close the encrypted
calls MVP item only after real signed-device smoke proves DM video, group voice,
forced TURN relay, and secret-safe logging.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `docs/security.md`
- `apple/README.md`
- `apple/project.yml`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Models/TrixCallModels.swift`
- `apple/Sources/Shared/Services/TrixCallServices.swift`
- `apple/Sources/Shared/ViewModels/TrixCallViewModel.swift`
- `apple/Sources/iOS/TrixiOSApp.swift`
- `apps/trix-call-control/src/main.rs`
- `apps/trix-push-gateway/src/main.rs`
- `apps/trix-push-gateway/README.md`
- `server/xmpp/README.md`
- `server/xmpp/scripts/call-log-audit.sh`

The checked-in call slice includes `trix-call-control`, short-lived LiveKit
tokens, TURN REST credentials, OMEMO-encrypted call descriptors, LiveKit media
E2EE, iOS PushKit/CallKit entrypoints, VoIP push payload validation, shared DM
video/group voice UI, `TRIX_CALL_FORCE_RELAY_ONLY=1` for signed-device forced
TURN smoke, and `server/xmpp/scripts/call-log-audit.sh` for post-smoke
log-bundle scanning. The MVP checklist remains open because the required
signed-device media proof has not passed yet.

## Goal

Produce repeatable smoke evidence for encrypted calls:

- DM video: two signed Apple devices, incoming CallKit/PushKit path on the callee,
  answer, bidirectional audio and video, and reconnect after a network/app
  interruption.
- Group voice: first three accounts in a private MUC, then ten authenticated
  participants in the same room, all with real LiveKit media sessions.
- TURN forced path: run at least one DM video or group voice call with relay-only
  ICE so media is proven through coturn instead of direct or reflexive candidates.
- Log audit: captured app, call-control, push-gateway, LiveKit/coturn, and proxy
  logs contain no LiveKit tokens, TURN credentials, media keys, XMPP passwords,
  APNs tokens, OMEMO secrets, or decrypted content.

## Non-Goals

- Do not mark calls complete from unit tests, token-minting API checks, or
  simulator-only media tests.
- Do not print or commit real account passwords, LiveKit JWTs, TURN usernames or
  credentials, media keys, APNs tokens, OMEMO material, or decrypted content.
- Do not weaken OMEMO descriptor gates, LiveKit E2EE, or device-trust checks to
  make the smoke easier to pass.
- Do not count group voice as ten participants unless ten authenticated clients
  have joined the LiveKit room; REST calls that only mint tokens are not enough.
- Do not expose `trix-call-control`, LiveKit admin APIs, coturn admin surfaces, or
  the push gateway publicly beyond the intended private deployment paths.

## Implementation Plan

1. Confirm current state with `git status --short`, then inspect the files above.
2. Build and install signed Apple apps with the existing `apple/` lane. The DM
   CallKit criterion requires the callee to use a signed iOS build with PushKit
   and CallKit available.
3. Provision disposable live accounts through the existing operator path. Use
   two accounts for DM video, three accounts for the first group voice smoke, and
   ten accounts for the scale smoke. Inject credentials through temporary
   environment, Keychain, or device UI only.
4. Confirm each participant has visible OMEMO device/trust state and that product
   send gates are not bypassed. If trust setup is required, perform it explicitly
   and keep fingerprints/secret material out of logs.
5. Run DM video smoke:
   - caller starts a DM video call from the signed app;
   - callee receives the incoming CallKit UI from the VoIP push path;
   - callee answers through CallKit;
   - both sides publish and receive audio and video;
   - interrupt one side with network toggle, app background/foreground, or
     LiveKit reconnect path;
   - require media recovery or a clean user-visible failure plus retry path.
6. Run group voice smoke with three accounts:
   - create or reuse a private members-only MUC;
   - all three accounts join the voice room from signed app builds;
   - verify each participant hears the others and the active participant count is
     consistent across clients;
   - leave/end the call cleanly without stale active-call UI.
7. Run group voice smoke with ten participants:
   - repeat the same private MUC voice flow with ten authenticated clients;
   - verify the LiveKit room contains ten participants, audio is usable for a
     representative speaking rotation, and clients do not show stale/missing
     participants after reconnect or leave.
8. Run the forced TURN path:
   - launch the signed app with `TRIX_CALL_FORCE_RELAY_ONLY=1` so the LiveKit
     adapter uses relay-only ICE transport policy;
   - block direct candidate success or configure ICE transport policy to relay;
   - prove selected candidate pairs are relay/coturn-backed from sanitized
     client, LiveKit, or coturn diagnostics;
   - do not print TURN usernames, credentials, or LiveKit JWTs.
9. Capture a sanitized log bundle for the smoke window:
   - Apple app logs from signed devices or macOS Console;
   - `trix-call-control` logs;
   - `trix-push-gateway` logs for the VoIP call push;
   - LiveKit and coturn logs sufficient to prove joins and relay use;
   - reverse-proxy logs if they are part of the call-control path.
10. Run `server/xmpp/scripts/call-log-audit.sh /path/to/call-smoke-logs` over
    the captured bundle. Its report must include only forbidden class names, file
    paths, and line counts; it must not echo matched secret values.
11. Update `docs/mvp-checklist.md`, `docs/security.md`, `apple/README.md`, and
    `server/xmpp/README.md` with dated evidence only after every smoke above
    passes. Leave the checklist open and report the exact blocker otherwise.

## Acceptance Criteria

- DM video passes on two signed Apple devices with incoming CallKit/PushKit,
  answer, bidirectional audio/video, and reconnect behavior verified.
- Group voice passes with three accounts first and ten authenticated
  participants second.
- Forced TURN relay smoke proves media works when direct/non-relay candidates are
  not allowed.
- Call descriptors remain OMEMO-encrypted and product flows fail closed when a
  media key, OMEMO trust, or recipient membership check is missing.
- VoIP pushes contain only opaque call routing, not caller names, room names,
  LiveKit tokens, TURN credentials, media keys, or decrypted content.
- The log audit reports forbidden sensitive classes absent from app,
  call-control, push-gateway, LiveKit/coturn, and proxy logs.
- Documentation is updated only with exact dated smoke evidence and does not
  include secrets or screenshots that reveal tokens.

## Verification Commands

Run applicable build and unit checks after code or docs changes:

```bash
cargo test -p trix-call-control
cargo test -p trix-push
cargo test -p trix-push-gateway
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
bash -n server/xmpp/scripts/*.sh apple/scripts/*.sh
git diff --check
```

After collecting signed-device call logs, run:

```bash
server/xmpp/scripts/call-log-audit.sh /path/to/call-smoke-logs
```

Also report the signed-device smoke command chain, device/build identifiers,
participant counts, relay-only proof, and log-audit result. If signed devices,
LiveKit/coturn access, APNs VoIP credentials, or disposable account credentials
are unavailable, report that as the blocker and leave the checklist open.
