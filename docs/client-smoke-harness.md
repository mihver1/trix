# Client Smoke Harness

`Trix` already had several point-to-point test assets, but they were scattered across Rust, bot, macOS, and Android targets. This harness gives the repo one repeatable laptop-friendly entrypoint for the basic client scenarios that were previously being re-checked by hand.

## Main Command

Run the default smoke pack:

```bash
./scripts/client-smoke-harness.sh
```

The default pack runs:

- `client-scenarios`
- `safe-ffi`
- `bot-runtime`
- `macos`
- `android-unit`

That default pack is the current best "local client baseline" because it combines the Rust control plane and bot flows with native macOS and Android client-local assertions. In practice it catches regressions in persistent stores, MLS flows, message projection, attachments, device linking, and the basic native presentation/state layer without requiring a simulator or emulator.

## Compose Runtime

When `podman compose` is available, the harness uses it to start local services from [`docker-compose.yml`](/Users/mihver/Projects/trix/docker-compose.yml). It now checks both `podman` from `PATH` and the Podman Desktop install at `/opt/podman/bin/podman`. If Podman is not available, it falls back to `docker compose`.

If you already have Postgres running locally, skip compose startup:

```bash
./scripts/client-smoke-harness.sh --no-postgres
```

By default the harness leaves started services running after the test pass so repeated runs stay fast. To stop them automatically after the run:

```bash
./scripts/client-smoke-harness.sh --stop-postgres
```

## Available Suites

List everything the harness knows about:

```bash
./scripts/client-smoke-harness.sh --list-suites
```

Current suites:

- `client-scenarios`: `trix-core` FFI client lifecycle, chat creation, text delivery, read state, realtime, and Android-style outbox flow.
- `safe-ffi`: high-level messenger client flows, paging, attachments, device linking, member and device removal, restart/reopen persistence.
- `bot-runtime`: headless bot runtime smoke coverage, websocket to polling fallback, text reply loop, and attachment download.
- `ios-unit`: native iOS unit tests through `xcodebuild test` on an available iPhone simulator.
- `ios-server`: native iOS server-backed smoke through `xcodebuild test` against a live backend on `TRIX_IOS_SERVER_SMOKE_BASE_URL` (defaults to `http://localhost:8080`).
- `macos`: `swift test` for the macOS client package.
- `android-unit`: local Android JVM unit tests. The harness runs these with `-PtrixSkipAndroidNdkBuild=true`, so they do not require cross-compiling JNI libs through the Android NDK.
- `android-ui`: Android instrumented UI tests for emulator/device runs.

Examples:

```bash
./scripts/client-smoke-harness.sh --suite client-scenarios --suite safe-ffi
./scripts/client-smoke-harness.sh --suite ios-unit --no-postgres
./scripts/client-smoke-harness.sh --suite ios-server --stop-postgres
./scripts/client-smoke-harness.sh --suite macos --no-postgres
./scripts/client-smoke-harness.sh --suite android-unit --suite android-ui
```

## Coverage Map

The harness intentionally aligns with the manual checklist in [`docs/client-test-checklist.md`](/Users/mihver/Projects/trix/docs/client-test-checklist.md).

Practical mapping today:

- `client-scenarios` covers the basic account bootstrap, profile update, device-link smoke, DM creation, message send/receive, read-state, realtime inbox, and Android outbox scenarios.
- `safe-ffi` covers the richer safe-messenger flows that native clients are converging on: snapshots, pagination, attachments, chat scoping, device approval/revoke, member removal, device removal, and reopen persistence.
- `bot-runtime` covers the lowest-friction end-to-end external client path and is useful as a regression canary for inbox delivery, eventing, and attachment round-trips.
- `ios-unit` covers the iOS-native bridge and model layer without requiring a live backend: onboarding/edit forms, link payload parsing, message-body serialization, attachment filename normalization, and safe diagnostic log redaction/rotation.
- `ios-server` covers live iOS user scenarios against the local server: bootstrap/auth, link intent, DM delivery, cross-device DM delivery, and group chat delivery.
- `macos` covers host-level macOS model and presentation logic, including group-chat naming/subtitle behavior and device/workspace stabilization helpers.
- `android-unit` covers Android local state reducers and repository-adjacent logic on the JVM; `android-ui` adds Compose coverage for DM/group chat surfaces, group actions, and chat list/detail presentation.

## Known Gaps

- iOS now has both native unit tests and server-backed user-scenario smoke, but there is still no iOS UI test suite for end-to-end screen flows.
- The harness does not boot a simulator or emulator for you. `android-ui` still expects an attached device or running emulator.
- `android-unit` still expects the normal Android/Gradle toolchain plus the Rust host toolchain used for checked-in UniFFI regeneration, but it no longer needs the Android NDK.
- The Rust e2e suites still require a reachable Postgres instance via `TRIX_TEST_DATABASE_URL`.

## Good Next Step

Once this becomes part of the daily loop, the next high-value increment is an iOS UI suite that drives the actual onboarding and chat screens against the same local server, so the native shell gets real screen-level regression coverage instead of only bridge and transport smoke.
