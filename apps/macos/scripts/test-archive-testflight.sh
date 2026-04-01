#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/archive-testflight.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local description="$3"
  local content=""

  [[ -f "$haystack" ]] || fail "$description"
  content="$(<"$haystack")"
  [[ "$content" == *"$needle"* ]] || fail "$description"
}

assert_order() {
  local haystack="$1"
  shift

  local previous_line=0
  local needle
  local line_number

  [[ -f "$haystack" ]] || fail "order check file missing: $haystack"

  for needle in "$@"; do
    line_number="$(grep -nF "$needle" "$haystack" | head -n 1 | cut -d: -f1 || true)"
    [[ -n "$line_number" ]] || fail "missing timeline entry: $needle"
    (( line_number > previous_line )) || fail "timeline entry out of order: $needle"
    previous_line="$line_number"
  done
}

write_fake_tool() {
  local path="$1"
  local body="$2"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$path"
}

setup_fake_toolchain() {
  local root="$1"
  local bin_dir="$root/bin"

  mkdir -p "$bin_dir"

  write_fake_tool "$bin_dir/xcodebuild" '
log_dir="${TEST_LOG_DIR:?}"
printf "xcodebuild:%s\n" "$*" >> "$log_dir/timeline.log"
printf "%s\n" "$*" >> "$log_dir/xcodebuild.log"

archive_path=""
export_path=""
export_options=""

while (($# > 0)); do
  case "$1" in
    -archivePath)
      shift
      archive_path="$1"
      ;;
    -exportPath)
      shift
      export_path="$1"
      ;;
    -exportOptionsPlist)
      shift
      export_options="$1"
      ;;
  esac
  shift || break
done

if [[ -n "$archive_path" ]]; then
  mkdir -p "$archive_path"
fi

if [[ -n "$export_options" ]]; then
  cp "$export_options" "$log_dir/export-options.plist"
fi

if [[ -n "$export_path" ]]; then
  mkdir -p "$export_path"
fi
'
}

write_fake_bridge_script() {
  local path="$1"

  write_fake_tool "$path" '
log_dir="${TEST_LOG_DIR:?}"
printf "bridge\n" >> "$log_dir/timeline.log"
'
}

write_fake_core_build_script() {
  local path="$1"

  write_fake_tool "$path" '
log_dir="${TEST_LOG_DIR:?}"
printf "core:%s\n" "${CONFIGURATION:-}" >> "$log_dir/timeline.log"
'
}

run_test() {
  local name="$1"
  shift

  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    fail "$name"
  fi
}

test_archive_refreshes_bridge_and_core_before_xcodebuild() {
  local temp_root
  temp_root="$(mktemp -d)"

  setup_fake_toolchain "$temp_root"
  write_fake_bridge_script "$temp_root/fake-generate-bridge.sh"
  write_fake_core_build_script "$temp_root/fake-build-core.sh"
  mkdir -p "$temp_root/logs"

  PATH="$temp_root/bin:$PATH" \
    TEST_LOG_DIR="$temp_root/logs" \
    TRIX_MACOS_BRIDGE_SCRIPT="$temp_root/fake-generate-bridge.sh" \
    TRIX_MACOS_CORE_BUILD_SCRIPT="$temp_root/fake-build-core.sh" \
    TRIX_DIST_ROOT="$temp_root/dist" \
    TRIX_MACOS_BUILD_NUMBER=42 \
    TRIX_CONFIGURATION=Release \
    "$TARGET_SCRIPT" >/dev/null

  assert_contains "-archivePath $temp_root/dist/TrixMac.xcarchive" "$temp_root/logs/xcodebuild.log" "archive path missing from xcodebuild invocation"
  assert_contains "-exportArchive" "$temp_root/logs/xcodebuild.log" "exportArchive invocation missing"
  assert_contains "<string>export</string>" "$temp_root/logs/export-options.plist" "export destination missing from export options"
  assert_order "$temp_root/logs/timeline.log" "bridge" "core:Release" "xcodebuild:-project"
  rm -rf "$temp_root"
}

main() {
  run_test "archive refreshes bridge and core before xcodebuild" test_archive_refreshes_bridge_and_core_before_xcodebuild
}

main "$@"
