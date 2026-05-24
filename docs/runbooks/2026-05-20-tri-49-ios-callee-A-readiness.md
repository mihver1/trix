# TRI-49 ios-callee-A Signed iOS Readiness

Date: 2026-05-20

This runbook records the sanitized host-side checks for the physical iOS smoke
destination `ios-callee-A`. It deliberately avoids UDIDs, private device names,
APNs tokens, credentials, screenshots, and other host-local identifiers.

## Current Board Direction

The board direction on 2026-05-20 is to stop blocking on physical iOS hardware
for this lane because the physical devices are not available yet. Use
`ios-sim-A` as the development-ready iOS destination for current simulator
coverage, and defer physical-device-only proof until hardware exists.

The physical `ios-callee-A` evidence below is retained as historical context,
not as the active blocker for this issue.

## Current Result

`ios-callee-A` is visible to CoreDevice and paired, but it is not
development-ready because Developer Mode is disabled on the device.

Sanitized CoreDevice evidence:

```text
alias=ios-callee-A platform=iOS transport=localNetwork pairing=paired developer_mode=disabled visibility=default
```

Sanitized Xcode evidence:

```text
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -showdestinations
```

Result: Xcode lists a physical iOS destination for `ios-callee-A`.

```text
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'id=<device-id>' \
  -derivedDataPath /tmp/trix-tri49-ios-callee-A \
  build
```

Result: failed before a usable signed-device build.

```text
xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
Available destinations for the "TrixMatrixiOS" scheme:
  { platform:iOS, arch:arm64, id:<device-id>, name:ios-callee-A, error:Developer Mode disabled To use ios-callee-A for development, enable Developer Mode in Settings -> Privacy & Security. }
```

## Simulator Fallback Lane

The board asked to spawn simulators while the physical device remains blocked.
This is now the active lane for this issue. It covers compile, install, launch,
and simulator-only app smoke. It does not prove real-device APNs delivery,
physical-device CallKit behavior, or Developer Mode readiness; those are
deferred risks rather than blockers for this issue.

Sanitized simulator evidence:

```text
alias=ios-sim-A name=iPhone_17 state=Booted runtime=iOS_26.3
```

This host moved to Xcode 26.5 while only the iOS 26.3 simulator runtime was
installed. Xcode initially hid all simulator destinations because it preferred
runtime build `23F73`. The development-ready simulator lane uses a local
CoreSimulator runtime match override:

```bash
xcrun simctl runtime match set iphoneos26.5 23D8133
```

Rollback:

```bash
xcrun simctl runtime match set iphoneos26.5 --default
```

After the override, `xcodebuild -showdestinations` lists `iPhone 17` on
`OS:26.3.1`.

Simulator build command:

```bash
xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination 'platform=iOS Simulator,OS=26.3.1,name=iPhone 17' \
  -derivedDataPath /tmp/trix-tri49-ios-sim-A \
  build CODE_SIGNING_ALLOWED=NO
```

Result:

```text
ios_simulator_build_status=pass alias=ios-sim-A destination=iPhone_17 os=26.3.1 signing=disabled
** BUILD SUCCEEDED **
```

Simulator install/launch smoke:

```text
ios_simulator_launch_status=pass alias=ios-sim-A bundle=com.softgrid.trixapp
```

The simulator lane is development-ready for the current board scope.

## Recheck Commands

Run from the repository root. The command prints only sanitized alias-level
state.

```bash
json="$(mktemp)"
trap 'rm -f "$json"' EXIT

xcrun devicectl list devices --timeout 15 --json-output "$json" --quiet >/dev/null

jq -r '
  .result.devices
  | map(select(.hardwareProperties.platform == "iOS"
      or .deviceProperties.platform == "com.apple.platform.iphoneos"
      or .platform == "com.apple.platform.iphoneos"))
  | .[0]
  | "alias=ios-callee-A platform=\(.hardwareProperties.platform // .platform // "unknown") transport=\(.connectionProperties.transportType // "unknown") pairing=\(.connectionProperties.pairingState // "unknown") developer_mode=\(.deviceProperties.developerModeStatus // "unknown") visibility=\(.visibilityClass // "unknown")"
' "$json"
```

After Developer Mode is enabled, rerun the signed destination build with the
device identifier kept in a shell variable and filtered from output:

```bash
json="$(mktemp)"
log="$(mktemp)"
trap 'rm -f "$json" "$log"' EXIT

xcrun devicectl list devices --timeout 15 --json-output "$json" --quiet >/dev/null
UDID="$(
  jq -r '
    .result.devices
    | map(select(.hardwareProperties.platform == "iOS"
        or .deviceProperties.platform == "com.apple.platform.iphoneos"
        or .platform == "com.apple.platform.iphoneos"))
    | .[0].hardwareProperties.udid // .[0].identifier // empty
  ' "$json"
)"

xcodebuild \
  -project apple/TrixMatrix.xcodeproj \
  -scheme TrixMatrixiOS \
  -destination "id=$UDID" \
  -derivedDataPath /tmp/trix-tri49-ios-callee-A \
  build 2>&1 |
  perl -CS -pe 's/[0-9A-F]{8}-[0-9A-F]{16}/<device-id>/g; s/iPhone \([^)]*\)/ios-callee-A/g' |
  tee "$log"
```

Expected ready evidence:

- CoreDevice reports `pairing=paired` and `developer_mode=enabled` for
  `ios-callee-A`.
- The signed `TrixMatrixiOS` destination build exits successfully.
- The build log and issue comments contain only the sanitized alias and no
  device identifiers or private device names.

## Future Physical Device Action

When physical hardware becomes part of the smoke lane again, the device owner or
CTO should enable Developer Mode on `ios-callee-A` from the physical device UI:

1. Open Settings.
2. Go to Privacy & Security.
3. Enable Developer Mode.
4. Reboot if prompted and confirm Developer Mode after restart.
5. Keep the device connected or reachable on the same trusted local network.

If `ios-callee-A` cannot be changed, provide a replacement sanitized physical
iOS alias that is paired, reachable, and already has Developer Mode enabled.

## Operational Risk

Physical-device proof is deferred. Simulator coverage does not exercise
real-device APNs delivery, physical-device CallKit behavior, or Developer Mode
setup. Reopen or create a new physical-device smoke task when hardware is
available; until then, do not block current iOS development on `ios-callee-A`.
