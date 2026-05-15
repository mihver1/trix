# Task: Apple Operator Health Dashboard

You are the next coding agent working in the Trix repo. Add an operator-only
health/diagnostic dashboard to Apple Settings without leaking admin credentials
or private message data.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/scripts/operator-control.sh`
- `server/xmpp/scripts/invite-registration-server.py`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/MockTrixService.swift`
- `apple/Sources/Shared/Views/TrixRoomListView.swift`
- `apple/Sources/macOS/TrixMacRootView.swift`

iOS and macOS Settings already show local redacted diagnostics: account, server,
room/invite/unread counts, push state, and device trust. Server-side
archive/upload/push health exists only through `operator-control.sh
archive-upload-push-health`.

## Goal

An operator can see private server health from Apple Settings:

- ejabberd/control-plane health;
- MAM/archive status;
- HTTP upload reachability;
- upload quota and media catalog size where available;
- push gateway reachability and registration count/status where available;
- backup freshness.

## Non-Goals

- Do not expose raw `mod_http_api` to Apple clients.
- Do not embed operator tokens, APNs credentials, XMPP passwords, or deployment
  secrets in the app bundle.
- Do not show decrypted message bodies, filenames, media keys, local decrypted
  paths, invite codes, or private key material.
- Do not make normal user Settings look like an admin console.

## Implementation Plan

1. Define a safe server-side diagnostics contract first:
   - new wrapper endpoint or local operator panel API, not raw `mod_http_api`;
   - bearer auth over private TLS or operator-local SSH tunnel;
   - JSON response with only redacted operational fields.
2. Suggested response shape:
   - `checked_at`;
   - `ejabberd_api`;
   - `mam`;
   - `http_upload`;
   - `upload_max_size_bytes`;
   - `upload_directory_size_bytes`;
   - `push_gateway`;
   - `push_registration_count` if the gateway can expose it safely;
   - `latest_backup_at`;
   - `latest_restore_verify_at` if automated CI writes a marker.
3. Implement an Apple service boundary:
   - `TrixOperatorDiagnosticsService` or equivalent;
   - mock implementation for previews/tests;
   - Keychain-backed storage for an operator endpoint/token if this is not
     purely local.
4. Add Settings UI:
   - macOS Diagnostics tab gets an "Operator" group when configured;
   - iOS Settings gets a compact operator diagnostics section only after opt-in;
   - refresh button with in-flight state;
   - clear error messages without raw URLs/tokens if sensitive.
5. Add a configuration flow:
   - paste private diagnostics URL;
   - paste bearer token into a secure field;
   - test connection;
   - clear operator configuration.
6. Keep push/APNs hygiene:
   - display generic gateway status;
   - do not display APNs tokens, device tokens, private key paths, or payloads.
7. Update docs:
   - `docs/security.md` local diagnostics risk;
   - `server/xmpp/README.md` operator diagnostics endpoint;
   - `apple/README.md` if it documents Settings behavior.

## Acceptance Criteria

- Apple Settings can show configured operator diagnostics from a safe wrapper
  endpoint.
- Without operator configuration, normal Settings remains redacted and
  user-focused.
- Tokens are stored securely and are not printed in diagnostics or logs.
- No decrypted content, filenames, media keys, invite codes, APNs tokens, or
  private key paths are displayed.
- iOS and macOS builds still pass.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run a mocked diagnostics refresh test and, if a private wrapper endpoint is
available, one scrubbed live diagnostics fetch.
