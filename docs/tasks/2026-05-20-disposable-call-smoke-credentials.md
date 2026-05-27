# TRI-21 Disposable Encrypted-Call Credentials

This runbook records a reproducible operator flow for disposable call-smoke
accounts needed by [TRI-18](/TRI/issues/TRI-18).

It is intentionally secret-free. Do not place passwords, invite codes, or
tokens in this file or in issue comments.

## Scope

- Provision 10 disposable XMPP accounts on `trix.selfhost.ru`.
- Reserve sets for:
  - DM pair (2 accounts)
  - 3-user group smoke (3 accounts)
  - 10-user group smoke (10 accounts total; includes DM+3-user accounts)
  - optional live call echo assistant (1 additional account)
- Keep credential handoff outside the repo.
- Define cleanup steps and verification commands.

## Operator Provisioning (Loopback API)

Run on the XMPP host (or over an explicit private tunnel) where
`server/xmpp/scripts/operator-control.sh` can reach loopback `mod_http_api`.

```bash
cd /opt/trix-xmpp/server/xmpp

mkdir -p /run/secrets/trix/tri21
chmod 700 /run/secrets/trix/tri21

# Generate disposable passwords with local-only file permissions.
for name in tri21dm1 tri21dm2 tri21g31 tri21g32 tri21g33 tri21g101 tri21g102 tri21g103 tri21g104 tri21g105 tri21echo; do
  LC_ALL=C tr -dc 'A-Za-z0-9-_' </dev/urandom | head -c 32 >"/run/secrets/trix/tri21/${name}.password"
  chmod 600 "/run/secrets/trix/tri21/${name}.password"
done

# Provision accounts through checked-in operator command.
for name in tri21dm1 tri21dm2 tri21g31 tri21g32 tri21g33 tri21g101 tri21g102 tri21g103 tri21g104 tri21g105 tri21echo; do
  ./scripts/operator-control.sh provision-user "$name" "/run/secrets/trix/tri21/${name}.password"
done
```

## App-Facing Invite Provisioning (Authenticated Wrapper)

When the operator API is not directly available, use authenticated
`/v1/invites` + `/v1/registration/redeem` through `invite-registration-server.py`
with deployment-local bootstrap credentials.

High-level flow:

1. `POST /v1/invites` (Basic auth, one invite per reserved localpart)
2. `POST /v1/registration/redeem` (invite code + localpart + password)
3. Store account IDs/passwords in a local secret file with `0600` permissions

This stays operator-controlled because public XMPP registration remains disabled.

## Authentication Verification

Minimum verification:

1. Confirm each account can authenticate over XMPP STARTTLS/SASL PLAIN against
   `trix.selfhost.ru:5222`.
2. Confirm app login with a signed build in target environment:

```bash
TRIX_XMPP_LIVE_SMOKE_MODE=login \
TRIX_XMPP_LIVE_SMOKE_USER_ID='<user>@trix.selfhost.ru' \
TRIX_XMPP_LIVE_SMOKE_PASSWORD='<password>' \
/path/to/Trix.app/Contents/MacOS/Trix
```

Expected smoke token:

- `TRIX_XMPP_LIVE_SMOKE login ok user=<user>@trix.selfhost.ru ...`

## Secure Handoff

- Store credential package outside the git workspace.
- Use `0600` for credential files and `0700` for parent directories.
- Share only the local secure path/process in issue comments.
- Never post secrets in [TRI-21](/TRI/issues/TRI-21) or [TRI-18](/TRI/issues/TRI-18)
  comments.

## Cleanup Plan

After call smoke completes (or at expiry), disable or delete all disposable
accounts through operator-controlled commands.

```bash
cd /opt/trix-xmpp/server/xmpp

for name in tri21dm1 tri21dm2 tri21g31 tri21g32 tri21g33 tri21g101 tri21g102 tri21g103 tri21g104 tri21g105 tri21echo; do
  ./scripts/operator-control.sh disable-user "$name" "TRI-21 disposable cleanup"
done

# Optional hard delete via ejabberd API:
# curl -fsS -X POST -H 'Content-Type: application/json' \
#   --data '{"user":"tri21dm1","host":"trix.selfhost.ru"}' \
#   "$TRIX_XMPP_API_URL/unregister"
```
