# XMPP Product Parity Checklist

This checklist tracks XMPP+OMEMO parity against the current Apple and server
implementation. It was refreshed against `docs/mvp-checklist.md` on
2026-06-01.

A checked item means the behavior is implemented and has either direct smoke
evidence or is covered by a documented MVP closeout path. Unchecked items are
still missing, not separately proven, or intentionally deferred.

## Current Blockers

- Encrypted calls are not launch-complete until signed-device DM video, group
  voice, forced TURN relay, ten-participant group voice, and log audit pass.
- Signed two-device trust proof is still open. Isolated local-profile smoke
  proves distinct OMEMO devices and no silent trust, but not the real signed
  two-device path.
- Old sender-side OMEMO self-history cannot be backfilled from MAM when archived
  stanzas were not encrypted for the current device. Do not work around this
  with custom key recovery.
- Server-side OMEMO key backup/recovery remains disabled until a reviewed
  MartinOMEMO/libsignal path exists.
- iOS physical-device APNs delivery is not called out as separate dated evidence
  here; signed macOS APNs proof and shared iOS/macOS plumbing are in place.

## Account And Session

- [x] Operator-created account can log in on iOS.
- [x] Operator-created account can log in on macOS.
- [x] Logout clears saved XMPP login state while preserving local OMEMO
      identity/trust state unless app Keychain data is reset.
- [x] App relaunch restores a valid session without retyping the password.
- [x] Disabled account cannot establish a new session through the operator
      `ban_account` flow.
- [ ] UI shows an independently verified account-disabled state.
- [x] Credentials, tokens, and encrypted-store secrets are absent from documented
      smoke output paths.

Definition of done:

- Session material is stored in Keychain or another approved secure store.
- Account lifecycle is controlled by the Trix control plane, not public
  self-registration.

## Inbox And Navigation

- [x] Room list shows DMs.
- [x] Room list shows groups.
- [x] Room list shows pending invitations.
- [x] User can accept an invitation.
- [x] User can decline an invitation.
- [x] Last message, timestamp, unread state, and sender summary are visible.
- [x] App restart reloads room summaries and selected timeline state where
      appropriate.
- [x] iOS navigation matches the compact messenger shape expected for Trix.
- [x] macOS navigation supports the desktop workflows expected for Trix.

Definition of done:

- Room discovery comes from live XMPP sync/archive state and Trix control-plane
  metadata where needed, not hard-coded local fixtures.

## Mandatory OMEMO

- [x] DM creation requires OMEMO.
- [x] Group creation requires OMEMO.
- [x] Text send requires an encrypted conversation.
- [x] Attachment send requires an encrypted conversation.
- [x] Missing OMEMO support blocks send with a visible reason.
- [x] Untrusted or unavailable participant device state blocks according to the
      documented trust policy.
- [x] Server-side stored message bodies are encrypted.
- [x] No production path logs decrypted message bodies in the documented smoke
      lanes.

Definition of done:

- There is no plaintext fallback for DMs or groups.
- OMEMO behavior uses the selected library APIs rather than custom key handling.

## Direct Messages

- [x] Create a DM from directory/search result.
- [x] Open an existing DM.
- [x] Send text.
- [x] Receive text.
- [x] Show sender, timestamp, and delivery state.
- [x] Restart the app and reload history for messages encrypted to the current
      device.
- [ ] Multi-device delivery works for the same user on real signed devices.
- [ ] Duplicate one-to-one conversations are prevented or merged by an
      explicitly documented smoke case.

Definition of done:

- Two-account encrypted DM smoke passes on iOS and macOS.

## Groups

- [x] Create a private group with at least three accounts.
- [x] Invite members.
- [x] Accept group invite.
- [x] Decline group invite.
- [x] Add member after creation.
- [x] Remove member where supported.
- [x] Leave group through the server-backed control-plane path.
- [x] Show group title and member list.
- [x] Send and receive encrypted text from multiple participants.
- [x] Restart the app and reload group history for decryptable group stanzas.

Definition of done:

- Three-account encrypted group smoke passes and stores no plaintext bodies on
  the server.

## Attachments And Media

- [x] Send image attachment.
- [x] Send file attachment.
- [x] Download received attachment.
- [x] Preview image in app.
- [x] Open, share, or export file through OS controls after local decrypt.
- [x] Attachment metadata does not expose plaintext message content beyond the
      accepted server-side upload metadata policy.
- [x] Attachment retry and failure states are visible.

Definition of done:

- Attachment bytes round-trip through the selected XMPP upload path, and
  message references to the attachment are sent only inside encrypted messages.

## Conversation UX

- [x] Composer sends on expected keyboard/action behavior.
- [x] Timeline shows outgoing, incoming, failed, blocked, and pending states.
- [x] Reactions are wired through the model/service/view-model/UI and
      Martin-backed XEP-0444 path; credentialed `dm-reaction` remains a focused
      live follow-up.
- [x] Read status is supported through local unread handling and the private
      Trix read cursor; peer-visible XEP-0333 observation remains best effort.
- [x] Delivery status is supported through XMPP delivery receipts.
- [x] Typing/composing indicators are supported for DMs.
- [ ] Offline send behavior is fully documented and verified as a product flow.
- [x] Retry behavior is visible for failed attachment/download paths.

Definition of done:

- User-visible conversation state is understandable even where XMPP extensions
  differ from prior prototypes.

## Directory, Profile, And Settings

- [x] Search for users available to Trix.
- [x] Start DM from a directory result.
- [x] Select group invitees from directory results.
- [x] View own profile.
- [x] Edit Trix-owned profile metadata.
- [x] View useful participant profile metadata.
- [x] Show device/encryption state.
- [x] Show server/account state.

Definition of done:

- Public or semi-public profile fields are intentionally chosen and documented.
- Trix-specific metadata is owned through the control plane or documented XMPP
  storage, not an accidental server default.

## Notifications

- [x] Foreground updates appear without manual refresh.
- [ ] Background notifications have separate dated signed iOS device proof.
- [x] Background notifications work on signed macOS with generic APNs text.
- [x] Notification payloads do not contain decrypted message bodies, filenames,
      media keys, or attachment metadata in the documented live proof.
- [x] Badge/unread state is local and sync-driven, not plaintext push content.

Definition of done:

- APNs or other notification delivery is validated without leaking plaintext
  message content through server-side push payloads.

## Operations And Admin

- [x] Create account through Trix control plane.
- [x] Disable account through Trix control plane.
- [x] Rotate invite or bootstrap credential through the invite/control wrapper.
- [ ] Inspect group membership through an operator control-plane view.
- [x] Inspect server health.
- [x] Confirm backup status.
- [x] Restore from backup.
- [x] Produce redacted diagnostics for support/operator use.

Definition of done:

- The private service can be operated without direct manual database edits for
  normal account and group administration.

## Release

- [x] iOS debug build.
- [x] macOS debug build.
- [x] iOS TestFlight archive path.
- [x] macOS TestFlight/archive path.
- [x] Fresh install login smoke path.
- [ ] Upgrade from previous build keeps valid local state or presents a clear
      reset/migration state.

Definition of done:

- Release commands are documented with real target names and have been run at
  least once after XMPP integration lands.
