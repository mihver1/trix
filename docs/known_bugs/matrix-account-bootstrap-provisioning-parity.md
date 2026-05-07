# Matrix: Account Bootstrap And Provisioning Parity

Status: Fixed in current docs; keep as regression guard.

## Summary

Legacy Trix has explicit first-device account bootstrap, admin provisioning
tokens, account linking, and server-side user management. Matrix deployment now
uses a smaller Matrix-native MVP model: short operator-controlled Conduit
registration windows protected by a rotated static token, followed by login in
the Trix Apple client.

## Legacy behavior to match

- Create account from the client when allowed.
- Support admin-created one-time provisioning tokens.
- Disable public registration while still allowing controlled account creation.
- Link new devices through trusted-device flows.
- Admin app can list, disable, reactivate, and provision users.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Onboarding/CreateAccountView.swift`
- `apps/macos-admin/README.md`
- `crates/trix-server/src/routes/admin.rs`
- `openapi/v0.yaml`

## Current Matrix state

- Conduit config has registration bootstrap settings and a registration token.
- `server/provisioning.md` documents the exact operator flow for creating new
  private users after registration has been disabled.
- `server/README.md`, `docs/security.md`, `docs/mvp-checklist.md`, and
  `apple/README.md` agree that the MVP Apple client is login-only.
- No Matrix operator app or Trix-specific Conduit admin wrapper is implemented
  for this slice.

## Required implementation

- MVP decision: use Conduit token registration windows, not a custom Trix
  account protocol or a resurrected `trixd` control plane.
- Account creation after registration is disabled is documented as: generate a
  fresh token, temporarily set `allow_registration = true`, restart Conduit,
  have the intended user register with an external Matrix client that supports
  registration tokens, set `allow_registration = false`, rotate the token, and
  restart Conduit.
- Client registration is not part of the MVP. The Apple client stays login-only.
- Full admin-app parity, including listing users and disable/reactivate flows,
  remains tracked in `matrix-admin-control-plane-parity.md`.

## Boundaries

- Do not commit real registration tokens or credentials.
- Do not make `allow_registration = true` the assumed long-term production mode.
- Do not implement a custom messaging protocol or custom account cryptography.

## Acceptance criteria

- [x] Docs state exactly how a new private user is created.
- [x] Docs state when and how registration is disabled.
- [x] Client UI and docs agree that self-registration does not exist in the
      Apple MVP.
- [x] The flow is written for `trix.selfhost.ru` without committing secrets.

## Verification plan

- Run the documented provisioning flow with disposable accounts only before
  claiming live provisioning validation.
- Verify the new user can log in to the Matrix Apple app.
- Verify registration can be disabled after bootstrap.
- Confirm no secrets are committed.
- `git diff --check`
