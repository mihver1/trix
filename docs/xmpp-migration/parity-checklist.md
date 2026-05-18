# XMPP Product Parity Checklist

Use this checklist to decide whether the XMPP+OMEMO implementation has reached
Trix product parity. A checked item means both iOS and macOS have been
verified unless the item explicitly names one platform.

## Account And Session

- [ ] Operator-created account can log in on iOS.
- [ ] Operator-created account can log in on macOS.
- [ ] Logout clears local session state.
- [ ] App relaunch restores a valid session without retyping the password.
- [ ] Disabled account cannot establish a new session.
- [ ] UI shows an understandable account-disabled state.
- [ ] Credentials, tokens, and encrypted-store secrets are absent from logs.

Definition of done:

- Session material is stored in Keychain or another approved secure store.
- Account lifecycle is controlled by the Trix control plane, not public
  self-registration.

## Inbox And Navigation

- [ ] Room list shows DMs.
- [ ] Room list shows groups.
- [ ] Room list shows pending invitations.
- [ ] User can accept an invitation.
- [ ] User can decline an invitation.
- [ ] Last message, timestamp, unread state, and sender summary are visible.
- [ ] App restart reloads the same room list and selected timeline state where
  appropriate.
- [ ] iOS navigation matches the compact messenger shape expected for Trix.
- [ ] macOS navigation supports the desktop workflows expected for Trix.

Definition of done:

- Room discovery comes from live XMPP sync/archive state and Trix control-plane
  metadata where needed, not hard-coded local fixtures.

## Mandatory OMEMO

- [ ] DM creation requires OMEMO.
- [ ] Group creation requires OMEMO.
- [ ] Text send requires an encrypted conversation.
- [ ] Attachment send requires an encrypted conversation.
- [ ] Missing OMEMO support blocks send with a visible reason.
- [ ] Untrusted or unavailable participant device state blocks or warns
  according to the documented trust policy.
- [ ] Server-side stored message bodies are encrypted.
- [ ] No production path logs decrypted message bodies.

Definition of done:

- There is no plaintext fallback for DMs or groups.
- OMEMO behavior uses the selected library APIs rather than custom key handling.

## Direct Messages

- [ ] Create a DM from directory/search result.
- [ ] Open an existing DM.
- [ ] Send text.
- [ ] Receive text.
- [ ] Show sender, timestamp, and delivery state.
- [ ] Restart the app and reload history.
- [ ] Multi-device delivery works for the same user where supported.
- [ ] Duplicate one-to-one conversations are prevented or merged according to a
  documented rule.

Definition of done:

- Two-account encrypted DM smoke passes on iOS and macOS.

## Groups

- [ ] Create a private group with at least three accounts.
- [ ] Invite members.
- [ ] Accept group invite.
- [ ] Decline group invite.
- [ ] Add member after creation.
- [ ] Remove member where supported.
- [ ] Leave group.
- [ ] Show group title and member list.
- [ ] Send and receive encrypted text from multiple participants.
- [ ] Restart the app and reload group history.

Definition of done:

- Three-account encrypted group smoke passes and stores no plaintext bodies on
  the server.

## Attachments And Media

- [ ] Send image attachment.
- [ ] Send file attachment.
- [ ] Download received attachment.
- [ ] Preview image in app.
- [ ] Open or share file through OS controls.
- [ ] Attachment metadata does not expose plaintext message content beyond the
  accepted server-side upload metadata policy.
- [ ] Attachment retry and failure states are visible.

Definition of done:

- Attachment bytes round-trip through the selected XMPP upload path, and
  message references to the attachment are sent only inside encrypted messages
  where the chosen OMEMO/library model supports it.

## Conversation UX

- [ ] Composer sends on expected keyboard/action behavior.
- [ ] Timeline shows outgoing, incoming, failed, and pending states.
- [ ] Reactions are supported or explicitly deferred with a replacement UX.
- [ ] Read receipts are supported or explicitly deferred with visible status.
- [ ] Delivery status is supported or explicitly deferred with visible status.
- [ ] Typing/composing indicators are supported or explicitly deferred.
- [ ] Offline send behavior is documented and visible.
- [ ] Retry behavior is visible for failed sends.

Definition of done:

- User-visible conversation state is understandable even where XMPP extensions
  differ from prior prototypes.

## Directory, Profile, And Settings

- [ ] Search for users available to Trix.
- [ ] Start DM from a directory result.
- [ ] Select group invitees from directory results.
- [ ] View own profile.
- [ ] Edit Trix-owned profile metadata.
- [ ] View useful participant profile metadata.
- [ ] Show device/encryption state.
- [ ] Show server/account state.

Definition of done:

- Public or semi-public profile fields are intentionally chosen and documented.
- Trix-specific metadata is owned through the control plane or documented XMPP
  storage, not an accidental server default.

## Notifications

- [ ] Foreground updates appear without manual refresh.
- [ ] Background notifications work on iOS.
- [ ] Background notifications work on macOS where supported.
- [ ] Notification payloads do not contain decrypted message bodies unless a
  documented local-notification path decrypts on device.
- [ ] Badge/unread state matches the inbox.

Definition of done:

- APNs or other notification delivery is validated without leaking plaintext
  message content through server-side push payloads.

## Operations And Admin

- [ ] Create account through Trix control plane.
- [ ] Disable account through Trix control plane.
- [ ] Rotate invite or bootstrap credential.
- [ ] Inspect group membership through Trix control plane.
- [ ] Inspect server health.
- [ ] Confirm backup status.
- [ ] Restore from backup.
- [ ] Produce redacted diagnostics for support.

Definition of done:

- The private service can be operated without direct manual database edits for
  normal account and group administration.

## Release

- [ ] iOS debug build.
- [ ] macOS debug build.
- [ ] iOS TestFlight archive path.
- [ ] macOS TestFlight/archive path.
- [ ] Fresh install login smoke.
- [ ] Upgrade from previous build keeps valid local state or presents a clear
  reset/migration state.

Definition of done:

- Release commands are documented with real target names and have been run at
  least once after XMPP integration lands.
