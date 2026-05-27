# Task: Live Encrypted Call Echo Assistant

You are the next coding agent working in the Trix repo. Add a disposable
call-test assistant for `trix.selfhost.ru` that helps a single tester validate
encrypted call media without weakening the real signed-device launch gate.

## Current Context

Relevant files:

- `docs/mvp-checklist.md`
- `docs/security.md`
- `docs/tasks/2026-05-19-encrypted-call-smoke-tests.md`
- `docs/tasks/2026-05-20-disposable-call-smoke-credentials.md`
- `apple/README.md`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`
- `apple/Sources/Shared/Services/TrixCallServices.swift`
- `apple/Sources/Shared/ViewModels/TrixCallViewModel.swift`
- `server/xmpp/README.md`
- `server/xmpp/scripts/call-log-audit.sh`

The current call stack keeps XMPP/OMEMO as the call-control and key-distribution
plane. LiveKit only routes media. Apple call descriptors carry call intent and
media keys through OMEMO-encrypted messages, and product flows fail closed when
recipient membership, device trust, or media key setup is missing.

`group-call-lab-media` already validates a two-client media window with
relay-only ICE and an audio probe. It does not echo audio/video back to the
tester.

## Goal

Add a repeatable live call echo assistant for disposable smoke rooms on
`trix.selfhost.ru`.

The preferred shape is a normal test client participant:

- sign in as a disposable XMPP account such as `tri21echo@trix.selfhost.ru`;
- enter only disposable DM/group smoke rooms;
- obtain call descriptors and media keys only through the existing OMEMO path;
- join LiveKit as a normal participant with the same E2EE setup as Apple clients;
- subscribe to remote media and publish a delayed echo when the pinned SDK path
  supports it;
- emit only scrubbed status lines and log-auditable evidence.

## Current Implementation Status

This slice adds the first `call-echo-assistant` Apple live smoke mode. It signs
in the echo account as a normal XMPP/OMEMO participant, creates a disposable
private group room with owner, peer, and echo accounts, performs the existing
smoke-only OMEMO trust setup, then drives owner and echo through the normal
relay-only group-voice join path. The owner publishes local audio through the
regular LiveKit path; the echo account is configured to join with the
remote-audio probe enabled and report only scrubbed status lines.

The mode can be run through
`apple/scripts/run-live-call-echo-assistant-macos.sh evidence`, which builds the
signed macOS smoke app if needed, captures `apple-smoke.log` plus sanitized Apple
OSLog output under `apple/build/LiveCallEchoEvidence/`, and runs
`server/xmpp/scripts/call-log-audit.sh` on the bundle.

The mode is intentionally not a completed delayed echo implementation yet. It
prints `delayed_audio_echo=false` and `delayed_video_echo=false` until reviewed
SDK paths for delayed local publication are added.

## 2026-05-25 Live Result

Live evidence bundle:
`apple/build/LiveCallEchoEvidence/20260525T195243Z`

The signed macOS wrapper loaded the owner credential from the local
`dev-credentials.txt`, provisioned fresh disposable peer and echo accounts
through `/v1/invites` plus `/v1/registration/redeem`, and verified both accounts
with call-control auth and XMPP login before running the echo assistant. The
first assistant attempt reached the useful live stage:

- owner, peer, and echo XMPP login succeeded;
- encrypted disposable MUC creation succeeded;
- peer and echo invites and joins succeeded;
- owner, peer, and echo all observed three joined members;
- six explicit smoke-only OMEMO trust checks passed;
- relay-only media was requested with owner audio publish enabled and echo audio
  probe enabled.

The media leg is still blocked. The owner LiveKit connect failed before an
active call:

```text
LiveKit media connect failed domain=io.livekit.swift-sdk code=100 description=Cancelled
```

The wrapper retried the smoke run with the same disposable credentials after the
first media failure. Later attempts hit intermittent XMPP connect failures before
media. `call-log-audit.sh` passed on the bundle and found no forbidden secret or
decrypted-content classes in the captured files.

## 2026-05-26 Forced-Relay Diagnosis

Comparison evidence bundles:

- `apple/build/LiveCallEchoEvidence/group-compare-20260526T161957Z`
- `apple/build/LiveCallEchoEvidence/sdk-debug-group-20260526T162734Z`

The deterministic `group-call-lab-media` live path failed with the same
`LiveKit media connect failed domain=io.livekit.swift-sdk code=100
description=Cancelled` error, so the blocker is not echo-assistant-specific and
is not caused by owner microphone publication. Public preflight still showed C2S
reachable, S2S unavailable, TURN ports reachable, the call-control app routes
auth-gated, and the raw LiveKit port closed externally. A token-scoped probe then
validated the call token through `/rtc/validate` and completed a raw LiveKit
WebSocket upgrade without printing the token.

With `TRIX_CALL_LIVEKIT_DEBUG_LOGS=1`, Apple OSLog showed the SDK receiving the
LiveKit join response, gathering relay candidates, and completing TURN allocation
over `trix.selfhost.ru:3478`. The first hard media failure was coturn rejecting
`CreatePermission` for the LiveKit media peer with `403`; after that the
subscriber ICE transport failed and the SDK cleaned up with `Cancelled`. Treat
the fix as server-side coturn/LiveKit address policy:

- set deployment-local `external-ip=<public-ip>/<coturn-container-ip>` in the
  uncommitted live `turnserver.conf` when coturn is behind Docker or host NAT;
- avoid Docker hairpin relay from coturn back to LiveKit's host public IP by
  configuring the uncommitted live `livekit.yaml` with
  `rtc.use_external_ip: false` and `rtc.node_ip: <livekit-container-ip>`;
- allow only that Docker-private LiveKit media peer in coturn with
  `allowed-peer-ip=<livekit-container-ip>`;
- restart coturn/LiveKit and rerun forced-relay smoke plus `call-log-audit.sh`.

Do not add real IPs, TURN shared secrets, LiveKit tokens, or account passwords to
this repo.

After switching SSH to the Bitwarden agent, the live host was updated with this
Docker-private relay path and the temporary `server-relay`/`verbose` coturn
debug options were removed. Evidence bundle:
`apple/build/LiveCallEchoEvidence/post-livekit-private-node-20260526T204403Z`.
The smoke passed:

- owner, peer, and echo XMPP login succeeded;
- encrypted disposable MUC create/invite/join and three-member visibility
  succeeded;
- six smoke-only OMEMO trust checks passed;
- owner and echo both joined the LiveKit room with relay-only ICE;
- SDK debug logs showed `Create permission for 172.29.0.x` succeeded, selected
  relay candidate pairs to the LiveKit Docker-private media peer, and both
  publisher/subscriber transports connected;
- `call-log-audit.sh` passed with forbidden secret classes absent.

This closes only the echo-assistant diagnostic slice. Delayed audio/video echo
still reports `false`, and the signed-device encrypted-calls MVP launch gate
remains open. The passing evidence uses UDP TURN on `3478`. A follow-up check
found coturn's TLS key unreadable by the container user; the live key ownership
was corrected for both ejabberd and coturn because ejabberd reads `certs/*.pem`,
coturn was restarted, and `turns:trix.selfhost.ru:5349` was reachable again.

## Non-Goals

- Do not implement a privileged server-side bot that receives media keys outside
  OMEMO.
- Do not expose LiveKit admin APIs, TURN credentials, call-control internals, or
  XMPP credentials to the bot.
- Do not count echo-assistant proof as launch completion. The encrypted-calls
  MVP still requires real signed-device DM video, group voice with three and ten
  authenticated participants, forced TURN relay, and log audit.
- Do not print, store, or commit LiveKit tokens, TURN credentials, media keys,
  XMPP passwords, APNs tokens, OMEMO secrets, fingerprints, raw audio/video, or
  decrypted content.
- Do not let the assistant join ordinary private chats or reuse production user
  accounts.

## Implementation Plan

1. Start with a small live smoke mode, for example `call-echo-assistant`, inside
   the Apple smoke runner. Use the existing `XMPPMartinService`,
   `TrixCallViewModel`, `HTTPCallControlService`, and `TrixLiveKitMediaCallService`
   boundaries. This initial group-voice participant/probe mode is now wired.
2. Add explicit environment variables for the echo account rather than reusing
   normal users silently:
   - `TRIX_XMPP_LIVE_SMOKE_ECHO_ID`
   - `TRIX_XMPP_LIVE_SMOKE_ECHO_PASSWORD`
   - optional `TRIX_XMPP_LIVE_SMOKE_ECHO_DELAY_SECONDS`
3. Provision the echo account only through operator-controlled disposable account
   flows. Keep credential files outside the repo with `0600` permissions.
4. For group voice:
   - create or reuse a private members-only MUC;
   - invite the human smoke account, one peer account, and the echo account;
   - perform explicit OMEMO trust setup through the existing smoke-only trust
     gates;
   - have the echo account join the voice room as a normal participant.
5. For direct video:
   - use the echo account as the callee in a disposable DM;
   - auto-accept the incoming direct call only in smoke mode;
   - publish video only if the local runner has camera or a reviewed synthetic
     video source.
6. Implement delayed video echo only if it can use a supported public LiveKit
   Swift API. The pinned LiveKit Swift `2.9.0` exposes `BufferCapturer` for
   publishing custom video frames, so a future pass can attach a remote
   `VideoRenderer`, delay frames, and recapture them into a local buffer track.
7. Implement delayed audio echo only after a reviewed path exists for publishing
   generated or replayed PCM audio from the Apple client. The pinned LiveKit
   Swift `2.9.0` exposes remote `AudioRenderer` hooks, but the public local audio
   track surface is microphone-oriented; do not fake audio echo by bypassing the
   media-key model or relying on server-side decrypted media.
8. Update `apple/README.md`, `server/xmpp/README.md`, and the encrypted-calls
   task with the exact command and limitations. Documentation must state that
   echo-assistant output is diagnostic-only.

## Acceptance Criteria

- Echo assistant joins only disposable call smoke rooms on `trix.selfhost.ru` or
  the loopback local lab.
- The assistant authenticates as a normal XMPP account and receives media keys
  only through OMEMO-encrypted call descriptors.
- Group voice assistant mode proves the echo account can join the LiveKit room
  as a normal E2EE participant.
- If delayed video echo is implemented, the tester sees the delayed returned
  video stream and the evidence reports only frame counts/readiness, not frame
  content.
- If delayed audio echo is implemented, the tester hears delayed returned audio
  and the evidence reports only frame counts/readiness, not audio samples.
- If either media echo layer is blocked by SDK surface, the smoke prints an
  explicit scrubbed blocker and still leaves encrypted calls open.
- `server/xmpp/scripts/call-log-audit.sh` passes on any captured evidence bundle.
- The signed-device encrypted-calls launch gate remains unchanged.

## Verification Commands

Run after code or docs changes:

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
bash -n apple/scripts/*.sh server/xmpp/scripts/*.sh
git diff --check
```

Live wrapper shape check:

```bash
apple/scripts/run-live-call-echo-assistant-macos.sh --help
```

Live verification must use disposable accounts only. Report the command chain,
assistant account localpart, participant counts, relay-only setting, echo media
status, and log-audit result without printing secrets.
