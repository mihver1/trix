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

## Group E2EE Risk

OMEMO group chat depends on correctly mapping room occupants to real JIDs and
encrypting to the devices of every current member. Anonymous or public MUC rooms
do not satisfy the Trix group-chat requirement.

Trix group rooms must be members-only and non-anonymous. If the client cannot
retrieve the member list or device bundles required for OMEMO, sending must be
blocked instead of falling back to plaintext.

## Attachment Risk

Uploaded files must be encrypted before upload. The server may store encrypted
media blobs and metadata, but it must not receive plaintext file contents from
product chat flows.

Do not log filenames, local paths, media keys, decrypted media bytes, or
decrypted previews in production paths.

## Backup Risk

Server backups include account metadata, rosters, MUC state, SQL-backed MAM
archives, and uploaded media blobs. Product message and attachment payloads are
expected to be OMEMO/client-encrypted before they reach the server, but backups
still expose metadata and encrypted ciphertext history to whoever can read them.

Production backups must be root-only, must not include TLS private keys,
bootstrap passwords, `.env`, shell history, APNs credentials, or OMEMO local
device secrets, and must be periodically restored into a clean instance before
being treated as reliable.

## Push Notification Risk

Push notifications should not include decrypted message bodies. The APNs payload
should be a wake-up or minimal metadata signal, with message text resolved locally
after sync and decryption.

APNs keys, gateway tokens, and signing credentials must never be committed.

## Registration And Provisioning Risk

Public registration is out of scope. Users should be created by the operator
through the Trix control plane, a server admin API, or a documented one-off admin
command. Any temporary registration window must be short-lived and closed after
use.

The control plane must not expose secrets in logs and must not create accounts
with committed default passwords.

## Logging Rules

- Do not log passwords.
- Do not log auth tokens or SASL material.
- Do not log OMEMO private keys, bundles with private material, or trust secrets.
- Do not log decrypted message bodies in production paths.
- Do not log decrypted attachment contents.
- Do not log APNs tokens or admin credentials.
- Keep debug logs local and scrubbed.
