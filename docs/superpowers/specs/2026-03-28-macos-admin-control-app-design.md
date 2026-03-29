# macOS Admin Control App Design

## Summary

This design adds a separate internal `SwiftUI` macOS application for operator workflows across multiple clusters. The app is not a distributed end-user product; it is a local service tool that stores several cluster profiles, lets an operator switch between them, and performs user administration plus server-level settings changes against a dedicated admin API.

The chosen `v1` shape is intentionally simple:

- one admin app shell
- direct cluster switching in the UI
- user lifecycle administration with operator provisioning plus `disable` / `reactivate`
- registration and server settings management
- a separate backend admin surface under `/v0/admin/*`

## Context

The repository already contains a `SwiftUI` macOS client in `apps/macos`, but that app is a consumer chat client with onboarding, session restore, directory-backed messaging, device approval, and advanced operational tooling for the signed-in account holder. It is not an operator console.

The backend already exposes `v0` endpoints for accounts, auth, devices, chats, and system health, but it does not yet expose a dedicated server-admin API surface or a multi-cluster operator workflow. Admin-control automation is explicitly outside the current bot surface, and there is no existing top-level admin app package in the repository.

That makes a separate internal admin tool the lowest-risk path:

- it avoids mixing end-user chat UX with operator workflows
- it reuses established macOS `SwiftUI` patterns from `apps/macos`
- it keeps `v1` small by connecting directly to each cluster instead of introducing a full central control plane

## Goals

- Create a separate internal macOS admin app with a simple `SwiftUI` shell.
- Let an operator store and switch between multiple cluster profiles.
- Provide user administration for the selected cluster.
- Provide server settings management for the selected cluster.
- Allow operators to enable or disable new registration per cluster.
- Allow operators to provision user access without bypassing end-user cryptographic bootstrap.
- Keep credentials local to the machine and avoid any external distribution requirements.
- Define a backend admin API shape that is clearly separated from consumer APIs.

## Non-Goals

- No central multi-tenant control-plane service in `v1`.
- No attempt to merge admin workflows into the existing consumer `apps/macos` app.
- No signed distribution, App Store work, or public packaging requirements.
- No enterprise-grade RBAC matrix, multi-admin collaboration, or full audit platform in `v1`.
- No hard delete for user accounts in `v1`.
- No server-generated account root keys or synthetic first-device identity on behalf of end users.
- No GUI for low-level static infrastructure configuration that still belongs in environment variables or deploy-time config.

## Decision Summary

The chosen direction is:

1. Build a separate macOS admin app instead of extending the existing consumer client.
2. Use a sidebar cluster switcher with a tabbed operator workspace for the active cluster.
3. Store multiple cluster profiles locally and maintain a separate admin session per cluster.
4. Call each cluster directly from the admin app rather than routing through a central control-plane backend.
5. Add a distinct backend namespace under `/v0/admin/*` for all operator functions.
6. Treat user removal as `disable` / `reactivate`, not hard delete.
7. Define `disable` as a soft-disable that:
   - removes the account from the user-facing directory
   - blocks new logins and pending-device registration
   - revokes active sessions
   - preserves account data for later operator inspection or reactivation
8. Treat "create user" as an operator provisioning flow that prepares user access, but does not bypass the existing cryptographic bootstrap requirements of the first client device.
9. Limit registration control in `v1` to a single explicit runtime flag such as `allow_public_account_registration`.
10. Limit server settings in `v1` to DB-backed runtime-administered settings that are safe to mutate through the API.

## Architecture

### 1. App Boundary

The new admin tool should be a separate app target and package, distinct from `apps/macos`. It is an operator console, not a chat client with an "admin mode."

That separation is important for both product clarity and safety:

- the navigation model is cluster-first, not conversation-first
- the session model is admin-authenticated, not account-authenticated
- operator actions must always show explicit cluster context before writes
- the UI can stay simple and utilitarian instead of inheriting consumer-client behavior

The recommended repository shape is a dedicated app slice such as `apps/macos-admin`, following the same general `SwiftUI` project conventions already used by `apps/macos` where they remain useful.

### 2. Runtime Model

The admin app keeps a local list of `ClusterProfile` records. Each profile contains:

- stable local identifier
- display name
- base URL
- environment label such as `prod`, `staging`, or `dev`
- admin auth mode metadata
- non-secret UI preferences

`v1` should support one concrete admin login flow even if the model leaves room for more later. The recommended flow is:

1. the operator selects a cluster profile
2. the operator enters a cluster-local admin identifier and secret
3. `POST /v0/admin/session` exchanges those credentials for a short-lived admin JWT
4. the token, expiry, and related secret material are stored in `Keychain`

This admin JWT is separate from the consumer device JWT used in `/v0/auth/session`. It should use a distinct claim shape and auth principal so admin tokens are never accepted on consumer routes.

The active cluster controls all data shown in the workspace. Switching clusters fully swaps:

- the active admin session
- overview metrics
- user search results
- user detail data
- registration policy state
- server settings state

The app must make the active cluster impossible to miss. Cluster name and environment should remain visible in the window chrome or main header, and every mutating action should repeat the target cluster name in its confirmation UI.

### 3. Information Architecture

`v1` uses a simple shell:

- left sidebar for cluster selection and cluster management
- main workspace for the currently selected cluster
- top summary row for health, registration state, and active session status
- tabbed or segmented sections for the operator surfaces

The `v1` operator surfaces are:

1. `Overview`
   - cluster health
   - backend version
   - registration state
   - user count and high-level stats
2. `Users`
   - searchable table by `account_id`, handle, or profile name
   - filters by status
   - fast actions
3. `User Detail`
   - profile summary
   - current state
   - device list
   - admin actions
4. `Provision User`
   - launched from the `Users` area instead of a separate top-level tab
   - creates a pending operator-managed user provision record and onboarding artifact
5. `Registration`
   - registration on/off
   - a single runtime flag such as `allow_public_account_registration`
6. `Server Settings`
   - safe DB-backed runtime-managed settings only

`User Detail` and `Provision User` are subflows inside the `Users` workspace, not separate primary navigation destinations. `Diagnostics` stays folded into `Overview` in `v1` so the first version remains centered on user administration plus server settings.

### 4. User Lifecycle Semantics

The admin app exposes CRUD-like account management, but `v1` deliberately replaces hard delete with reversible account disabling.

The user operations are:

- `Provision`
- `Read`
- `Update`
- `Disable`
- `Reactivate`

`Provision` must respect the current repository reality: `POST /v0/accounts` is a cryptographic bootstrap path that requires client-generated credential identity, account-root keys, signatures, and transport keys. The admin tool should not fabricate those artifacts on the user's behalf.

That means "create user" in `v1` is an operator provisioning flow, not a server-side manufacture of a fully active account. The admin backend should create a pending provision record and onboarding artifact, and the user's first real client still completes the cryptographic bootstrap before the account becomes active.

`Update` in `v1` should be limited to fields that are safe for operators to change without rewriting deeper account state. The exact field set is an implementation detail, but it should stay intentionally narrow.

`Disable` is the key lifecycle decision. In `v1`, disabling an account means:

1. the account no longer appears in the end-user directory
2. the account is excluded from directory search and related discovery paths
3. new sign-ins are blocked
4. new device-link or pending-device registration is blocked
5. active HTTP sessions are invalidated and must no longer authorize requests
6. existing WebSocket sessions for that account are actively closed server-side
7. the account remains visible in the admin tool with a `disabled` status
8. account data is preserved so an operator can inspect or reactivate it later

`Reactivate` reverses those policies and returns the account to normal directory visibility and login eligibility.

This lifecycle gives the admin tool a safe default for operational response without introducing irreversible deletion into the first version.

To stay compatible with the current schema, `disable` should not reuse `accounts.deleted_at`. The repository already uses `deleted_at` as the existing "gone" gate for directory and session checks, while `v1` requires reversible suspension plus admin visibility. The backend should therefore add a dedicated reversible account status field or equivalent policy record, and consumer gates such as directory queries and `ensure_active_device_session` should check that status in addition to the existing account/device constraints.

### 5. Backend Admin Surface

The admin app should not piggyback on consumer-facing account APIs with hidden parameters. `v1` needs a dedicated backend namespace with separate auth and permission checks.

The admin auth model for `v1` is:

- cluster-local admin credentials configured out of band
- `POST /v0/admin/session` exchanges those credentials for a short-lived admin JWT
- the admin JWT uses a distinct claim type and principal from consumer account/device tokens
- admin JWTs are accepted only on `/v0/admin/*`
- consumer JWTs are never accepted on `/v0/admin/*`

The recommended shape is:

- `POST /v0/admin/session`
- `DELETE /v0/admin/session`
- `GET /v0/admin/overview`
- `GET /v0/admin/users?q=&status=&cursor=&limit=`
- `GET /v0/admin/users/{account_id}`
- `POST /v0/admin/users`
- `PATCH /v0/admin/users/{account_id}`
- `POST /v0/admin/users/{account_id}/disable`
- `POST /v0/admin/users/{account_id}/reactivate`
- `GET /v0/admin/settings/registration`
- `PATCH /v0/admin/settings/registration`
- `GET /v0/admin/settings/server`
- `PATCH /v0/admin/settings/server`
- `GET /v0/admin/diagnostics` is deferred from `v1`

`GET /v0/admin/users` should support cursor pagination and stable sorting so the macOS app can render large result sets safely. The default sort can be reverse creation order or another stable admin-facing order, but the contract must be explicit.

`POST /v0/admin/users` is defined as "provision a user" rather than "create a cryptographically complete account." Its response should return the pending provision record and whatever onboarding artifact the first real client needs to finish account bootstrap.

`PATCH /v0/admin/users/{account_id}` should be constrained to admin-safe fields only. `disable` and `reactivate` should remain explicit action endpoints rather than overloaded status patches.

When an account is disabled, the backend must revoke authorization in two ways:

1. authenticated HTTP routes must fail through the same active-session gate that already checks account and device activity
2. the server must actively close live WebSocket sessions for the disabled account's active devices, which likely requires extending `WebSocketSessionRegistry` with an account-scoped close helper or equivalent fan-out path

This separation keeps the consumer API surface clean and makes future permissioning easier. It also makes it possible to introduce a later control-plane backend without rewriting the admin app's core domain concepts.

### 6. Server Settings Scope

`Server Settings` in `v1` does not mean arbitrary infra control. The admin GUI should manage only settings that are:

- conceptually operator-owned
- safe to change at runtime
- understandable without shell access
- reversible through the same UI

These settings should be backed by a runtime-admin settings store, not by the current process-level `AppConfig` environment variables such as bind address, database URL, blob root, or JWT signing key.

Examples of acceptable `v1` settings include:

- brand label or public display text
- support contact metadata
- policy text shown to clients
- bounded feature flags that are explicitly modeled as runtime-managed admin settings

Settings that still require process restart, deploy-time secrets, or low-level infrastructure coordination should remain outside this tool.

### 7. Auth And Local Storage

Each cluster has its own admin session. Secrets and credentials should be stored in `Keychain`. Non-secret app state should live under app-controlled local storage, such as `Application Support`.

The admin app should remember:

- cluster profiles
- last selected cluster
- non-secret UI preferences
- cached read models where useful for responsiveness

It should not silently reuse stale admin state. If a session expires or is revoked, the active cluster should clearly fall back to an unauthenticated or reconnect-required state.

`ClusterProfile.authMode` exists to avoid painting the UI model into a corner, but `v1` should implement only the single credential-exchange flow described above. Additional auth modes can be added later without changing the basic cluster-switching model.

### 8. Safety And Error Handling

Operator writes must favor safety over speed.

The UI should:

- require confirmation for destructive or high-impact actions
- display the target cluster name in confirmations
- avoid optimistic success UI for write operations
- refetch canonical state after successful mutations
- surface partial-failure states explicitly

Typical dangerous flows include:

- disabling a user
- reactivating a user
- changing registration policy
- mutating cluster-wide settings

For cluster switching, the app should cancel or invalidate stale in-flight requests tied to the previous cluster so the workspace never renders mixed-cluster data.

## Testing Strategy

`v1` should be validated with both backend and macOS coverage.

### Backend

- integration tests for admin session creation and authorization
- tests for provision/read/update paths
- tests that consumer JWTs cannot call `/v0/admin/*` and admin JWTs cannot call consumer routes
- tests for `disable` behavior:
  - directory exclusion
  - blocked sign-in
  - blocked device registration
  - active-session invalidation
  - active WebSocket closure
- tests for `reactivate`
- tests for registration toggle and server setting mutations
- tests for user search filters, cursor pagination, and stable ordering
- tests that `/v0/admin/*` is represented in `openapi/v0.yaml`

### macOS App

- smoke tests for cluster switching
- UI or presentation tests for user search and user detail rendering
- tests for disable/reactivate confirmations and result handling
- tests for provisioning flow and resulting pending state presentation
- tests for registration toggle and server settings edit flows
- tests for expired-session handling and cluster reconnect UX

### Manual Validation

- configure at least two cluster profiles, such as `staging` and a production-like local environment
- verify that switching clusters always changes the visible state and mutation target
- verify that disabling a user removes the account from directory search on the affected cluster
- verify that disabling the same user on one cluster has no effect on another cluster

## Risks And Mitigations

### Risk: cluster-targeting mistakes cause writes against the wrong environment

Mitigation: persistent active-cluster banner, environment labels, and explicit confirmation dialogs that repeat the cluster name.

### Risk: the tool grows into an implicit control plane without the supporting backend model

Mitigation: keep `v1` direct-to-cluster, constrain the feature set, and preserve clean domain objects such as `ClusterProfile`, `AdminSession`, `RegistrationSettings`, and `AdminUserDetail` for future migration.

### Risk: disable semantics are inconsistent across directory, auth, and session layers

Mitigation: define `disable` centrally in the admin backend, avoid overloading `deleted_at`, and test all related HTTP and WebSocket paths together instead of scattering partial checks across routes.

### Risk: server settings UI exposes configuration that is not safely mutable at runtime

Mitigation: restrict `v1` to DB-backed runtime-administered settings only and keep `AppConfig` environment fields, deploy-time secrets, and restart-required config out of scope.

### Risk: "create user" conflicts with the current cryptographic bootstrap contract

Mitigation: model the operator flow as provisioning plus onboarding, and keep first-device cryptographic bootstrap in the real client flow instead of synthesizing root keys on the server.

### Risk: admin auth drifts into the consumer token model

Mitigation: use a separate admin claim type, principal, and route gate under `/v0/admin/*` from the start.

### Risk: reusing too much consumer-client code drags chat-specific assumptions into the admin tool

Mitigation: create a separate app boundary and only reuse lower-level platform patterns or support utilities where the abstractions truly match.

## Validation Plan

- confirm the admin app remains a separate macOS target and package
- verify cluster switching and cluster-scoped sessions using at least two backend profiles
- verify admin API authorization boundaries under `/v0/admin/*`
- verify `/v0/admin/*` is documented in `openapi/v0.yaml`
- verify disabled accounts disappear from the directory and lose active authorization
- verify active WebSocket sessions for disabled accounts are closed
- verify server setting mutations only cover runtime-safe settings
- verify dangerous actions require explicit confirmation and update the UI from canonical server state
