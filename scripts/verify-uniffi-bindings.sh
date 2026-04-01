#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-uniffi-verify.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

host_rust_library_name() {
  local os_name
  os_name="$(uname -s)"
  case "$os_name" in
    Darwin) printf '%s' "libtrix_core.dylib" ;;
    Linux) printf '%s' "libtrix_core.so" ;;
    *)
      printf 'unsupported host OS for UniFFI verification: %s\n' "$os_name" >&2
      return 1
      ;;
  esac
}

compare_file() {
  local generated="$1"
  local checked_in="$2"
  local label="$3"
  local fix_hint="$4"

  if ! diff -u "$checked_in" "$generated"; then
    printf '\nerror: %s is out of date.\n' "$label" >&2
    printf 'regenerate with: %s\n' "$fix_hint" >&2
    return 1
  fi
}

HOST_LIBRARY_PATH="$ROOT_DIR/target/debug/$(host_rust_library_name)"
SWIFT_OUT="$TMP_DIR/swift"
KOTLIN_OUT="$TMP_DIR/kotlin"
ANDROID_UNIFFI_CONFIG="$ROOT_DIR/crates/trix-core/uniffi.toml"
ANDROID_GENERATED_FILE="$KOTLIN_OUT/chat/trix/android/core/ffi/trix_core.kt"
STATUS=0

mkdir -p "$SWIFT_OUT" "$KOTLIN_OUT"

(
  cd "$ROOT_DIR"
  cargo build -p trix-core --lib
  cargo run -p trix-core --bin uniffi-bindgen -- generate \
    --library "$HOST_LIBRARY_PATH" \
    --language swift \
    --out-dir "$SWIFT_OUT"
  cargo run -p trix-core --bin uniffi-bindgen -- generate \
    --library "$HOST_LIBRARY_PATH" \
    --language kotlin \
    --no-format \
    --out-dir "$KOTLIN_OUT" \
    --config "$ANDROID_UNIFFI_CONFIG"
)

compare_file \
  "$SWIFT_OUT/trix_core.swift" \
  "$ROOT_DIR/apps/ios/TrixiOS/Bridge/Generated/trix_core.swift" \
  "iOS Swift UniFFI bridge" \
  "bash apps/ios/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_coreFFI.h" \
  "$ROOT_DIR/apps/ios/TrixiOS/Bridge/Generated/trix_coreFFI.h" \
  "iOS UniFFI header" \
  "bash apps/ios/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_coreFFI.modulemap" \
  "$ROOT_DIR/apps/ios/TrixiOS/Bridge/Generated/trix_coreFFI.modulemap" \
  "iOS UniFFI modulemap" \
  "bash apps/ios/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_coreFFI.modulemap" \
  "$ROOT_DIR/apps/ios/TrixiOS/Bridge/Generated/module.modulemap" \
  "iOS copied module.modulemap" \
  "bash apps/ios/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_core.swift" \
  "$ROOT_DIR/apps/macos/Sources/TrixMac/Generated/trix_core.swift" \
  "macOS Swift UniFFI bridge" \
  "bash apps/macos/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_coreFFI.h" \
  "$ROOT_DIR/apps/macos/Sources/trix_coreFFI/trix_coreFFI.h" \
  "macOS UniFFI header" \
  "bash apps/macos/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$SWIFT_OUT/trix_coreFFI.modulemap" \
  "$ROOT_DIR/apps/macos/Sources/trix_coreFFI/module.modulemap" \
  "macOS UniFFI modulemap" \
  "bash apps/macos/scripts/generate-trix-core-bridge.sh" || STATUS=1

compare_file \
  "$ANDROID_GENERATED_FILE" \
  "$ROOT_DIR/apps/android/app/src/main/java/chat/trix/android/core/ffi/trix_core.kt" \
  "Android Kotlin UniFFI bridge" \
  "(cd apps/android && ./gradlew :app:syncCheckedInTrixCoreKotlinBindings)" || STATUS=1

exit "$STATUS"
