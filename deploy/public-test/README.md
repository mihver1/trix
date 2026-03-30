# Public Test Domain

This directory contains the staged ingress/TLS assets for the public test instance at `trix.artelproject.tech`.

## Files

- `docker-compose.public-test.yml`: compose overlay that adds `nginx` and `certbot`
- `nginx/entrypoint.sh`: renders an HTTP-only or HTTPS-enabled config at container start
- `nginx/http.conf.template`: HTTP bootstrap config for proxying traffic and serving ACME challenges
- `nginx/https.conf.template`: HTTPS config with HTTP-to-HTTPS redirect once certificates exist
- `certbot/run-certbot.sh`: default `certbot certonly --webroot` wrapper

## Expected Compose Flow

Run the public stack with the base project file plus this overlay:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/public-test/docker-compose.public-test.yml \
  up -d app nginx
```

This overlay assumes the repo-root `docker-compose.yml` is the first file in the `docker compose -f ...` chain, so the relative bind mounts resolve from the project root.

If the host also uses `docker-compose.override.yml`, keep that file last in the `docker compose -f ...` order so remote-only environment overrides win over the overlay defaults.

Issue a certificate once DNS resolves:

```bash
docker compose \
  -f docker-compose.yml \
  -f deploy/public-test/docker-compose.public-test.yml \
  --profile certbot \
  run --rm certbot
```

For a dry run against the Let's Encrypt staging CA:

```bash
CERTBOT_STAGING=1 docker compose \
  -f docker-compose.yml \
  -f deploy/public-test/docker-compose.public-test.yml \
  --profile certbot \
  run --rm certbot
```

Optional variables:

- `TRIX_PUBLIC_DOMAIN` defaults to `trix.artelproject.tech`
- `TRIX_TLS_READY=1` enables the HTTPS config once `/etc/letsencrypt/live/<domain>/fullchain.pem` and `privkey.pem` exist
- `CERTBOT_EMAIL` is optional; if empty, the helper uses `--register-unsafely-without-email`
- `CERTBOT_STAGING=1` opts into Let's Encrypt staging for dry runs

## Rollout Notes

- Keep `app` on `8080` during bootstrap while DNS and certificates settle.
- Set `TRIX_PUBLIC_BASE_URL` to the final `https://` domain only after HTTPS is actually reachable.
- ACME uses the shared `/var/www/certbot/.well-known/acme-challenge/` webroot mounted into both `nginx` and `certbot`.
