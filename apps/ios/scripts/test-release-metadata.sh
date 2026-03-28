#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$IOS_DIR/TrixiOS/Resources/Info.plist"
APP_ICON_CONTENTS="$IOS_DIR/TrixiOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
LAUNCH_SCREEN_STORYBOARD="$IOS_DIR/TrixiOS/Resources/LaunchScreen.storyboard"
PROJECT_YML="$IOS_DIR/project.yml"
PROJECT_PBXPROJ="$IOS_DIR/TrixiOS.xcodeproj/project.pbxproj"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

declare -a FAILURES=()

record_failure() {
  FAILURES+=("$1")
}

finish() {
  local failure

  if ((${#FAILURES[@]} > 0)); then
    for failure in "${FAILURES[@]}"; do
      printf 'not ok - %s\n' "$failure" >&2
    done
    exit 1
  fi
}

assert_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || record_failure "$plist_path missing $key_path=$expected"
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || record_failure "missing file $path"
}

assert_app_icon_asset_is_complete() {
  python3 - "$APP_ICON_CONTENTS" <<'PY' || record_failure "app icon asset catalog is incomplete"
import json
import pathlib
import sys

contents_path = pathlib.Path(sys.argv[1])
data = json.loads(contents_path.read_text())
base_dir = contents_path.parent

required_slots = {
    ("iphone", "60x60", "2x"),
    ("ipad", "76x76", "2x"),
    ("ios-marketing", "1024x1024", "1x"),
}
present_slots = set()

for image in data["images"]:
    filename = image.get("filename")
    idiom = image.get("idiom")
    size = image.get("size")
    scale = image.get("scale")
    if filename:
        file_path = base_dir / filename
        if not file_path.is_file():
            print(f"missing referenced icon file: {file_path}", file=sys.stderr)
            sys.exit(1)
    present_slots.add((idiom, size, scale))

missing = required_slots - present_slots
if missing:
    print(f"missing required app icon slots: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_release_project_has_no_development_asset_paths() {
  local file_path
  local project_text

  for file_path in "$PROJECT_YML" "$PROJECT_PBXPROJ"; do
    project_text="$(<"$file_path")"
    if [[ "$project_text" == *'DEVELOPMENT_ASSET_PATHS'* ]]; then
      record_failure "$file_path still defines DEVELOPMENT_ASSET_PATHS, which can omit release resources from archives"
    fi
  done
}

main() {
  assert_plist_value "$INFO_PLIST" "CFBundleIconName" "AppIcon"
  assert_plist_value "$INFO_PLIST" "UILaunchStoryboardName" "LaunchScreen"
  assert_file_exists "$LAUNCH_SCREEN_STORYBOARD"
  assert_app_icon_asset_is_complete
  assert_release_project_has_no_development_asset_paths
  finish
  printf 'ok - ios release metadata is configured for App Store validation\n'
}

main "$@"
