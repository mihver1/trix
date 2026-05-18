# Client Quality Of Life Section 5

This file validates the fifth auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These are good product-quality items, but they sit on different risk surfaces:

- Local search over decrypted history is valid and valuable. It must search only
  locally decrypted/cacheable content and must not trigger XMPP MAM, directory, or
  server-side search requests.
- User history export is valid but security-sensitive. It intentionally creates
  plaintext output, so it needs explicit user confirmation, OS save/share
  controls, and clear warnings.
- Rich inline previews are valid for encrypted attachments and links, but remote
  URL/Open Graph fetches reveal user/network metadata to third-party sites. Link
  previews must stay opt-in.
- Persistent drafts are low-risk if stored as local encrypted app state and never
  sent as typing/message state on restore.
- Notes-to-self is a useful private-messenger pattern, but it depends on the
  self-JID OMEMO path working as a real encrypted DM. Do not special-case it into
  plaintext or local-only messages.
- Per-room mute/notification profiles fit the current generic APNs model. They
  should filter local notification presentation after sync, not change push
  payload contents or unread semantics.

## Suggested Order

1. `2026-05-15-persistent-composer-drafts.md`
2. `2026-05-15-per-room-notification-profiles.md`
3. `2026-05-15-local-decrypted-history-search.md`
4. `2026-05-15-notes-to-self-chat.md`
5. `2026-05-15-user-history-export.md`
6. `2026-05-15-rich-inline-previews.md`

Drafts are first because they are narrow and independent. Notification profiles
come early because they extend the current inactive notification work. Local
search should land before export so both features can share the same cache and
room-manifest decisions. Rich previews are last because they combine attachment
decrypt, media thumbnailing, and consent-gated network fetches.

## Global Constraints For All Prompts

- Start by reading `AGENTS.md`, `docs/security.md`, `docs/mvp-checklist.md`,
  `apple/README.md`, and the task-specific files listed in each prompt.
- Run `git status --short` before editing and do not revert unrelated changes.
- Keep XMPP and OMEMO calls behind service and view-model boundaries.
- Do not weaken mandatory OMEMO, add plaintext fallback, or add custom crypto.
- Treat message bodies, drafts, search terms/results, export contents, attachment
  filenames, media thumbnails, link URLs, and notification profile data as
  sensitive local data.
- Do not log decrypted message text, drafts, export contents, search queries,
  attachment filenames, local file paths, media keys, preview bytes, link URLs, or
  notification profile settings.
- APNs payloads must remain generic and plaintext-free. Client QoL features may
  use local decrypted state after sync, but remote payloads must not carry message
  bodies, filenames, URLs, or mention text.
- Any feature that creates plaintext output or reaches a third-party URL needs a
  visible, explicit user action.
