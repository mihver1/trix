# MVP Closeout Section 1

This file validates the first auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These items are valid MVP closeout work, not speculative feature expansion:

- APNs wake-only signed-device smoke is still open. The gateway, app token
  capture, and wake-only app handler exist, but `docs/mvp-checklist.md` keeps
  APNs open until a signed device proves wake delivery with no plaintext payload
  fields.
- Server-backed group leave is still open. The timeline UI currently says the
  checked-in action is local-only, and `TrixRoomMembershipService` has add,
  remove, and list operations but no server-backed leave operation.
- Full signed-app quit/relaunch timeline smoke is still open. The current
  `timeline-restart` mode proves a fresh `XMPPMartinService` restore inside one
  process, not a real app process quit and relaunch.
- Second-device fingerprint smoke is still open. Settings and peer-device
  discovery surfaces are wired, but the checklist still requires a live
  two-device validation.
- Persistent tests around encrypted DM/group sync are still open. The repo has
  credentialed live smoke modes, but no repeatable persistent DM plus group sync
  test gate.

One other MVP checkbox is open but is not part of this batch:

- `Backfill older sender-side OMEMO self-history from MAM after restart` is a
  recovery/key-backup blocker. Do not mix it into the five closeout tasks below,
  and do not add custom key recovery or custom crypto to make it pass.

## Suggested Order

1. `2026-05-15-apns-wake-only-signed-device-smoke.md`
2. `2026-05-15-server-backed-group-leave.md`
3. `2026-05-15-persistent-dm-group-sync-tests.md`
4. `2026-05-15-signed-app-quit-relaunch-timeline-smoke.md`
5. `2026-05-15-second-device-fingerprint-smoke.md`

APNs and second-device validation require real signed-device state. If that
state is unavailable, the agent should leave a precise blocker with the missing
device/account/certificate condition instead of marking the checklist complete.

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
