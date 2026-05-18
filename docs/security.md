# Security Notes

## Threat Model

The MVP is for a small private group on a self-hosted server. The main risks are:

- Server compromise or VPS operator access.
- Account password compromise.
- Device loss or malware on a client device.
- Unknown or untrusted devices receiving future encrypted messages.
- Broken backups or unrecoverable OMEMO state.
- Push notification metadata exposure.
- Accidental public registration or accidental federation.

The MVP does not try to protect against compromised endpoints. If a phone or Mac
is compromised, decrypted messages on that device are exposed.

## What E2EE Covers

OMEMO should protect product DM and group message content from the XMPP server
when the client, room, and device state are correctly configured. The server may
store archived stanzas and uploaded media, but those payloads must be encrypted
before they reach the server.

Trix must rely on a reviewed OMEMO implementation. Do not implement custom
cryptography, custom key exchange, or manual key handling in the app.

## Metadata Still Visible To The Server

Even with OMEMO, the server can still observe metadata, including:

- Account JIDs and resource/device activity.
- MUC room membership.
- Message timing and approximate sizes.
- XEP-0444 reaction metadata, including the reacted-to message id and emoji.
- IP addresses and user agents.
- Media upload/download timing and sizes.
- Push gateway interactions if push is enabled.

This is acceptable for a tiny trusted private server, but it should be clearly
understood.

## Federation Risk

The MVP is private and non-federated. Accidental server-to-server federation would
expand the trust and abuse surface beyond the product scope.

Production deployment must:

- disable the server-to-server module;
- keep port `5269` closed;
- avoid publishing server-to-server DNS records;
- verify from outside the host that federation is unreachable.

## Device Trust Risk

If new devices are trusted silently, an attacker with account credentials can add
a device and receive future encrypted messages. The MVP may ship with limited
trust UX only if the limitation is visible and tracked.

The app should surface OMEMO device identity and trust state. It must not mark all
devices trusted locally just to make encrypted sending easier.

The Apple Settings surface now shows the current account's OMEMO device list
from the existing MartinOMEMO discovery/store path: current device, published
account devices, device ids, active state, local trust state, and a short visual
fingerprint challenge. Trust is a per-device manual action and is only offered
after the user can compare the visual challenge. The challenge is a documented
deterministic display transform over the MartinOMEMO identity fingerprint; the
raw OMEMO fingerprint is hidden behind a technical disclosure. The pinned
libsignal source includes displayable/scannable fingerprint primitives, but they
are not exposed to the app target as a reviewed Swift verification flow here.
The app still does not provide an interactive reviewed SAS exchange,
cross-signing, QR scanning, or device revocation in this slice; those remain
blocked rather than replaced with custom crypto or silent trust-all behavior.

## Recovery And Reinstall Risk

The current Apple MartinOMEMO path persists local OMEMO registration id,
identity keys, prekeys, signed prekeys, sessions, identities, sender keys, and
trust decisions in the app Keychain. Logging out removes the saved XMPP login but
does not erase OMEMO device state.

The decrypted local timeline cache, room-summary cache, and media cache are
stored outside Keychain in app-controlled Application Support storage and
encrypted with app-local cache keys that are stored in Keychain. Keychain is
used for small secret material, not as the message-history, room-list, or media
database. The media cache stores decrypted attachment bytes only after local
OMEMO media decryption, encrypts each blob and its index at rest, uses hashed
file names, and exposes Settings controls for size, age, per-chat media depth,
forever retention, and full or partial deletion.

There is no validated server-side OMEMO key backup or account recovery path in
this slice. If the app is deleted, the Keychain state is reset, or the account is
restored onto a fresh device, the client creates a new OMEMO device. Old
ciphertext archived in MAM or stored in local caches can remain unavailable when
it was not encrypted for the replacement device. Trix must not add custom key
recovery or manually move OMEMO private key material to work around this; the
limitation must remain visible until a reviewed MartinOMEMO recovery path is
selected.

## Group E2EE Risk

OMEMO group chat depends on correctly mapping room occupants to real JIDs and
encrypting to the devices of every current member. Anonymous or public MUC rooms
do not satisfy the Trix group-chat requirement.

Trix group rooms must be members-only and non-anonymous. If the client cannot
retrieve the member list or device bundles required for OMEMO, sending must be
blocked instead of falling back to plaintext.

The Apple client caches known MUC members in an encrypted Application Support
file and merges that cache with live occupants and affiliation queries. Keychain
stores only the cache key. This cache is used for display and recipient
validation continuity after reconnect; it is not a server-side authorization
source. New Apple-created MVP groups make invited members MUC admins so the
current member-management UI can list and change room affiliations.

The macOS `group-e2ee` live smoke passed with three accounts on 2026-05-09:
private MUC create, invite/join, owner/peer/third member-list visibility,
explicit device trust, encrypted group send, and decrypt on both peers completed
without printing message bodies or OMEMO secrets.

## Attachment Risk

Uploaded files must be encrypted before upload. The server may store encrypted
media blobs and metadata, but it must not receive plaintext file contents from
product chat flows.

The Apple XMPP attachment MVP uses MartinOMEMO file encryption before requesting
an HTTP upload, then sends the download URL, media decryption fragment, filename,
MIME type, size, and image dimensions inside an OMEMO-encrypted message
descriptor. HTTP upload requests use a generic encrypted filename and
`application/octet-stream` so the upload service does not receive the original
filename or MIME type. Group attachment sending uses the same encrypted path and
is gated on a validated MUC recipient set plus trusted active OMEMO devices for
every recipient. On 2026-05-10 the credentialed `dm-attachment` and
`group-attachment` smoke modes passed live upload, peer download, local decrypt,
MIME/image classification, and byte equality checks without printing decrypted
content, filenames, media keys, or secret URLs.

Inline timeline media previews use the same local decrypt path as manual
attachment preview and are limited to supported image attachments with bounded
descriptor sizes. They must not introduce server-side plaintext access or
logging of decrypted bytes, filenames, media keys, local paths, or preview data.

Do not log filenames, local paths, media keys, decrypted media bytes, or
decrypted previews in production paths.

## Sticker Import Risk

Stickers are a presentation layer on top of the encrypted attachment path, not a
new plaintext media channel. Apple sends sticker bytes through the existing
MartinOMEMO file-encryption and HTTP-upload flow, with sticker metadata kept
inside the OMEMO-encrypted attachment descriptor. The descriptor version remains
`1` so older clients can still treat the item as a normal encrypted attachment.

Telegram sticker import is server-proxied. The app-facing wrapper accepts
`POST /v1/stickers/telegram/packs` and
`POST /v1/stickers/telegram/file` only after the same signed-in XMPP Basic auth
validation used by the invite/password routes. `TRIX_TELEGRAM_BOT_TOKEN` and
`TRIX_STICKER_TOKEN_SECRET` are deployment-local server secrets and must never
ship in an Apple client or be committed. Sticker file responses use short-lived
HMAC-signed tokens so Telegram file paths and bot credentials are not exposed to
clients.

The v1 import path accepts only regular static Telegram stickers. Animated
`.TGS` and video `.WEBM` stickers are skipped and surfaced to the user as an
unsupported count. Imported sticker packs are stored per account on Apple in an
Application Support library encrypted with a local Keychain-held key. Received
Telegram-sourced stickers may offer "Add Sticker Pack" by importing the source
pack metadata; non-Telegram sticker pack import stays unavailable in v1.
Settings can clear the full local sticker library or remove individual imported
packs without touching timeline or chat caches.

Do not log Telegram bot tokens, sticker token secrets, signed sticker file
tokens, Telegram file paths, local sticker files, decrypted sticker bytes,
sticker media keys, or XMPP passwords used for sticker import authentication.

## Backup Risk

Server backups include account metadata, rosters, MUC state, SQL-backed MAM
archives, and uploaded media blobs. Product message and attachment payloads are
expected to be OMEMO/client-encrypted before they reach the server, but backups
still expose metadata and encrypted ciphertext history to whoever can read them.

Production backups must be root-only, must not include TLS private keys,
bootstrap passwords, `.env`, shell history, APNs credentials, or OMEMO local
device secrets, and must be periodically restored into a clean instance before
being treated as reliable.

As of the current XMPP server/control-plane slice,
`server/xmpp/scripts/restore-verify.sh` is the local restore gate. It now uses
ejabberd-native Mnesia backup/restore for account state plus a scoped upload
archive, and passed locally on 2026-05-09. Do not treat tar-only fresh-volume
archives as production-ready restore for account state.

## Push Notification Risk

Push notifications should not include decrypted message bodies. The APNs payload
should be a wake-up or minimal metadata signal, with message text resolved locally
after sync and decryption.

APNs keys, gateway tokens, and signing credentials must never be committed.

The current Apple XMPP path accepts only sync pushes with
`aps.content-available=1` and `trix.type=sync`. Optional account, room, and badge
metadata is allowed. The only accepted visible APNs alert is generic: title
`Trix` with `New encrypted message` or unread-count wording. Plaintext/body
outside that generic alert, decrypted content, filename, and attachment-name
payload fields are rejected by the app handler, and notification profile or mute
state is also rejected if it appears in APNs metadata. The app does not create
local notifications containing decrypted message or attachment text. When the app
is inactive and receives an older silent sync payload, it may turn local sync
into a generic local notification such as a new encrypted-message/unread count
alert. Those local fallback notifications are filtered by per-room default,
muted, or mentions-only profiles after sync. Mentions-only currently uses local
decrypted content matching for the account JID or localpart mention token until
the dedicated XMPP mentions work lands; if no local mention can be identified,
non-mention notifications are suppressed. Those remote or local notifications
must not include decrypted text, filenames, room names, or attachment names.

Per-room notification profiles reveal behavior metadata. The Apple client stores
the local profile cache in Application Support encrypted with AES-GCM and a
Keychain-held key, and backs the settings with a private XMPP PEP item so profile
changes survive local cache loss. The server-backed PEP item contains room IDs
and profile values for the signed-in account; it is not copied into APNs payloads.

ejabberd `mod_push` only exposes XMPP push semantics; it does not sign or send
APNs requests by itself. APNs signing is handled by the standalone
`trix-push-gateway` binary. The gateway also has an XEP-0114
component mode that accepts Martin/Tigase `register-device`, stores XEP-0357
node mappings outside the repo, and emits only the generic sync notification
contract above.

The Apple client must send XEP-0352 Client State Indication when the iOS/macOS
scene becomes inactive or active. Without that inactive signal, an online or
stream-resumable XMPP resource can remain eligible for normal delivery and
ejabberd may not publish to the XEP-0357 push node, leaving APNs untouched even
though device registration succeeded.

On 2026-05-10 the XMPP push gateway was deployed on the VPS with
deployment-local APNs token-auth material. The APNs `.p8` key is mounted into
the container read-only, owned for the non-root gateway user, and not committed
to the repository. `trix-push-gateway` is healthy, binds its HTTP endpoint to
`127.0.0.1:8090`, connects to ejabberd as the private XEP-0114 component
`push.trix.selfhost.ru`, and the component port is not externally reachable.
APNs delivery is still not launch-complete until signed-device smoke confirms
delivery and a payload/log audit confirms no alert, body, filename, media-key,
or decrypted-content fields.

## Registration And Provisioning Risk

Public registration is out of scope. Users should be created by the operator
through the Trix control plane, a server admin API, a documented one-off admin
command, or a single-use invite wrapper that keeps public XMPP registration
disabled.

The control plane must not expose secrets in logs and must not create accounts
with committed default passwords.

The current ejabberd `mod_http_api` path is acceptable only as a localhost-bound
backend for a trusted operator wrapper or local scripts. The checked-in
`server/xmpp/scripts/operator-control.sh` flow can provision accounts, reset
passwords, disable accounts with `ban_account`, re-enable them with
`unban_account`, search the small local directory, and report
archive/upload/push health through loopback-only calls. It is not a public or
client-facing API and must not be exposed directly outside the host. Passwords
are read from local files and must not be logged.

The checked-in invite-registration wrapper is the first app-facing account
bootstrap path. It keeps invite codes single-use, stores only code hashes plus
redemption metadata, requires a bearer token for `POST /v1/operator/invites`,
allows signed-in app users to issue codes through `POST /v1/invites` only after
ejabberd `check_password` validates the current XMPP account, and redeems
through the loopback ejabberd API. It also allows signed-in app users to change
their own password through `POST /v1/account/password`; the wrapper validates the
current password with `check_password` before calling loopback `change_password`.
Only `POST /v1/invites`, `POST /v1/account/password`,
`POST /v1/registration/redeem`, `POST /v1/stickers/telegram/packs`, and
`POST /v1/stickers/telegram/file` should be reachable by clients through private
TLS policy; `/v1/operator/*` remains operator-only. Request bodies include invite
codes, XMPP passwords, and short-lived sticker file tokens, so reverse proxy and
service logs must not capture bodies.

## Local Diagnostics Risk

The Apple Settings diagnostics surface is intentionally local and redacted. It
may show account JID, server, room/invite/unread counts, push registration
status, and device-trust state, but it must not show passwords, APNs tokens,
OMEMO secrets, private keys, media keys, local file paths, or decrypted message
or attachment bodies.

## Logging Rules

- Do not log passwords.
- Do not log auth tokens or SASL material.
- Do not log OMEMO private keys, bundles with private material, or trust secrets.
- Do not log decrypted message bodies in production paths.
- Do not log decrypted attachment contents.
- Do not log Telegram bot tokens, sticker token secrets, sticker file tokens, or
  decrypted sticker bytes.
- Do not log APNs tokens or admin credentials.
- Keep debug logs local and scrubbed.
