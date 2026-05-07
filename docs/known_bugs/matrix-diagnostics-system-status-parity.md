# Matrix: Diagnostics And System Status Parity

Status: Open.

## Summary

Legacy Trix exposes safe diagnostics, server health/version, connection state,
local state panels, and debug metrics. Matrix Apple currently has live-smoke
documentation and visible verification limitations, but no in-app diagnostics
or system status surface.

## Legacy behavior to match

- iOS exposes safe diagnostic logs and system status.
- macOS exposes connection/local-state panels and projection diagnostics.
- Admin tooling exposes debug metrics.
- Diagnostics avoid leaking secrets.

Relevant legacy entry points:

- `apps/ios/TrixiOS/Features/Home/DiagnosticsLogView.swift`
- `apps/ios/TrixiOS/Features/SystemStatus/SystemStatusView.swift`
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- `apps/macos-admin/Sources/TrixMacAdmin/Features/DebugMetrics/DebugMetricsWorkspaceView.swift`

## Current Matrix state

- Matrix app has user-facing verification/recovery limitations.
- Live smoke prints only `TRIX_LIVE_SMOKE` status lines.
- No in-app diagnostics panel was found.

## Required implementation

- Add a Matrix diagnostics/settings surface for connection status, homeserver
  URL, sync state, SDK store state, push state, and verification state.
- Reuse or adapt safe diagnostic log redaction patterns from legacy clients.
- Add explicit "copy diagnostics" behavior only if secrets are redacted.
- Keep raw SDK errors available to developers without showing tokens or message
  bodies.

## Boundaries

- Do not log Matrix access tokens, passwords, registration tokens, recovery
  keys, decrypted bodies, APNs tokens, or private keys.
- Do not add telemetry.
- Do not expose internal event JSON to end users unless redacted.

## Acceptance criteria

- iOS and macOS have a visible diagnostics/status entry.
- The panel shows current account, homeserver, sync, push, and verification
  status without secrets.
- User-facing errors include enough detail to debug generic failures.
- Redaction tests or manual checks confirm secret strings are not printed.

## Verification plan

- Build iOS and macOS Matrix targets.
- Trigger an offline/network failure and confirm diagnostics are useful.
- Confirm logs stay redacted during login, send, attachment, and recovery flows.
- `git diff --check`
