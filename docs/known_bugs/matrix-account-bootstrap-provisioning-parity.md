# Matrix: Account Bootstrap And Provisioning Parity

Status: Open.

## Summary

Legacy Trix has explicit first-device account bootstrap, admin provisioning
tokens, account linking, and server-side user management. Matrix deployment now
relies on Conduit registration/admin behavior and manual bootstrap docs. The
product needs a clear Matrix-native provisioning story before parity is claimed.

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
- Docs say the first Conduit user becomes admin, create friend accounts, then
  disable registration.
- No Matrix operator app or provisioning UI is documented.
- Matrix Apple app has login/restore/logout only.

## Required implementation

- Decide the MVP provisioning model: manual Conduit admin, Matrix registration
  token, admin API wrapper, or a small Trix-specific operator script.
- Document the exact account creation flow for real users after registration is
  disabled.
- If client registration is required, add Matrix auth service support and UI.
- If admin-only provisioning is chosen, add a documented command/operator flow
  and keep the client login-only.
- Keep server scope aligned with Conduit; do not rebuild legacy `trixd`.

## Boundaries

- Do not commit real registration tokens or credentials.
- Do not make `allow_registration = true` the assumed long-term production mode.
- Do not implement a custom messaging protocol or custom account cryptography.

## Acceptance criteria

- Docs state exactly how a new private user is created.
- Docs state when and how registration is disabled.
- Client UI and docs agree on whether self-registration exists.
- The flow works with `trix.selfhost.ru` without exposing secrets.

## Verification plan

- Run the documented provisioning flow with disposable accounts only.
- Verify the new user can log in to the Matrix Apple app.
- Verify registration can be disabled after bootstrap.
- Confirm no secrets are committed.
- `git diff --check`
