# Trix macOS Admin

`apps/macos-admin` is the macOS admin control app: a `SwiftPM` executable target that will talk to the Trix server over HTTP (no `trix-core` / Rust FFI).

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

`project.yml` does not set `DEVELOPMENT_TEAM` so the repo stays portable for other machines and CI. Xcode's default "Sign to Run Locally" flow is enough for local `xcodebuild test`. For explicit team-based signing, pick your team under **Signing & Capabilities** in Xcode or pass `DEVELOPMENT_TEAM` on the `xcodebuild` command line.

## Bundle identity

- App bundle ID: `com.softgrid.trixadmin` (distinct from the consumer app `com.softgrid.trixapp`).
- Keychain and app-support naming use `AppIdentity` in `Sources/TrixMacAdmin/Support/AppIdentity.swift`.
