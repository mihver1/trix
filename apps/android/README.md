# Android Client Scaffold

This directory now contains a standalone Android project for the future Trix client.

## Direction

- Kotlin + Jetpack Compose first, not KMP or Flutter
- native adaptive layouts for phone, tablet, foldable, and resizable windows
- native Android shell first, with Rust FFI now used where the boundary has stabilized
- messaging-first UX using canonical Android patterns instead of a single stretched phone screen

## Current Layout Decisions

- top-level navigation adapts by width:
  - compact: bottom navigation bar
  - medium: navigation rail
  - expanded: permanent drawer
- chats use a list-detail pattern on wider windows
- foldables are posture-aware through `WindowManager`
  - book posture keeps panes side by side
  - tabletop posture avoids putting the transcript and compose area across the hinge
- secure-app defaults start conservative:
  - Android backup disabled in the manifest
  - no cloud restore assumptions for device keys

## Why The Boundary Is Split

The UI, lifecycle, adaptive navigation, and Android-secure local persistence still belong on the platform side. The Rust boundary is now useful for:

- account root and transport Ed25519 key material
- server transport calls already exposed via `FfiServerApiClient`
- encrypted local chat/sync state through `FfiClientStore` on top of a single `state-v1.db`
- MLS state and persistent group storage through `FfiMlsFacade`
- realtime websocket delivery through `FfiRealtimeDriver`

The Android project now generates Kotlin bindings from UniFFI during the Gradle build and cross-compiles `libtrix_core.so` for `arm64-v8a` and `x86_64` via `cargo ndk`.

## Why Kotlin-First Around It

The better tradeoff for this PoC is still:

1. ship a real Android-native shell with adaptive UX
2. move the narrow, already-stable crypto/transport surfaces behind Rust FFI
3. keep windowing, session orchestration, and device-local UX native on Android

## Next Android Tasks

- bridge canonical MLS `group_id` from the backend into Android so local state matches cross-device traffic
- extend the current text send path into attachments, receipts, and commit/welcome handling
- implement device linking and trusted-device approval flows on top of the FFI server client

## Current Live Flow

- create a new account from Android
- scan a QR code or paste/share a raw device-link payload from another trusted client and register a pending Android device
- generate local `account root` and `transport` Ed25519 key material through `trix-core` FFI
- generate persistent MLS key packages locally during linked-device bootstrap through `FfiMlsFacade`
- encrypt a transfer bundle for the pending device during trusted-device approval, so account-root material can move without passing through the server in plaintext
- sign the bootstrap payload expected by the backend through Rust key material
- open an auth challenge/session for the stored device through `FfiServerApiClient`
- auto-import the encrypted transfer bundle on the first successful reconnect after approval, promoting the linked Android client into a full trusted device
- persist bootstrap state locally in an encrypted file protected by Android Keystore
- generate a per-device SQLCipher key on Android, wrap it with Android Keystore, and open the shared Rust-owned `state-v1.db`
- restore a saved device session on app launch
- migrate legacy JSON/plaintext SQLite caches into the encrypted `state-v1.db` on first open
- sync cached chats and inbox items into the local Rust-backed encrypted SQLite store
- keep a foreground realtime websocket active while the app is in the foreground, with `WorkManager` catch-up as a background fallback
- project decryptable transcripts through persistent `FfiMlsFacade` state when this device has the group locally
- send text messages into chats backed by local MLS state, with local projection applied immediately after server accept
- render trusted-device link intents as QR codes and share/copy them from Android
- list linked devices, create link intents, and approve/revoke devices when this Android client has local account-root material

## FFI Build Requirements

- Android SDK with:
  - `platform-tools`
  - `platforms;android-36`
  - `build-tools;36.0.0`
  - `ndk;29.0.14206865`
- Rust targets:
  - `aarch64-linux-android`
  - `x86_64-linux-android`
- `cargo-ndk`

## Local Backend Wiring

- default Android `debug` base URL is `http://10.0.2.2:8080`
- override it when needed with:
  - `./gradlew installDebug -PtrixBaseUrl=http://10.0.2.2:8080`
  - or `TRIX_BASE_URL=http://10.0.2.2:8080 ./gradlew installDebug`
- Android also keeps a runtime server switcher on the bootstrap screen; this remains enabled in release beta builds for tester flexibility
- cleartext HTTP is enabled in the manifest for beta/dev builds because `trixd` still commonly runs over plain HTTP in local and staging setups
