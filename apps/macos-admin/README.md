# Trix macOS Admin

`apps/macos-admin` is the macOS admin control app. It is a separate `SwiftUI`/`SwiftPM` operator app that talks to the Trix backend over HTTP only; it does not use `trix-core` or the consumer FFI layer.

## Current Scope

- multi-cluster profile sidebar with persisted selection
- per-cluster admin JWT sessions stored in `Keychain`
- overview workspace for service/build/runtime status
- registration settings workspace for the public self-service toggle
- server settings workspace for brand/support/policy text
- user list with search, status filtering, and cursor pagination
- user detail, provision, disable, and reactivate flows
- request coordination that cancels in-flight workspace loads when the active cluster changes

The app targets the `/v0/admin/*` surface documented in [`openapi/v0.yaml`](../../openapi/v0.yaml).

## Backend Requirements

The backend must start with the admin auth env configured. The repo-root `.env.example` already includes the required development values:

- `TRIX_ADMIN_USERNAME`
- `TRIX_ADMIN_PASSWORD`
- `TRIX_ADMIN_JWT_SIGNING_KEY`
- `TRIX_ADMIN_SESSION_TTL_SECONDS`

The app expects a reachable backend whose base URL resolves the admin routes, for example `http://127.0.0.1:8080/` locally or the staged public host over `https://`.

## Layout

```text
apps/macos-admin/
  Package.swift
  project.yml
  Sources/TrixMacAdmin/
    App/
    Features/
    Support/
  Tests/TrixMacAdminTests/
  TrixMacAdminUITests/
```

## Swift Package Manager

```bash
cd apps/macos-admin
swift build
swift run
swift test
```

## Xcode project (XcodeGen)

Regenerate the committed Xcode project after changing `project.yml`:

```bash
xcodegen generate --spec apps/macos-admin/project.yml
```

Open `TrixMacAdmin.xcodeproj` and run the `TrixMacAdmin` scheme.

Build-only verification can stay unsigned:

```bash
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO
```

UI tests need the default local signing path so the `TrixMacAdminUITests-Runner.app` can launch under macOS automation:

```bash
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" test
```

Repo-root smoke entrypoint:

```bash
./scripts/client-smoke-harness.sh --suite macos-admin --no-postgres
```

`project.yml` does not set `DEVELOPMENT_TEAM` so the repo stays portable for other machines and CI. Xcode's default "Sign to Run Locally" flow is enough for local `xcodebuild test`. For explicit team-based signing, pick your team under **Signing & Capabilities** in Xcode or pass `DEVELOPMENT_TEAM` on the `xcodebuild` command line.

## Bundle identity

- App bundle ID: `com.softgrid.trixadmin` (distinct from the consumer app `com.softgrid.trixapp`).
- Keychain and app-support naming use `AppIdentity` in `Sources/TrixMacAdmin/Support/AppIdentity.swift`.
