# Feature Flags

Feature flags are runtime product configuration for Trix clients and the admin
app. They are not a security boundary and must never contain secrets.

## Data Model

`trix-admin-api` stores a JSON snapshot:

```json
{
  "version": 1,
  "updated_at_unix": 0,
  "flags": [
    {
      "key": "client.calls.encrypted_media",
      "enabled": false,
      "rollout_percentage": 0,
      "client_visible": true,
      "description": "Gates signed-device encrypted media-call surfaces.",
      "updated_at_unix": 0
    }
  ]
}
```

Fields:

- `key`: lowercase ASCII namespace such as `client.calls.encrypted_media`.
- `enabled`: global on/off gate.
- `rollout_percentage`: deterministic percentage bucket from `0` to `100`.
- `client_visible`: whether `/v1/feature-flags/snapshot` exposes the flag.
- `description`: operator-facing context, never a secret.
- `updated_at_unix`: server-side update timestamp.

## Client Use

Apple clients use `TrixFeatureFlagSnapshot`, `TrixFeatureFlag`, and
`TrixFeatureFlagEvaluator` from `apple/Sources/SharedFeatureFlags`.

Recommended pattern:

```swift
let evaluator = TrixFeatureFlagEvaluator(snapshot: snapshot)
let context = TrixFeatureFlagContext(stableID: accountID)
let enabled = evaluator.isEnabled("client.calls.encrypted_media", context: context)
```

Use a stable account-level identifier for rollout bucketing. Do not use device
randomness, current time, or session ids; those make rollouts jump between app
launches.

If the snapshot cannot be loaded, clients should use checked-in safe defaults.
For features that affect encryption, trust, privacy, or server exposure, the
safe default is off.

## Change Flow

1. Pick a namespaced key:
   `client.<area>.<feature>`, `admin.<area>.<feature>`, or
   `server.<area>.<feature>`.
2. Add the code path behind `TrixFeatureFlagEvaluator`.
3. Add or update a focused test that proves the disabled and enabled behavior.
4. Document the flag in this file if it gates user-visible behavior, deployment
   risk, E2EE/trust behavior, or server exposure.
5. Use the admin app to create the flag with `enabled=false`,
   `rollout_percentage=0`, and `client_visible=false`. Flip
   `client_visible=true` only when the client needs to see it.
6. Roll out by raising `rollout_percentage`, then switch `enabled=false` to
   stop the feature quickly if needed.
7. Confirm the admin app audit trail shows the create/update/delete event
   without secrets or request bodies.
8. Run `server/xmpp/scripts/admin-api-smoke.sh` after changing the server flag
   store, admin routes, audit behavior, or client-visible filtering.
9. Remove stale flags after the feature is permanently on or permanently
   abandoned.

## Current Flags

- `admin.users`: server/admin-app flag for user-management controls. It is not
  client-visible.
- `client.calls.encrypted_media`: client-visible gate for signed-device
  encrypted media-call surfaces. Keep the default off until the signed-device
  call gate in `docs/mvp-checklist.md` is closed.

## Safety Rules

- Do not store passwords, tokens, APNs material, TURN credentials, OMEMO state,
  media keys, or private endpoint URLs in flags.
- Do not use flags to bypass OMEMO, trust, plaintext-send, account-auth, or
  federation-off requirements.
- Do not make a flag the only guard around an unsafe server route. Server-side
  authorization and network binding still have to enforce the boundary.
- Treat flag descriptions as log-visible operator text.
- Keep flag defaults conservative in checked-in client code.
