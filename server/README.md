# Matrix Server

This directory contains the Conduit homeserver scaffold for the Matrix pivot.

## Files

- `docker-compose.yml`: Conduit plus optional Caddy TLS proxy profile.
- `conduit.toml`: sample private-server Conduit config.
- `Caddyfile`: preferred reverse proxy example.
- `nginx/matrix.conf`: alternative reverse proxy example.
- `.env.example`: placeholder environment values for a VPS deployment.
- `provisioning.md`: private-user account creation and registration window
  runbook.

## Choose `server_name`

The intended Matrix `server_name` is:

```text
trix.selfhost.ru
```

Matrix user IDs include the server name, for example:

```text
@alice:trix.selfhost.ru
```

Treat `server_name` as permanent once real users exist. Changing it later means
creating new Matrix IDs and migrating or abandoning rooms. Pick the final domain
before inviting friends.

## Local Development

Start only Conduit:

```bash
cd server
docker compose up -d conduit
curl http://127.0.0.1:6167/_matrix/client/versions
```

Use `podman compose` for the same commands when Docker is unavailable.

The local port is bound to `127.0.0.1:6167`. The config still uses
`server_name = "trix.selfhost.ru"` so Matrix IDs match the intended deployment.
Use a real TLS reverse proxy for physical-device testing.

Stop the local server:

```bash
docker compose down
```

Delete local Conduit data:

```bash
docker compose down -v
```

## Small VPS Deployment

1. Point DNS for `trix.selfhost.ru` at the VPS.
2. Copy `.env.example` to `.env`.
3. Replace `CONDUIT_REGISTRATION_TOKEN` with a high-entropy secret.
4. Review `conduit.toml`. Do not add `emergency_password` unless you are in a
   documented recovery flow; Conduit treats the key as active even when the
   value is empty.
5. Start Conduit and Caddy:

```bash
cd server
docker compose --profile caddy up -d
curl https://trix.selfhost.ru/_matrix/client/versions
```

Caddy will request TLS certificates automatically when DNS and ports 80/443 are
reachable.

## First Admin User

Conduit treats the first created user as the admin. After the first successful
boot:

1. Register the first account immediately using a Matrix client that supports
   registration tokens.
2. Use the token configured by `CONDUIT_REGISTRATION_TOKEN` or
   `registration_token`.
3. Confirm the account can log in.
4. Create the remaining friend accounts.
5. Disable registration when bootstrap is complete.

The MVP provisioning model is documented in
[`provisioning.md`](provisioning.md). Trix uses short operator-controlled
Conduit registration windows with a rotated token, then keeps the Apple client
login-only after accounts exist.

## Enable Or Disable Registration

During bootstrap:

```toml
allow_registration = true
registration_token = "replace-with-a-real-token"
```

After the private group is created:

```toml
allow_registration = false
```

Restart Conduit after changing the config:

```bash
docker compose restart conduit
```

## Backups

Conduit state lives in the `conduit-data` Docker volume. It contains the RocksDB
database and filesystem media path from `conduit.toml`.

Example cold backup:

```bash
cd server
docker compose stop conduit
docker run --rm \
  -v server_conduit-data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine \
  tar czf /backup/conduit-data-$(date +%Y%m%d%H%M%S).tgz -C /data .
docker compose start conduit
```

Test restore into a fresh volume before relying on backups.

## Notes

- Federation is disabled with `allow_federation = false`.
- Encryption is allowed with `allow_encryption = true`.
- The sample registration token is not a secret. Replace it before any reachable
  deployment.
- `emergency_password` is intentionally absent from the sample config.
- Do not commit edited `.env` files.
