# MVP Closeout Section 1

This file validates the first auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These items were valid MVP closeout work, not speculative feature expansion.
Current state:

- APNs generic signed-device smoke is closed for the current MVP. On
  2026-05-20 signed macOS APNs smoke passed with generic visible text and no
  plaintext payload fields, and later live XMPP component publishes were wired
  to silent sync wakes.
- Server-backed group leave is closed. The Apple timeline calls the Trix
  control-plane leave path before local MUC leave, and the hosted three-account
  `group-leave` smoke passed on 2026-05-21.
- Full signed-app quit/relaunch timeline smoke is closed. The signed macOS
  persistent gate ran `timeline-relaunch-seed` and `timeline-relaunch-verify`
  in separate processes on 2026-05-20.
- Persistent tests around encrypted DM/group sync are closed. The signed macOS
  persistent gate covers DM restart overlap and encrypted group MUC restart
  overlap.
- Second-device fingerprint smoke remains open for real signed-device proof.
  The isolated local-profile smoke proves distinct OMEMO device IDs and no
  silent trust, but `docs/mvp-checklist.md` still requires signed two-device
  validation.

One other MVP checkbox is open but is not part of this batch:

- `Backfill older sender-side OMEMO self-history from MAM after restart` is a
  recovery/key-backup blocker. Do not mix it into this closeout batch,
  and do not add custom key recovery or custom crypto to make it pass.

## Suggested Order

1. Keep `2026-05-15-second-device-fingerprint-smoke.md` open until signed
   two-device evidence exists.
2. Do not reopen APNs, group leave, persistent sync, or signed relaunch unless
   new regressions appear.
3. Keep the separate older sender-side self-history blocker out of this batch.

Second-device validation requires real signed-device state. If that state is
unavailable, leave a precise blocker with the missing device/account/certificate
condition instead of marking the checklist complete.

## Global Constraints For All Prompts

- Start by reading `AGENTS.md`, `docs/mvp-checklist.md`, `docs/security.md`,
  `apple/README.md`, and the task-specific files listed in each prompt.
- Run `git status --short` before editing and do not revert unrelated changes.
- Keep XMPP/OMEMO calls behind service and view-model boundaries.
- Do not weaken OMEMO gates or add plaintext fallback.
- Do not log passwords, APNs tokens, APNs keys, OMEMO secrets, private keys,
  decrypted message bodies, filenames from encrypted attachments, media keys, or
  full trust secrets.
- Live smoke output must stay scrubbed status lines only.
- Update `docs/mvp-checklist.md` only after the requested proof exists. If a
  task is blocked, document the blocker instead of checking the box.
