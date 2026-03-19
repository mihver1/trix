# Android Client Scaffold

This directory now contains a standalone Android project for the future Trix client.

## Direction

- Kotlin + Jetpack Compose first, not KMP or Flutter
- native adaptive layouts for phone, tablet, foldable, and resizable windows
- no Rust FFI on Android yet because `trix-core` is still a stub and would add coupling without product value
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

## Why Kotlin-First For Now

The repository has a `trix-core` crate, but it does not yet provide real sync, storage, or crypto behavior. Building Android around JNI/UniFFI right now would mostly freeze an interface over placeholders. The better tradeoff for the PoC is:

1. ship a real Android-native shell with adaptive UX
2. wire the backend vertical slices that already exist
3. move stable crypto/sync surfaces into shared Rust only when they stop changing every few days

## Next Android Tasks

- add a thin API layer for `system/health` and `system/version`
- implement account bootstrap and device session flows
- add secure local persistence for session state
- introduce thread caching and message timeline syncing
- decide where Android-specific storage ends and shared Rust begins
