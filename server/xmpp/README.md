# Trix XMPP Server Scaffold

This directory contains a first-pass XMPP scaffold for a small private
deployment at:

```text
trix.selfhost.ru
```

The default recommendation is now ejabberd, because Trix needs a centralized
operator control plane. Prosody remains in this directory only as a lightweight
shell-managed fallback/spike profile.

The scaffold is intentionally separate from the Matrix server files. Federation
is disabled, registration is closed by default, and no secrets are committed.

## Files

- `docker-compose.yml`: ejabberd by default, plus a `prosody-fallback` profile.
- `certs/README.md`: keeps the local certificate mount directory present without
  committing real certificates or private keys.
- `ejabberd.yml`: private non-federated ejabberd config for
  `trix.selfhost.ru`, `conference.trix.selfhost.ru`, and HTTP upload under
  `https://trix.selfhost.ru/upload`.
- `prosody.cfg.lua`: lightweight fallback/spike config, not the recommended
  default.
- `.env.example`: non-secret local overrides for image tags and bind addresses.
- `scripts/local-smoke.sh`: bounded local ejabberd start plus STARTTLS/SASL
  login smoke with generated disposable credentials.
- `scripts/operator-control.sh`: local operator commands for provision,
  reset-password, disable, enable, directory search, and archive/upload/push
  health over the loopback `mod_http_api` backend.
- `scripts/operator-api-smoke.sh`: localhost `mod_http_api` provision,
  reset-password, directory search, health, disable, enable, and cleanup smoke
  with generated disposable credentials.
- `scripts/restore-verify.sh`: fresh-instance restore verifier using
  ejabberd-native Mnesia backup/restore for account state plus a compose-scoped
  upload-volume archive.

## Default: ejabberd

Key decisions:

- Client-to-server XMPP: `5222`, bound to `127.0.0.1` by default in Compose.
- Server-to-server XMPP: no `5269` listener, plus `s2s_access: none`.
- Control plane: `mod_http_api` is enabled on the localhost-bound HTTP listener
  at `/api`. API permissions allow loopback/admin use and deny `stop`/`start`.
- MUC: `conference.trix.selfhost.ru` using `mod_muc`.
- MAM: one-to-one and room history through `mod_mam` and MUC `mam: true`,
  backed by SQLite in the ejabberd database volume.
- HTTP upload/file sharing: `https://trix.selfhost.ru/upload` through
  `mod_http_upload`, advertised by the internal XMPP upload component
  `upload.trix.selfhost.ru`, with upload data persisted in a named volume.
- Authentication: ejabberd internal auth. Create accounts through
  `ejabberdctl` during an operator-controlled bootstrap window.
- Registration: disabled by omitting `mod_register`; create users only through
  operator-controlled `ejabberdctl` or localhost API flows.

OMEMO is client-side end-to-end encryption. This scaffold does not implement
custom cryptography, custom key exchange, or server-side message encryption.

## Prosody Fallback

Prosody is still present for a fast shell-managed spike:

```bash
cd server/xmpp
podman compose --profile prosody-fallback up -d prosody
```

Do not treat Prosody as the final product recommendation unless the centralized
control-plane requirement changes or ejabberd fails validation in a way that is
more expensive than a Prosody-based operator workflow.

## DNS And TLS

Minimum intended DNS records:

```text
trix.selfhost.ru              A/AAAA  <server-ip>
conference.trix.selfhost.ru   A/AAAA  <server-ip>
```

For client compatibility, add SRV records if the XMPP service is not directly
available on `trix.selfhost.ru:5222`.

TLS material is not included. Put deployment-specific certificates under
`server/xmpp/certs/` or mount them from a host secret path. Do not commit that
directory if it contains real certificates or private keys.

Spike required before public exposure:

- Confirm final certificate names and PEM layout for ejabberd
  `/opt/ejabberd/conf/certs/*.pem`.
- Confirm whether upload stays under `https://trix.selfhost.ru/upload` or moves
  to a dedicated upload host after a matching certificate exists. The current
  config uses the primary host so the existing wildcard `*.selfhost.ru`
  certificate can cover `trix.selfhost.ru`.
- Confirm whether the localhost `/api` control plane should remain HTTP behind
  a private sidecar/proxy or move to a TLS listener.

## Local Validation

Render the Compose file:

```bash
cd server/xmpp
podman compose config
```

Use `docker compose` for the same commands when Docker is available.

Run the bounded local start/login smoke without committing credentials:

```bash
cd server/xmpp
./scripts/local-smoke.sh
```

The script creates a temporary Compose project, generates a one-day local
self-signed certificate, creates one disposable account, verifies STARTTLS and
SASL login over XMPP, then removes the temporary containers and volumes. It uses
random host ports by default so it can run beside an existing local ejabberd.

Check that ejabberd can boot with this config:

```bash
podman run -d --name trix-ejabberd-check \
  --hostname ejabberd \
  -e ERLANG_NODE_ARG=ejabberd@ejabberd \
  -v "$PWD/ejabberd.yml:/opt/ejabberd/conf/ejabberd.yml:ro" \
  -v "$PWD/certs:/opt/ejabberd/conf/certs:ro" \
  ghcr.io/processone/ejabberd:latest foreground-quiet
podman exec trix-ejabberd-check ejabberdctl status
podman stop trix-ejabberd-check
```

A complete deployment validation still needs real certificates, final DNS, and
client login/upload smoke.

Start ejabberd locally:

```bash
podman compose up -d ejabberd
podman compose logs --tail=100 ejabberd
```

Confirm only local C2S/HTTP bindings from the host:

```bash
lsof -nP -iTCP:5222 -iTCP:5280 -iTCP:5269 -sTCP:LISTEN
```

There should be listeners for `5222` and `5280` only. There should be no
`5269` listener.

Create a local account without putting the password in shell history:

```bash
podman compose exec ejabberd ejabberdctl register alice trix.selfhost.ru
```

If the image requires a password argument for non-interactive registration, use
an interactive local wrapper or a temporary environment variable and do not
commit or log the password.

Check control-plane reachability from the host:

```bash
curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d '{}' \
  http://127.0.0.1:5280/api/status
```

Authentication and exact command authorization need a live admin account before
this is a finished control-plane contract.

Run the bounded localhost operator API smoke against an already-running local
ejabberd:

```bash
cd server/xmpp
./scripts/operator-api-smoke.sh
```

Current decision: ejabberd `mod_http_api` is viable as the low-level
operator/backend API for health and account lifecycle operations when it remains
bound to loopback. It is not the finished product control plane by itself:
Trix still needs a small authenticated and audited operator wrapper before any
non-local caller can create users, reset passwords, change group membership, or
inspect diagnostics. Do not expose `5280` publicly.

The checked-in MVP operator wrapper is intentionally a local script:

```bash
cd server/xmpp
./scripts/operator-control.sh provision-user alice /run/secrets/trix/alice-password
./scripts/operator-control.sh reset-password alice /run/secrets/trix/alice-new-password
./scripts/operator-control.sh disable-user alice "left private group"
./scripts/operator-control.sh enable-user alice
./scripts/operator-control.sh search-directory ali
./scripts/operator-control.sh archive-upload-push-health
```

`operator-control.sh` refuses non-loopback API URLs unless
`TRIX_XMPP_OPERATOR_ALLOW_NON_LOOPBACK=1` is set for an explicit private
maintenance session. Passwords are read from files and are never printed.
Disable uses ejabberd `ban_account`, which blocks login and kicks current
sessions without deleting the account's roster/vCard/archive state. Enable uses
ejabberd `unban_account` to clear that ban without changing the account secret.

## Deployment Notes

1. Copy `.env.example` to `.env`.
2. Keep localhost binds until a reverse proxy and firewall rules are ready.
3. Mount valid certificates for `trix.selfhost.ru` and any upload host clients
   will access.
4. Start ejabberd:

```bash
cd server/xmpp
podman compose up -d ejabberd
```

5. To enable APNs wake pushes, set deployment-local APNs variables plus
   `TRIX_XMPP_PUSH_COMPONENT_SECRET`, mount the `.p8` key through
   `TRIX_APNS_KEY_DIR`, and start the private component profile:

```bash
cd server/xmpp
podman compose --profile push-gateway up -d ejabberd push-gateway
```

6. Add users through `ejabberdctl` or the localhost-only control plane after
   admin authentication is validated.
7. Open only the required public ports. For this private non-federated target,
   do not open `5269`.

## APNs Push Status

ejabberd `mod_push` is enabled for XMPP push semantics, but ejabberd is not an
APNs provider by itself. Trix provides `trix-push-gateway` as a private APNs
sender plus XEP-0114 component for Martin/Tigase registration.

APNs signing material has been verified on the legacy `trix-server` deployment,
outside this repository. The gateway loads APNs credentials from environment or
a mounted `.p8` file, accepts only wake-only requests, advertises
`pubsub/push`, handles Martin's `register-device` command, stores the returned
XEP-0357 node mapping locally, and sends only `aps.content-available=1` plus
`trix.type=sync` notifications.

Do not commit the `.p8` key or related credentials. The XEP-0114 component port
`5347` must stay private to the host or Docker network and must not be published
through Compose. `iNPUTmice/up` was reviewed as a possible component reference,
but it is a UnifiedPush provider for XMPP distributors and does not implement
APNs provider delivery or the Martin/Tigase registration flow Trix uses.

Production status on 2026-05-10: the XMPP deploy at `trix.selfhost.ru` runs
`ejabberd` plus `trix-push-gateway`. The gateway was built from a minimal Rust
source context under `/opt/trix-build`, uses deployment-local APNs token-auth
material mounted from `/opt/trix-xmpp/certs/apns`, rejects checked-in default
secrets, exposes HTTP health only on `127.0.0.1:8090`, and connects to ejabberd
as the private XEP-0114 component `push.trix.selfhost.ru`. External checks keep
`5222` reachable while `5269`, `5347`, and `8090` are not reachable from the
internet. Do not mark APNs delivery complete until a signed-device wake-only
smoke passes without alert, body, filename, media-key, or decrypted-content
payload fields.

To verify a legacy `trixd` env file or process without printing values:

```bash
server/xmpp/scripts/push-gateway-apns-presence.sh /path/to/trixd.env
server/xmpp/scripts/push-gateway-apns-presence.sh --pid <trixd-pid>
```

The checker prints only `present`, `missing`, `complete`, and key-file
readability status. It does not print APNs team IDs, key IDs, topics, private
key contents, or key paths. Once the source reports `apns_config=complete`, copy
or mount the `.p8` into the XMPP deployment, set matching `TRIX_APNS_*` values
for `trix-push-gateway`, set fresh `TRIX_PUSH_GATEWAY_TOKEN` and
`TRIX_XMPP_PUSH_COMPONENT_SECRET`, then start:

```bash
podman compose --profile push-gateway up -d ejabberd push-gateway
```

## Backup

ejabberd data lives in Compose volumes:

- `trix-xmpp_ejabberd-database`: Mnesia database, accounts, rosters, archives.
- `trix-xmpp_ejabberd-upload`: HTTP upload files.

Message Archive Management is SQL-backed through SQLite:

```yaml
sql_type: sqlite
sql_database: "/opt/ejabberd/database/ejabberd-mam.sqlite"
update_sql_schema: true
```

Accounts, rosters, vCards, pubsub state, and other small control-plane tables
remain in ejabberd's internal database for now. This avoids moving existing
bootstrap users during the first deployment while removing the Mnesia archive
warning for MAM.

Production cold backup on the VPS:

```bash
/opt/trix-xmpp/scripts/backup.sh
```

The script:

- stops `ejabberd`;
- archives non-secret config files;
- archives the `trix-xmpp_ejabberd-database` and
  `trix-xmpp_ejabberd-upload` Docker volumes;
- excludes private TLS material, ejabberd's database certificate cache, `.env`,
  bootstrap credentials, and shell history;
- starts `ejabberd`;
- keeps the latest 14 backups by default under `/var/backups/trix-xmpp`.

Installed timer:

```bash
systemctl status trix-xmpp-backup.timer
systemctl list-timers trix-xmpp-backup.timer
```

Default schedule is daily at `03:20` local server time with up to ten minutes of
randomized delay.

Manual local native Mnesia backup plus upload archive, if systemd is unavailable:

```bash
cd server/xmpp
mkdir -p backups
podman compose exec ejabberd \
  ejabberdctl backup /opt/ejabberd/database/trix-mnesia.backup
podman compose stop ejabberd
podman compose run --rm --no-deps \
  -v "$PWD/backups:/backup" \
  --entrypoint sh \
  ejabberd \
  -lc 'set -e
cp /opt/ejabberd/database/trix-mnesia.backup /backup/trix-mnesia.backup
if [ -f /opt/ejabberd/database/ejabberd-mam.sqlite ]; then
  cp /opt/ejabberd/database/ejabberd-mam.sqlite /backup/ejabberd-mam.sqlite
fi
tar czf /backup/ejabberd-upload.tgz -C /opt/ejabberd/upload .
rm -f /opt/ejabberd/database/trix-mnesia.backup'
podman compose start ejabberd
```

Fresh-instance restore verifier:

```bash
cd server/xmpp
./scripts/restore-verify.sh
```

Account and control-plane state must be restored through ejabberd-native Mnesia
backup/restore, not tar-only fresh-volume restore. The verifier creates a
disposable account, runs `ejabberdctl backup`, archives the upload volume through
the same Compose backend, destroys the temporary volumes, restores into a fresh
instance with `ejabberdctl restore`, confirms the account is registered, confirms
the upload archive sentinel, and completes STARTTLS/SASL login.

Current local result: passed on 2026-05-09 with `podman compose`. The script
intentionally avoids mixing `podman compose` with plain `podman run` or
`podman volume`, because delegated Compose providers can use a different volume
namespace.

Production backup scripts still need to follow the same native-Mnesia restore
requirement before tar-only volume backups are accepted for production migration
or host rename scenarios.

## OMEMO Smoke Checklist

Use two or more OMEMO-capable clients. Do not use server-side shortcuts to
trust devices silently.

1. Create `alice@trix.selfhost.ru` and `bob@trix.selfhost.ru`.
2. Log in from two devices or profiles for at least one account.
3. Add each other to rosters and verify device fingerprints or QR codes out of
   band.
4. Send an OMEMO one-to-one message while both users are online.
5. Disconnect one device, send another OMEMO message, reconnect, and confirm
   MAM sync shows the encrypted conversation history.
6. Create a room at `conference.trix.selfhost.ru`; keep it members-only and
   non-anonymous if the selected client exposes those controls.
7. Verify whether the selected clients support OMEMO in MUC. Treat missing MUC
   OMEMO support as a client limitation, not a reason to weaken encryption.
8. Upload a small file through the client. Confirm that HTTP upload works, and
   separately confirm whether the client encrypts file payloads or links under
   OMEMO. The upload service itself should be treated as storing server-visible
   file bytes unless the client proves otherwise.

## Spike-Required Items

- Production reverse proxy config for `https://trix.selfhost.ru/upload` and
  ejabberd HTTP on `5280`.
- Trix operator wrapper authentication, authorization, and audit logging around
  the localhost-only `mod_http_api` backend.
- Whether internal Mnesia storage is sufficient for the expected private user
  set, or whether SQL-backed archive storage should be introduced.
- Exact mobile-client behavior for OMEMO in MUC and encrypted file transfer.
- Prosody fallback viability only if ejabberd is rejected after live validation.
