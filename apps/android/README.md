# Android Client

This directory contains the current Android client slice for `Trix`.

## Direction

- Kotlin + Jetpack Compose first, not KMP or Flutter
- native adaptive layouts for phone, tablet, foldable, and resizable windows
- native Android shell first, with Rust FFI used wherever the messaging/storage boundary has stabilized
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
- safe messenger conversation snapshots, unread counts, message history, attachment send/download, receipts, typing, and member/device mutations through `FfiMessengerClient`

The Android project now generates Kotlin bindings from UniFFI during the Gradle build, regenerates shared `strings.xml` resources from the repo-level catalog, and cross-compiles `libtrix_core.so` for `arm64-v8a` and `x86_64` via `cargo ndk`.

## Why Kotlin-First Around It

The better tradeoff for this PoC is still:

1. ship a real Android-native shell with adaptive UX
2. move the narrow, already-stable crypto/transport surfaces behind Rust FFI
3. keep windowing, session orchestration, and device-local UX native on Android

## Next Android Tasks

- expand Compose and instrumented coverage around attachment failure/retry, inline preview/open flows, lifecycle resume, and stored-device recovery states
- surface richer messenger-core recovery events more explicitly in the UI instead of collapsing some states into generic labels
- keep converging remaining debug-only or legacy repository paths on the shared messenger-core runtime

## Current Live Flow

- use the shared task-first onboarding flow:
  - set or override the server URL
  - run an explicit server availability check
  - create an account with `profile name`, public optional `handle`, and `device name`
  - or link a device with `link payload/code` plus `device name`
- keep pending approval separate from the main form, so an already-linked device can return and use `Check Approval` instead of re-entering bootstrap data
- surface stored local device state explicitly on launch:
  - active / unknown sessions offer `Reconnect`
  - pending sessions offer `Check Approval`
  - revoked sessions require forgetting local state before relinking
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
- open `FfiMessengerClient` against the same account/device root so projected timelines, unread counts, and preview ordering stay in one shared state layer
- keep a foreground realtime websocket active while the app is in the foreground, with `WorkManager` catch-up as a background fallback
- list conversations, participant labels, unread counts, and previews from the shared messenger core
- send text and attachment messages through the shared messenger core, with local projection applied immediately after server accept
- mark conversations read, queue best-effort read receipts, and render outgoing delivered/read ticks from shared messenger receipt decorations
- render inline previews for common image attachment types (`jpeg`, `png`, `gif`, `webp`, `heif`, `heic`) and tap through to the normal open/share attachment flow
- manage group members and device membership through the shared messenger-core mutation APIs
- render trusted-device link intents as QR codes and share/copy them from Android
- list linked devices, create link intents, and approve/revoke devices when this Android client has local account-root material

## Shared Strings

- shared user-facing chat copy lives in the root [`strings.yaml`](../../strings.yaml) catalog
- refresh generated outputs manually with `make strings-generate`
- the Android build also regenerates [`app/src/main/res/values/strings.xml`](./app/src/main/res/values/strings.xml) and [`app/src/main/res/values-ru/strings.xml`](./app/src/main/res/values-ru/strings.xml) automatically from that catalog
- do not hand-edit the generated XML resources; edit `strings.yaml` instead

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

- default Android `debug` base URL is `https://trix.artelproject.tech`
- override it when needed with:
  - `./gradlew installDebug -PtrixBaseUrl=http://10.0.2.2:8080`
  - or `TRIX_BASE_URL=http://10.0.2.2:8080 ./gradlew installDebug`
- Android also keeps a runtime server switcher on the bootstrap screen; this remains enabled in release beta builds for tester flexibility
- cleartext HTTP is enabled in the manifest for beta/dev builds because `trixd` still commonly runs over plain HTTP in local and staging setups

## Android Interop Smoke

- the debug build now exposes a debug-only Android interop bridge for local harness work
- Genymotion remains the only supported Android runtime for the first interop wave
- normal app defaults now point at `https://trix.artelproject.tech`; interop still uses the explicit debug-only `TRIX_INTEROP_BASE_URL` path when you need a local backend
- if the host backend is described with host loopback such as `http://127.0.0.1:8080`, the interop config remaps that to the Genymotion-reachable `http://10.0.3.2:8080`
- run the Android smoke driver with:
  - `./gradlew connectedDebugAndroidTest -PtrixBaseUrl=http://10.0.3.2:8080 -Pandroid.testInstrumentationRunnerArguments.class=chat.trix.android.interop.AndroidInteropDriverInstrumentedTest`
- the instrumented driver writes:
  - a per-action transcript path
  - PNG screenshot artifact paths when a UI-backed interop step fails
