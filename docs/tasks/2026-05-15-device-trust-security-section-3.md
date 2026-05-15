# Device Trust And Security Section 3

This file validates the third auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These items are worth keeping, but they have different risk levels:

- Visual device verification is valid and should replace raw manual fingerprint
  comparison as the primary UX. Prefer a short human-checkable phrase, 4-5
  emoji-style symbols with labels, or a deterministic visual card over QR as
  the main path. Do not invent a new cryptographic verification protocol.
- Device revocation is valid and high value. It must remove or deactivate an
  own OMEMO device through MartinOMEMO/server-supported APIs, then keep sends
  blocked for revoked/untrusted devices.
- OMEMO key backup and recovery is the highest-risk item. Treat it as a
  research-and-decision task first. If MartinOMEMO/libsignal does not expose a
  reviewed path that fits Trix, document the blocker and leave recovery disabled.
- Local app lock is valid as local device-loss hardening. It is an access gate,
  not E2EE or secure backup.
- Ephemeral messages are useful but should be framed as disappearing messages,
  not guaranteed destruction. Pair local expiration with XEP-0424 retraction and
  document limits.
- iOS screenshot/screen-recording detection is valid as an indicator only.
  Screenshot notifications arrive after the screenshot and cannot block capture.

## Suggested Order

1. `2026-05-15-reviewed-omemo-key-backup-recovery.md`
2. `2026-05-15-visual-sas-device-verification.md`
3. `2026-05-15-omemo-device-revocation-ux.md`
4. `2026-05-15-local-app-lock-biometrics-passcode.md`
5. `2026-05-15-ephemeral-self-destruct-messages.md`
6. `2026-05-15-ios-screenshot-screen-recording-indicator.md`

Recovery research comes first because it decides whether any account recovery UI
can be honest. Visual verification and revocation then close the most important
trust gaps. App lock is a contained Apple-platform hardening slice. Ephemeral
messages and screenshot indicators are product polish with clear security caveats.

## Global Constraints For All Prompts

- Start by reading `AGENTS.md`, `docs/security.md`,
  `docs/xmpp-migration/spike-checklist.md`,
  `docs/xmpp-migration/risk-register.md`, `apple/README.md`, and the
  task-specific files listed in each prompt.
- Run `git status --short` before editing and do not revert unrelated changes.
- Keep XMPP, OMEMO, libsignal, and LocalAuthentication calls behind service and
  view-model boundaries.
- Do not weaken mandatory OMEMO or add plaintext fallback.
- Do not implement custom cryptography, custom key exchange, custom OMEMO backup
  wrapping, or manual private-key movement.
- Do not silently trust devices. Trust changes must be explicit and visible.
- Do not log passwords, APNs tokens, OMEMO secrets, private keys, recovery
  material, device trust secrets, decrypted bodies, media keys, local decrypted
  file paths, or screenshots.
- Treat device ids, fingerprint-derived metadata, verification request ids,
  retraction targets, screenshot events, and timer metadata as server-visible
  unless proven encrypted.
- Live smoke output must stay scrubbed status lines only.

## External References

- MartinOMEMO package source:
  https://github.com/tigase/MartinOMEMO
- MartinOMEMO mirror/README:
  https://tigase.dev/tigase/_libraries/MartinOMEMO
- XEP-0384 OMEMO Encryption:
  https://xmpp.org/extensions/xep-0384.html
- XEP-0424 Message Retraction:
  https://xmpp.org/extensions/xep-0424.html
- Apple LocalAuthentication overview:
  https://developer.apple.com/documentation/localauthentication/
- Apple screenshot notification:
  https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification
- Apple `UIScreen.isCaptured`:
  https://developer.apple.com/documentation/uikit/uiscreen/2921651-iscaptured
