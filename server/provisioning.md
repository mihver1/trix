# Matrix User Provisioning

This is the MVP provisioning model for the private Matrix deployment.

Trix does not run a separate Matrix admin control plane yet. New users are
created through short operator-controlled Conduit registration windows protected
by a high-entropy registration token. The Apple Matrix client stays login-only:
users register with a Matrix client that supports `m.login.registration_token`,
then log in to Trix with the created Matrix account.

This deliberately does not recreate legacy `trixd` provisioning tokens. Conduit
uses a static registration token while registration is enabled, so the operator
must rotate it for each provisioning window and disable registration immediately
after the intended user has registered.

## Bootstrap The First Admin

1. Start Conduit with registration enabled and a real token in the
   deployment-local `conduit.toml`.
2. Register the first account immediately. Conduit treats the first user as the
   admin.
3. Confirm the admin can log in to Trix.
4. Disable registration if no more users are being created in the same window.

Do not commit the deployment-local token or edited production config.

## Add A User After Registration Is Disabled

Generate a fresh token on the deployment host:

```bash
python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
```

Edit the deployment-local `server/conduit.toml`:

```toml
allow_registration = true
registration_token = "paste-the-fresh-token-here"
```

Restart Conduit:

```bash
cd server
docker compose restart conduit
```

Use `podman compose restart conduit` when the deployment uses Podman.

Give the user these values through an out-of-band private channel:

- Homeserver: `https://trix.selfhost.ru`
- Matrix server name: `trix.selfhost.ru`
- Their chosen username, for example `alice`
- The registration token for this provisioning window

The user registers with Element Web, Nheko, SchildiChat, or another Matrix
client that supports registration tokens. The resulting Matrix ID should look
like `@alice:trix.selfhost.ru`.

After the user has registered, close the registration window:

```toml
allow_registration = false
registration_token = "rotate-before-next-window"
```

Restart Conduit again:

```bash
cd server
docker compose restart conduit
```

Verify registration is closed without using the real token:

```bash
curl -sS -o /tmp/trix-registration-token-check.json -w '%{http_code}\n' \
  'https://trix.selfhost.ru/_matrix/client/v1/register/m.login.registration_token/validity?token=not-the-real-token'
```

When registration is disabled, the expected status is `403`.

Finally, have the user log in to the Trix Apple client with the new Matrix ID
and password. Trix should not need the registration token after the account
exists.

## Current Limitations

- There is no Matrix self-registration UI in the Trix Apple client.
- There is no Matrix admin app or Trix-specific Conduit admin wrapper.
- Conduit static registration tokens are not one-time tokens. The safe MVP
  behavior is a short registration window plus immediate token rotation.
- Disable/reactivate, user listing, and richer operator workflows remain tracked
  by `docs/known_bugs/matrix-admin-control-plane-parity.md`.
