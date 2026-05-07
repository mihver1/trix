# Security Notes

## Threat Model

The MVP is for a small private group on a self-hosted server. The main risks
are:

- Server compromise or VPS operator access.
- Account password compromise.
- Device loss or malware on a client device.
- Unverified new devices joining encrypted rooms.
- Broken backups or unrecoverable encryption keys.
- Push notification metadata exposure.
- Accidental public registration.

The MVP does not try to protect against compromised endpoints. If a phone or Mac
is compromised, decrypted messages on that device are exposed.

## What E2EE Covers

Matrix encrypted rooms protect message content from the homeserver when the
client and room are correctly configured. Conduit should store encrypted event
payloads for encrypted rooms, not plaintext message bodies.

Trix must rely on Matrix SDK E2EE. Do not implement custom cryptography or
manual key handling.

## Metadata Still Visible To The Server

Even with encrypted rooms, the homeserver can still observe metadata, including:

- Account IDs and device IDs.
- Room membership.
- Event timing and event sizes.
- IP addresses and user agents.
- Media upload/download timing and sizes.
- Push gateway interactions if push is enabled.

This is acceptable for a tiny trusted private server, but it should be clearly
understood.

## Device Verification Risk

If new devices are trusted silently, an attacker with account credentials can
add a device and receive future encrypted room keys according to SDK and room
policy. The MVP may ship without a full verification UX only if the limitation
is visible and tracked.

The app should eventually support Matrix device verification flows instead of
inventing its own trust model.

## Key Backup And Recovery Risk

Key backup improves recovery from lost devices, but it introduces another
sensitive secret and UX path. A weak recovery phrase, unclear backup state, or
server-side recovery misunderstanding can lead to either message loss or
unexpected access.

The first pass uses Matrix SDK recovery APIs only. When no verified session is
available for interactive device verification, the Apple UI may set up recovery
with `enableRecovery` or confirm an existing recovery key with
`recoverAndFixBackup`. It must not call `resetIdentity`, silently trust devices,
or store recovery secrets in the repo or logs.

## Push Notification Risk

Push notifications should not include decrypted message bodies. If APNs is
added through a Matrix push gateway, the payload should be wake-up or minimal
metadata only, with message text resolved locally after sync.

APNs keys, gateway tokens, and signing credentials must never be committed.

## Registration Risk

Conduit registration should be token-based for bootstrap and disabled after the
friend group is created. The registration token in the repo is a placeholder and
must be changed before any reachable deployment.

The first created Conduit user is expected to be the admin. Create that user
immediately after first server start, then disable registration if no more
accounts are needed.

After bootstrap, new private users should be added through short registration
windows only: generate a fresh token, enable Conduit registration, let the
intended user register through a Matrix client that supports registration
tokens, then disable registration and rotate the token again. The Trix Apple
client is login-only for the MVP and should not receive or store registration
tokens after an account has been created.

## Logging Rules

- Do not log access tokens.
- Do not log passwords.
- Do not log decrypted message bodies in production paths.
- Do not log recovery secrets or registration tokens.
- Keep debug logs local and scrubbed.
