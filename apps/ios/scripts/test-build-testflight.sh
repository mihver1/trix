#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/build-testflight.sh"

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

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local description="$3"
  local content=""

  if [[ -f "$haystack" ]]; then
    content="$(<"$haystack")"
  fi

  if [[ "$content" == *"$needle"* ]]; then
    fail "$description"
  fi
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
printf "%s\n" "$*" >> "$log_dir/xcodebuild.log"

export_path=""
export_options=""
result_bundle=""

while (($# > 0)); do
  case "$1" in
    -exportPath)
      shift
      export_path="$1"
      ;;
    -exportOptionsPlist)
      shift
      export_options="$1"
      ;;
    -resultBundlePath)
      shift
      result_bundle="$1"
      ;;
  esac
  shift || break
done

if [[ -n "$result_bundle" ]]; then
  mkdir -p "$result_bundle"
  : > "$result_bundle/Info.plist"
fi

if [[ -n "$export_options" ]]; then
  cp "$export_options" "$log_dir/export-options.plist"
fi

if [[ -n "$export_path" ]]; then
  mkdir -p "$export_path"
  if [[ -n "$export_options" ]]; then
    destination="$(/usr/libexec/PlistBuddy -c "Print :destination" "$export_options")"
    if [[ "$destination" == "export" ]]; then
      : > "$export_path/Trix.ipa"
    fi
  fi
fi
'

  write_fake_tool "$bin_dir/xcrun" '
log_dir="${TEST_LOG_DIR:?}"
printf "%s\n" "$*" >> "$log_dir/xcrun.log"
'

  write_fake_tool "$bin_dir/cargo" ':'
  write_fake_tool "$bin_dir/rustup" ':'
  write_fake_tool "$bin_dir/xcodegen" ':'
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

write_fake_bridge_script() {
  local path="$1"

  write_fake_tool "$path" '
log_dir="${TEST_LOG_DIR:?}"
printf "bridge\n" >> "$log_dir/bridge.log"
'
}

test_upload_with_asc_auth_uses_xcodebuild() {
  local temp_root
  temp_root="$(mktemp -d)"

  setup_fake_toolchain "$temp_root"
  write_fake_bridge_script "$temp_root/fake-generate-bridge.sh"
  mkdir -p "$temp_root/logs"
  : > "$temp_root/AuthKey_TESTKEY.p8"

  PATH="$temp_root/bin:$PATH" \
    TEST_LOG_DIR="$temp_root/logs" \
    TRIX_IOS_BRIDGE_SCRIPT="$temp_root/fake-generate-bridge.sh" \
    TRIX_IOS_BUILD_ROOT="$temp_root/build" \
    TRIX_IOS_ALLOW_PROVISIONING_UPDATES=0 \
    TRIX_ASC_AUTH_KEY_PATH="$temp_root/AuthKey_TESTKEY.p8" \
    TRIX_ASC_AUTH_KEY_ID="TESTKEY" \
    TRIX_ASC_AUTH_ISSUER_ID="TESTISSUER" \
    TRIX_TESTFLIGHT_INTERNAL_ONLY=1 \
    "$TARGET_SCRIPT" --upload --skip-prechecks --skip-xcodegen >/dev/null

  assert_contains "bridge" "$temp_root/logs/bridge.log" "bridge refresh not invoked"
  assert_contains "-authenticationKeyPath $temp_root/AuthKey_TESTKEY.p8" "$temp_root/logs/xcodebuild.log" "xcodebuild upload auth path missing"
  assert_contains "-authenticationKeyID TESTKEY" "$temp_root/logs/xcodebuild.log" "xcodebuild upload auth key id missing"
  assert_contains "-authenticationKeyIssuerID TESTISSUER" "$temp_root/logs/xcodebuild.log" "xcodebuild upload auth issuer missing"
  assert_contains "-exportArchive" "$temp_root/logs/xcodebuild.log" "xcodebuild exportArchive not invoked"
  assert_contains "<string>upload</string>" "$temp_root/logs/export-options.plist" "upload destination not written to export options"
  assert_contains "<true/>" "$temp_root/logs/export-options.plist" "internal-only plist flag missing"
  assert_not_contains "altool" "$temp_root/logs/xcrun.log" "xcrun altool should not be used for xcodebuild upload path"
  rm -rf "$temp_root"
}

test_upload_with_xcode_account_uses_xcodebuild() {
  local temp_root
  temp_root="$(mktemp -d)"

  setup_fake_toolchain "$temp_root"
  write_fake_bridge_script "$temp_root/fake-generate-bridge.sh"
  mkdir -p "$temp_root/logs"

  PATH="$temp_root/bin:$PATH" \
    TEST_LOG_DIR="$temp_root/logs" \
    TRIX_IOS_BRIDGE_SCRIPT="$temp_root/fake-generate-bridge.sh" \
    TRIX_IOS_BUILD_ROOT="$temp_root/build" \
    TRIX_IOS_ALLOW_PROVISIONING_UPDATES=0 \
    "$TARGET_SCRIPT" --upload --skip-prechecks --skip-xcodegen >/dev/null

  assert_contains "bridge" "$temp_root/logs/bridge.log" "bridge refresh not invoked"
  assert_contains "-exportArchive" "$temp_root/logs/xcodebuild.log" "xcodebuild exportArchive not invoked for Xcode-account upload"
  assert_contains "<string>upload</string>" "$temp_root/logs/export-options.plist" "upload destination not written for Xcode-account upload"
  assert_not_contains "altool" "$temp_root/logs/xcrun.log" "xcrun altool should not be used for Xcode-account upload path"
  rm -rf "$temp_root"
}

test_archive_upload_with_apple_id_uses_altool() {
  local temp_root
  temp_root="$(mktemp -d)"

  setup_fake_toolchain "$temp_root"
  write_fake_bridge_script "$temp_root/fake-generate-bridge.sh"
  mkdir -p "$temp_root/logs"

  PATH="$temp_root/bin:$PATH" \
    TEST_LOG_DIR="$temp_root/logs" \
    TRIX_IOS_BRIDGE_SCRIPT="$temp_root/fake-generate-bridge.sh" \
    TRIX_IOS_BUILD_ROOT="$temp_root/build" \
    TRIX_IOS_ALLOW_PROVISIONING_UPDATES=0 \
    TRIX_APPLE_ID="user@example.com" \
    TRIX_APP_SPECIFIC_PASSWORD="secret" \
    "$TARGET_SCRIPT" --upload --skip-prechecks --skip-xcodegen >/dev/null

  assert_contains "bridge" "$temp_root/logs/bridge.log" "bridge refresh not invoked"
  assert_contains "<string>export</string>" "$temp_root/logs/export-options.plist" "archive upload with Apple ID should export an IPA"
  assert_contains "altool" "$temp_root/logs/xcrun.log" "archive upload with Apple ID should use altool"
  assert_contains "--upload-app" "$temp_root/logs/xcrun.log" "archive upload with Apple ID should call altool upload"
  rm -rf "$temp_root"
}

test_ipa_upload_falls_back_to_altool() {
  local temp_root
  temp_root="$(mktemp -d)"

  setup_fake_toolchain "$temp_root"
  mkdir -p "$temp_root/logs"
  : > "$temp_root/Trix.ipa"

  PATH="$temp_root/bin:$PATH" \
    TEST_LOG_DIR="$temp_root/logs" \
    TRIX_IOS_BUILD_ROOT="$temp_root/build" \
    TRIX_APPLE_ID="user@example.com" \
    TRIX_APP_SPECIFIC_PASSWORD="secret" \
    "$TARGET_SCRIPT" --upload --ipa "$temp_root/Trix.ipa" >/dev/null

  assert_contains "altool" "$temp_root/logs/xcrun.log" "altool upload fallback not used for IPA upload"
  assert_contains "--upload-app" "$temp_root/logs/xcrun.log" "altool upload command missing"
  [[ -f "$temp_root/build/upload.log" ]] || fail "upload log missing for IPA upload fallback"
  rm -rf "$temp_root"
}

main() {
  run_test "upload with ASC auth uses xcodebuild" test_upload_with_asc_auth_uses_xcodebuild
  run_test "upload with Xcode account uses xcodebuild" test_upload_with_xcode_account_uses_xcodebuild
  run_test "archive upload with Apple ID uses altool" test_archive_upload_with_apple_id_uses_altool
  run_test "ipa upload falls back to altool" test_ipa_upload_falls_back_to_altool
}

main "$@"
