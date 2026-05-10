# XMPP+OMEMO Risk Register

## Risk Levels

- High: can block launch or compromise security goals.
- Medium: can ship only with a documented limitation or extra operational work.
- Low: should be tracked but does not block the MVP alone.

## Risks

### Apple OMEMO Library Is Not Production-Ready

Level: High

Risk: available Apple XMPP libraries may not provide maintained, complete OMEMO
support for both iOS and macOS.

Mitigation:

- Treat Apple OMEMO selection as a spike gate.
- Require two-account DM and three-account group prototypes.
- Reject any path that requires custom crypto or manual key manipulation.

Owner: Apple implementation lead.

Status: Open.

### Mature Apple OMEMO Paths Have GPL Or AGPL Obligations

Level: High

Risk: the most complete native Apple OMEMO routes currently involve Tigase
Martin/MartinOMEMO, SignalProtocol-ObjC, or Monal-derived code paths with GPL or
AGPL obligations. Trix is non-commercial and private, so this is likely more
acceptable than for a closed commercial app, but it still needs an explicit
source-distribution and App Store/TestFlight decision.

Mitigation:

- Keep the SBOM/license report in `license-sbom.md` current for the selected
  Apple stack.
- GPL/AGPL obligations are accepted for the non-commercial private friends MVP;
  broader distribution still needs source/license handling or a separate
  commercial/permissive license path.
- Do not copy Monal or Tigase OMEMO code into Trix without legal review.

Owner: Product lead and Apple implementation lead.

Status: Accepted for private MVP; distribution obligations remain tracked.

### Group OMEMO Semantics Do Not Match Product Needs

Level: High

Risk: private encrypted group behavior may differ from Matrix encrypted rooms or
legacy expectations, especially around membership changes, device fan-out, and
history visibility.

Mitigation:

- Prototype three-account groups before building production UI.
- Document membership-change behavior.
- Block plaintext fallback.

Owner: Apple implementation lead and server lead.

Status: Open.

### Federation Accidentally Remains Enabled

Level: High

Risk: a default XMPP server configuration may accept or attempt federated
routing, expanding the operational and abuse surface.

Mitigation:

- Add federation-disabled checks to server verification.
- Document production config explicitly.
- Include a negative remote-domain routing test or config inspection step.

Owner: Server lead.

Status: Open.

### Control Plane Duplicates Server Truth

Level: Medium

Risk: the Trix control plane can drift from XMPP server state if account,
roster, group, or profile data is stored in two places without a clear owner.

Mitigation:

- Define ownership per field before implementation.
- Use server APIs for server-owned state.
- Keep Trix-only metadata in a documented Trix store.

Owner: Control-plane lead.

Status: Open.

### No Matrix Migration Surprises Users

Level: Medium

Risk: users may expect existing Matrix rooms, history, devices, or recovery
state to appear in the XMPP service.

Mitigation:

- State clearly that there is no Matrix data migration and no Matrix bridge.
- Provide a launch/reset message.
- Decide separately whether old local history is view-only, exported, or
  ignored.

Owner: Product lead.

Status: Open.

### Notifications Leak Message Content

Level: High

Risk: a push path may expose plaintext message bodies through server-side push
payloads or logs.

Mitigation:

- Require notification spike before launch readiness.
- Prefer payloads that carry only routing/count metadata.
- Decrypt for local notification display only on device, if supported.
- Audit logs during smoke tests.

Owner: Apple implementation lead.

Status: Open.

### Attachment Metadata Exposes Too Much

Level: Medium

Risk: XMPP upload services may expose filenames, media types, sizes, or URLs
outside the encrypted message body.

Mitigation:

- Document accepted metadata exposure.
- Send sensitive attachment context only inside encrypted messages.
- Validate server retention and deletion behavior.

Owner: Server lead and Apple implementation lead.

Status: Open.

### Multi-Device Behavior Is Hard To Explain

Level: Medium

Risk: OMEMO device lists, trust state, and missed-device delivery can create
confusing UX if the app hides device state.

Mitigation:

- Expose encryption/device blocked states clearly.
- Include multi-device in the spike checklist.
- Avoid silent trust-all behavior as a finished UX.

Owner: Apple implementation lead.

Status: Open.

### Server Backup Does Not Restore Crypto-Critical State

Level: High

Risk: backup and restore may miss server-side state needed for accounts,
archives, pubsub device bundles, uploads, or control-plane metadata.

Mitigation:

- Run restore drills before launch.
- Include accounts, archives, upload storage, pubsub data, and Trix metadata in
  the backup inventory.
- Validate login and encrypted message sync after restore.

Owner: Server lead.

Status: Open.

### Feature Parity Scope Expands Without Gates

Level: Medium

Risk: the pivot can stall if every legacy edge case is treated as launch
blocking without owner, priority, or verification.

Mitigation:

- Use `parity-checklist.md` as the parity ledger.
- Mark deferrals explicitly with owner and reason.
- Keep launch-critical encryption, account, DM, group, and restore behavior
  separate from lower-priority polish.

Owner: Product lead.

Status: Open.
