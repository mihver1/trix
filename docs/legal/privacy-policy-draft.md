# Trix Privacy Policy (Draft)

Status: Draft with CEO and CTO review incorporated; not publish-ready.
Publication gate: outside-counsel review is required before publication, and the
current CEO decision is no publication until counsel supplies or approves the
final clauses.
Last updated: 2026-05-21
Applies to: Trix MVP private XMPP + OMEMO deployment.

This document is a product-fact draft, not outside-counsel advice.

## 1) Scope and Roles

Trix is a private, invite-based messenger operated on a self-hosted XMPP stack.
For the current MVP direction, the primary deployment is the Trix-operated private
instance and control-plane tooling.

For this MVP draft, the approved operator/controller identity is "Trix only".
No fuller legal-entity/controller identity has been approved for publication.

If someone else independently self-hosts Trix components, that operator controls
its own server configuration, logs, backups, and account administration for that
instance.

Fact basis:
- `docs/architecture.md` (Goal, Components, Control Plane)
- `server/xmpp/README.md` (deployment model, operator wrapper)
- `docs/security.md` (private MVP threat model)
- CEO decision on `TRI-38` (2026-05-21): operator/controller identity uses only
  Trix; counsel required; no publication.

## 2) Data Categories We Process

### 2.1 Account and profile data

We process account identifiers and profile data needed to run XMPP accounts and
friend directory/profile features, including user JIDs, localpart/handle,
display-name metadata, and related account status.

Fact basis:
- `docs/architecture.md` (control-plane responsibilities)
- `docs/mvp-checklist.md` (directory and profile flows)
- `server/xmpp/README.md` (invite and account provisioning wrapper)

### 2.2 Invite and account lifecycle metadata

The invite wrapper stores invite code hashes (not raw codes), optional reserved
localpart/display-name metadata, issuer metadata, created/expires timestamps, a
redemption-in-progress marker, redeemed timestamp, and redeemed JID. Raw invite
codes and XMPP passwords are not stored in the invite metadata file.

The wrapper validates account credentials for invite issuance/password changes and
passes account provisioning/password-change commands to loopback ejabberd APIs.
The wrapper is documented to avoid request-body logging because bodies can include
invite codes and passwords.

Fact basis:
- `server/xmpp/scripts/invite-registration-server.py`
- `server/xmpp/README.md` (Invite Registration section)
- `docs/security.md` (Registration and Provisioning Risk; Logging Rules)

### 2.3 Message, group, and activity metadata

Even with OMEMO, the server can process metadata such as account and device
activity, group membership, message timing/size patterns, read-marker metadata,
reaction/reply/edit/retract/thread metadata, upload timing/sizes, IP addresses,
and user agents.

Fact basis:
- `docs/security.md` (Metadata Still Visible To The Server)

### 2.4 Encrypted message and media payloads

For product DMs/groups, message bodies and attachment descriptors are intended to
be encrypted client-side with OMEMO before server storage or transit.

The server still stores encrypted stanzas and upload artifacts and can access
server-visible metadata.

Fact basis:
- `docs/architecture.md` (OMEMO; server must not decrypt)
- `docs/security.md` (What E2EE Covers; Attachment Risk)
- `server/xmpp/README.md` (MAM + upload architecture)

### 2.5 Push and call-related data

If enabled, push processing can include APNs token-registration mapping and
minimal notification routing metadata. Payload design is intentionally generic
and must not include decrypted message text. Signed macOS APNs validation has
passed for generic plaintext-free delivery; broader push changes should keep
that smoke as a regression gate.

Call features add call/session metadata (for example call IDs, participant
activity timing, relay/network metadata). Encrypted calls are currently tracked
as not launch-complete.

Fact basis:
- `apps/trix-push-gateway/README.md`
- `docs/security.md` (Push Notification Risk; Call Media Risk)
- `docs/mvp-checklist.md` (APNs and call status)

### 2.6 Local device storage

On Apple clients, session and OMEMO secret material are stored in Keychain.
Decrypted local caches (timeline/media/sticker/profile cache data) are stored in
app-managed storage encrypted with local keys whose secrets are kept in Keychain.

Logging out removes the saved XMPP login but leaves local OMEMO device/trust
state until app Keychain state is reset. Reinstalling the app or resetting
Keychain state creates a new OMEMO device and can leave old ciphertext
unavailable without a reviewed recovery path.

Fact basis:
- `docs/security.md` (Recovery and Reinstall Risk; media/profile cache notes)
- `docs/mvp-checklist.md` (local encrypted media cache retention)

## 3) Why We Process Data

We process data to:
- create/manage accounts and authenticate users;
- deliver encrypted DMs and encrypted group chats;
- maintain private group membership and room sync;
- support push wake-ups and call setup where enabled;
- operate backups, restore checks, and diagnostics for the private deployment;
- enforce abuse/security controls for a private operator-managed service.

Fact basis:
- `docs/architecture.md`
- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/README.md`

## 4) Encryption and Security Representations

Trix uses OMEMO as a mandatory E2EE gate for product DM/group sends in MVP flows,
with fail-closed behavior when required encryption/trust state is missing.

Trix does not claim perfect security or anonymity. Endpoint compromise (for
example compromised phone/Mac) can expose decrypted content on that endpoint.
Server operators can still observe metadata described above.

Fact basis:
- `docs/architecture.md` (mandatory OMEMO, no plaintext fallback)
- `docs/security.md` (Threat Model; What E2EE Covers; Metadata visibility)
- `docs/mvp-checklist.md` (plaintext blocked in product flows)

## 5) Retention, Backups, and Deletion

### 5.1 Server retention and backups

Server state includes account metadata, rosters, MUC state, archived encrypted
stanzas, and uploaded media blobs. Production backup scripts currently keep the
latest 14 backup archives by default.

Backup archives can preserve encrypted content and metadata. Deletion requests
may not immediately erase data from all backups.

Fact basis:
- `docs/security.md` (Backup Risk)
- `server/xmpp/README.md` (Backup section)
- `server/xmpp/scripts/backup.sh` (`TRIX_XMPP_BACKUP_RETAIN=14` default)

### 5.2 Account disablement vs deletion

The documented operator disable flow (`ban_account`) blocks login and can end
active sessions without deleting existing account data (for example roster,
profile, archive state). Re-enable clears the ban.

Fact basis:
- `server/xmpp/README.md` (operator-control behavior)
- `docs/mvp-checklist.md` (disable/enable account checks)

### 5.3 Local deletion controls

Apple clients expose local controls to clear encrypted media/sticker caches.
These controls govern local device storage and do not automatically mean global
server/backups deletion.

Fact basis:
- `docs/mvp-checklist.md` (local encrypted media cache retention controls)

### 5.4 Invite record retention

Unused invites expire by TTL (default 7 days, max 30 days). Redeemed invites and
expired unused invites are retained in `invites.json` for up to 30 days via
`TRIX_INVITE_METADATA_RETENTION_SECONDS` before operator purge; longer retention
values are rejected by the invite wrapper.

Fact basis:
- `server/xmpp/scripts/invite-registration-server.py`
- `server/xmpp/README.md` (invite wrapper)

## 6) Sharing and Third Parties

Trix does not describe selling user data.

Data may be processed by infrastructure and protocol providers required for
service operation, including:
- hosting/VPS and networking layers used by the private deployment;
- Apple APNs for push delivery (if enabled);
- Telegram API paths only if Telegram sticker import is enabled;
- LiveKit/coturn media infrastructure for calls (if enabled).

Fact basis:
- `server/xmpp/README.md`
- `apps/trix-push-gateway/README.md`
- `docs/security.md`

## 7) User Choices and Account Actions

Current documented user/operator actions include:
- user password changes through the authenticated account endpoint;
- operator account provision/disable/enable/reset flows;
- local client cache-clearing controls.

Trix is adult-only and invite-only for the MVP. Users must be 18 or older,
invites must not be issued to minors, and discovered minor accounts may be
disabled pending deletion and legal handling.

Fact basis:
- `server/xmpp/README.md`
- `docs/mvp-checklist.md`
- CEO review on `TRI-24` (2026-05-20)

## 8) Privacy Contact

Privacy requests should use `privacy@trix.selfhost.ru`. Do not publish a
personal address in the policy.

Fact basis:
- CEO review on `TRI-24` (2026-05-20)

## 9) Current-State vs Publication Gates

Current-state statements in this draft are based on repository evidence as of
2026-05-21.

Before publication, outside counsel must review jurisdiction-specific rights
language (access/correction/erasure/objection, etc.), cross-border transfer
language, legal-entity/controller identity, and any required
consumer/minor-handling disclosures. The CEO decision on `TRI-38` confirms that
counsel is required and publication is not allowed until counsel supplies or
approves those clauses. No board waiver, counsel-approved template, or final
publishable clause text is available in the current legal thread.

Fact basis:
- CEO decision on `TRI-38` (2026-05-21): counsel required; no publication; no
  counsel-approved text or template available.
- CEO review on `TRI-33` and `TRI-24`: `privacy@trix.selfhost.ru`, adult-only,
  invite-only, and no public registration remain the MVP policy facts.

## 10) Changes to This Policy

Trix may update this policy as product behavior changes. Material changes should
be dated and versioned.

Fact basis:
- Internal draft-control requirement for MVP docs; no automated legal-notice
  mechanism is currently documented.
