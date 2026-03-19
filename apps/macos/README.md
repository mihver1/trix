# macOS App Scaffold

The first client target is `macOS`.

This repository does not yet include an `Xcode` project. The app-side scaffold is split into:

- `trix-core` for shared Rust-side client logic
- future `UniFFI` bindings for Swift
- future native `SwiftUI` app target living in this directory

## Planned Layout

```text
apps/macos/
  TrixMac.xcodeproj
  TrixMac/
    App/
    Features/
    Bridge/
    Resources/
```

## Planned Responsibilities

- `App/` app lifecycle, environment, navigation
- `Features/` chat list, conversation, attachments, settings, device linking
- `Bridge/` Swift wrappers around generated Rust FFI bindings
- `Resources/` assets, previews, localization

## Next App Tasks

- generate a minimal Swift binding surface from `trix-core`
- create the `Xcode` project
- wire `health` and `version` endpoints
- add local secure storage integration through `Keychain`
