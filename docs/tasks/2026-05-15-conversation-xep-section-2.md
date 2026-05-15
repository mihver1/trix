# Conversation XEP Section 2

This file validates the second auditor batch and points the next agents at
bounded prompts under `docs/tasks/`.

## Validation

These items are worth keeping, but they should not all be treated as equal MVP
work:

- Reply / quoting with XEP-0461 is valid and fits the current timeline. Treat it
  as a quote-reply UX with local preview. Do not leak quoted plaintext outside
  OMEMO.
- Edit / retract with XEP-0308 and XEP-0424 is valid for own messages. Treat
  edit content as encrypted replacement content and retraction as a tombstone,
  not a guaranteed server-side erase.
- Voice messages are valid as encrypted attachments, not a new protocol. Use the
  existing OMEMO attachment path and keep waveform data local or inside the
  encrypted descriptor.
- Mentions with XEP-0372 are valid but experimental and metadata-visible. Strong
  local notification handling must still keep APNs wake-only and plaintext-free.
- Server-side chat markers with XEP-0333 are valid for displayed/read markers,
  but do not rely on XEP-0333 alone as a complete same-account multi-device read
  cursor. Pair it with archived marker processing or a Trix-owned cursor if
  needed.
- Pinned messages via XEP-0402 are only partially validated. XEP-0402 is native
  bookmarks; it can support per-account pinned-message state as bookmark
  extension data, but it is not a shared MUC pin standard by itself.
- Threaded replies with XEP-0201 are separate from XEP-0461 quote replies. Keep
  them later than quote replies unless the product explicitly wants thread
  navigation in group chats.

## Suggested Order

1. `2026-05-15-xep-0333-chat-markers-read-sync.md`
2. `2026-05-15-xep-0461-reply-quoting.md`
3. `2026-05-15-xep-0308-0424-edit-retract.md`
4. `2026-05-15-encrypted-voice-messages.md`
5. `2026-05-15-xep-0372-mentions.md`
6. `2026-05-15-muc-pinned-messages-bookmarks.md`
7. `2026-05-15-xep-0201-threaded-replies.md`

The read-marker task comes first because it improves unread correctness and
multi-device behavior. Quote replies should land before threaded replies so the
timeline gets a simple reference model before thread navigation is introduced.

## Global Constraints For All Prompts

- Start by reading `AGENTS.md`, `docs/security.md`,
  `docs/xmpp-migration/protocol-feature-map.md`, `apple/README.md`, and the
  task-specific files listed in each prompt.
- Run `git status --short` before editing and do not revert unrelated changes.
- Keep XMPP and OMEMO calls behind service and view-model boundaries.
- Do not weaken mandatory OMEMO or add plaintext fallback.
- Treat message body content, quote previews, edit replacement text, voice
  media, attachment filenames, media keys, and decrypted bodies as encrypted
  content.
- Treat XMPP reference/edit/retract/marker/thread metadata as server-visible and
  document that in `docs/security.md` when implementing.
- Live smoke output must stay scrubbed status lines only.

## Standards References

- XEP-0461 Message Replies: https://xmpp.org/extensions/xep-0461.html
- XEP-0308 Last Message Correction: https://xmpp.org/extensions/xep-0308.html
- XEP-0424 Message Retraction: https://xmpp.org/extensions/xep-0424.html
- XEP-0372 References: https://xmpp.org/extensions/xep-0372.html
- XEP-0333 Chat Markers: https://xmpp.org/extensions/xep-0333.html
- XEP-0402 PEP Native Bookmarks: https://xmpp.org/extensions/xep-0402.html
- XEP-0201 Best Practices for Message Threads:
  https://xmpp.org/extensions/xep-0201.html
