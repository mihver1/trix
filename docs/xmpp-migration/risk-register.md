# XMPP+OMEMO Risk Register

This register tracks remaining launch and security risks for the current XMPP
MVP. It was refreshed on 2026-06-01 against `docs/mvp-checklist.md`.

## Risk Levels

- High: can block launch or compromise security goals.
- Medium: can ship only with a documented limitation or extra operational work.
- Low: should be tracked but does not block the MVP alone.

## Risks

### Encrypted Calls Are Not Launch-Proven

Level: High

Risk: the checked-in call stack has LiveKit/coturn, call-control, OMEMO call
descriptors, CallKit/PushKit entrypoints, and signed macOS relay-only diagnostic
evidence, but the full signed-device launch gate has not passed.

Mitigation:

- Keep calls behind fail-closed OMEMO descriptor and membership gates.
- Require signed-device DM video with incoming CallKit/PushKit, answer,
  bidirectional audio/video, and reconnect.
- Require group voice with three accounts, then ten authenticated participants.
- Require forced TURN relay proof and `call-log-audit.sh` over app,
  call-control, push-gateway, LiveKit/coturn, proxy, and push logs.
- Do not count echo-assistant evidence as launch completion.

Owner: Apple implementation lead and server lead.

Status: Open.

### Apple OMEMO Library Is Not Production-Ready For Every Future Need

Level: High

Risk: Tigase Martin/MartinOMEMO is accepted for the private MVP, but it still
does not give Trix a reviewed server-side OMEMO backup/recovery path, reviewed
interactive SAS/cross-signing flow, or proven ecosystem interop.

Mitigation:

- Keep using reviewed MartinOMEMO/libsignal APIs only.
- Treat missing recovery as a documented product limitation, not a reason to
  move private key material manually.
- Keep signed two-device trust proof and any interop claims as separate gates.
- Keep the composer fail-closed when required trust or OMEMO state is missing.

Owner: Apple implementation lead.

Status: Mitigated for the private MVP; recovery, signed multi-device proof, and
interop remain open.

### Mature Apple OMEMO Paths Have GPL Or AGPL Obligations

Level: High

Risk: the selected native Apple route uses Tigase Martin/MartinOMEMO and related
GPL/AGPL-family dependencies. Private non-commercial use is acceptable for the
current friends app, but broader distribution still needs source/license
handling or a different license path.

Mitigation:

- Keep the SBOM/license report in `license-sbom.md` current.
- Do not copy Monal or Tigase OMEMO code into Trix without review.
- Before broader public or proprietary distribution, implement and review the
  source-availability and notice obligations, or select a different path.

Owner: Product lead and Apple implementation lead.

Status: Accepted for private MVP; broader distribution obligations remain
tracked.

### Group OMEMO Semantics Diverge From Product Expectations

Level: High

Risk: private encrypted group behavior can still surprise users around device
fan-out, membership changes, removed members, and history visibility.

Mitigation:

- Keep rooms members-only and non-anonymous.
- Block product sends unless the MUC recipient set and trusted active OMEMO
  devices are known.
- Preserve the local encrypted member cache only as display/continuity state,
  not an authorization source.
- Keep recovery/backfill limitations visible.

Owner: Apple implementation lead and server lead.

Status: Mitigated in part. Three-account encrypted group smoke, group
attachments, group restart overlap, and server-backed group leave have passed;
old-history recovery and broader multi-device behavior remain caveated.

### Federation Accidentally Becomes Reachable

Level: High

Risk: a config or deployment change could reopen server-to-server routing and
expand the abuse and trust surface beyond the private product scope.

Mitigation:

- Keep no `5269` listener in the checked-in ejabberd config.
- Keep `s2s_access: none`.
- Verify from outside the host that `5222` is reachable and `5269` is not.
- Avoid publishing server-to-server DNS records.

Owner: Server lead.

Status: Mitigated; repeat the external `5269` negative check after deployment
changes.

### Control Plane Duplicates Server Truth

Level: Medium

Risk: account, directory, profile, group, push, or feature-flag state can drift
if Trix stores server-owned facts in a second source of truth.

Mitigation:

- Use ejabberd/server APIs for server-owned account and group state.
- Keep app-facing invite, password, sticker, group-leave, and admin wrappers
  loopback/private and authenticated.
- Keep Trix-only state explicit: feature flags, audit events, local encrypted
  caches, and app settings.
- Add audit events for new mutating admin routes.

Owner: Control-plane lead.

Status: Mitigated in part. The local operator scripts, invite wrapper, and
`trix-admin-api` are in place; new operator surfaces must preserve the boundary.

### No Matrix Migration Surprises Users

Level: Medium

Risk: users may expect old Matrix rooms, history, devices, or recovery material
to appear in the XMPP service.

Mitigation:

- Keep docs explicit that Matrix migration and bridging are out of scope.
- Treat any launch/reset wording or export as a product communication task, not
  an engineering dependency for XMPP.

Owner: Product lead.

Status: Accepted. There are no live Matrix users to preserve.

### Notifications Leak Message Content

Level: High

Risk: push paths could leak plaintext message bodies, filenames, attachment
metadata, media keys, or token material through APNs payloads or logs.

Mitigation:

- Keep APNs payloads generic or silent sync only.
- Keep visible notification wording local and generic after sync.
- Keep `trix-push-gateway` private and rate-limited.
- Audit logs whenever push behavior changes.

Owner: Apple implementation lead and server lead.

Status: Mitigated for the current MVP. Signed macOS APNs proof passed with
generic text; live XMPP publishes now produce silent sync wakes. Keep iOS
physical-device proof as a platform follow-up if required.

### Attachment Metadata Exposes Too Much

Level: Medium

Risk: HTTP upload can expose media timing, approximate size, and server-side
storage metadata even when content is encrypted.

Mitigation:

- Upload only encrypted bytes.
- Keep original filename, MIME type, image dimensions, and media key material in
  the OMEMO-encrypted descriptor.
- Use generic upload filenames and `application/octet-stream`.
- Do not log decrypted bytes, filenames, local paths, media keys, or preview
  data.

Owner: Server lead and Apple implementation lead.

Status: Mitigated for the current MVP. Server retention/deletion policy remains
an operational follow-up.

### Multi-Device Behavior Is Hard To Explain

Level: Medium

Risk: OMEMO device lists, trust state, missed-device delivery, recovery limits,
and own-device revocation can confuse users if the app hides device state.

Mitigation:

- Keep account-device fingerprints visible through visual challenges and hidden
  technical disclosure.
- Require explicit manual trust.
- Keep own-device revocation clear that already delivered ciphertext cannot be
  removed.
- Keep scrubbed `second-device-fingerprint` and `own-device-revocation` smoke
  entrypoints for repeatable checks.

Owner: Apple implementation lead.

Status: Mitigated in part; signed-device two-device proof remains open.

### Server Backup Does Not Restore Crypto-Critical State

Level: High

Risk: backup and restore may miss account, archive, pubsub device bundle, upload,
or control-plane state. Even correct server restore does not solve client-side
OMEMO private state recovery.

Mitigation:

- Use ejabberd-native Mnesia backup/restore for account state.
- Include upload storage in restore drills.
- Run `server/xmpp/scripts/restore-verify.sh` after backup changes.
- Keep client-side OMEMO recovery limitations visible.

Owner: Server lead.

Status: Mitigated for current server state by the restore verifier; production
schedule and periodic proof remain operational work.

### Feature Parity Scope Expands Without Gates

Level: Medium

Risk: the XMPP pivot can stall if every useful messenger feature is treated as
launch-blocking without owner, priority, or proof.

Mitigation:

- Use `docs/mvp-checklist.md` as the launch ledger.
- Use `parity-checklist.md` as product parity, not as a promise that all XEPs
  are launch blockers.
- Keep encrypted calls, signed multi-device trust proof, and recovery/backfill
  separate from lower-risk QoL work such as drafts, search, export, and pins.

Owner: Product lead.

Status: Mitigated in part.
