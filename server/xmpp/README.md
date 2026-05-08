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

5. Add users through `ejabberdctl` or the localhost-only control plane after
   admin authentication is validated.
6. Open only the required public ports. For this private non-federated target,
   do not open `5269`.

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

Manual local cold backup, if systemd is unavailable:

```bash
cd server/xmpp
mkdir -p backups
podman compose stop ejabberd
podman run --rm \
  -v trix-xmpp_ejabberd-database:/database:ro \
  -v trix-xmpp_ejabberd-upload:/upload:ro \
  -v "$PWD/backups:/backup" \
  alpine \
  sh -c 'tar czf /backup/ejabberd-database.tgz -C /database . && tar czf /backup/ejabberd-upload.tgz -C /upload .'
podman compose start ejabberd
```

Restore into fresh volumes:

```bash
cd server/xmpp
podman compose down
podman volume rm trix-xmpp_ejabberd-database trix-xmpp_ejabberd-upload
podman volume create trix-xmpp_ejabberd-database
podman volume create trix-xmpp_ejabberd-upload
podman run --rm \
  -v trix-xmpp_ejabberd-database:/database \
  -v trix-xmpp_ejabberd-upload:/upload \
  -v "$PWD/backups:/backup:ro" \
  alpine \
  sh -c 'cd /database && tar xzf /backup/ejabberd-database.tgz && cd /upload && tar xzf /backup/ejabberd-upload.tgz'
podman compose up -d ejabberd
```

Spike required: ejabberd has native backup/restore commands for Mnesia and node
name changes. Use them before relying on tar-only volume backups for production
migration or host rename scenarios.

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
- Final control-plane authentication and authorization shape around
  `mod_http_api`.
- Whether internal Mnesia storage is sufficient for the expected private user
  set, or whether SQL-backed archive storage should be introduced.
- Exact mobile-client behavior for OMEMO in MUC and encrypted file transfer.
- Prosody fallback viability only if ejabberd is rejected after live validation.
