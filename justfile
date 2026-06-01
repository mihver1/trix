# Trix project task runner
# Usage: just <recipe>

set dotenv-load := true
set positional-arguments := true

repo_root := justfile_directory()
version_file := repo_root / "version.conf"
version := `awk -F= '/^[[:space:]]*VERSION[[:space:]]*=/{gsub(/[[:space:]"]/, "", $2); print $2; found=1; exit} END{if(!found) exit 1}' version.conf`
trix_apple_dir := repo_root / "apple"
trix_ios_derived_data := "/tmp/trix-ios-dd"
trix_macos_derived_data := "/tmp/trix-macos-dd"
trix_admin_macos_derived_data := "/tmp/trix-admin-macos-dd"
trix_app_bundle_id := "com.softgrid.trixapp"

# Show current version.
version:
    @echo "{{ version }}"

# Bump version: just bump major|minor|patch.
bump level:
    #!/usr/bin/env bash
    set -euo pipefail
    current="{{ version }}"
    version_file="{{ version_file }}"

    IFS='.' read -r major minor patch <<< "$current"
    if [[ -z "${major:-}" || -z "${minor:-}" || -z "${patch:-}" ]] ||
       [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
      echo "error: VERSION in $version_file must be semver-like MAJOR.MINOR.PATCH, got '$current'" >&2
      exit 1
    fi

    case "{{ level }}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "error: expected major, minor, or patch" >&2; exit 1 ;;
    esac
    next="${major}.${minor}.${patch}"
    if grep -qE '^[[:space:]]*VERSION[[:space:]]*=' "$version_file"; then
      sed -i '' -E "s/^[[:space:]]*VERSION[[:space:]]*=.*/VERSION=$next/" "$version_file"
    else
      printf '\nVERSION=%s\n' "$next" >> "$version_file"
    fi
    echo "==> $current -> $next"
    just sync-version

# Sync version.conf into active project configs.
sync-version:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{ version }}"
    echo "==> syncing version $v"
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: $v/" "{{ trix_apple_dir }}/project.yml"
    sed -i '' '/\[workspace\.package\]/,/^\[/ s/^version = ".*"/version = "'"$v"'"/' "{{ repo_root }}/Cargo.toml"
    echo "    apple/project.yml"
    echo "    Cargo.toml"

# Build iOS app and upload to TestFlight.
ios-testflight build_number="": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    export TRIX_ASC_DESTINATION="upload"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform ios

# Build macOS app and upload to TestFlight.
macos-testflight build_number="" destination="upload": (_testflight-preflight) sync-version
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    export TRIX_ASC_DESTINATION="{{ destination }}"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform macos

# Build iOS archive only.
ios-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform ios --unsigned-archive

# Build macOS archive only.
macos-archive build_number="":
    #!/usr/bin/env bash
    set -euo pipefail
    export TRIX_APPLE_BUILD_NUMBER="{{ if build_number == "" { "$(date '+%Y%m%d%H%M')" } else { build_number } }}"
    export TRIX_APPLE_MARKETING_VERSION="{{ version }}"
    bash "{{ trix_apple_dir }}/scripts/archive-testflight.sh" --platform macos --unsigned-archive

_testflight-preflight:
    @command -v xcodebuild >/dev/null || (echo "error: xcodebuild not found" >&2 && exit 1)
    @command -v xcodegen >/dev/null || (echo "error: xcodegen not found" >&2 && exit 1)

# Run cargo check for the remaining Rust workspace.
check:
    make -C "{{ repo_root }}" check

# Run Rust tests.
test:
    cargo test --workspace

# Run shell syntax checks for current scripts.
bash-check:
    bash -n "{{ trix_apple_dir }}/scripts/archive-testflight.sh" "{{ repo_root }}"/server/xmpp/scripts/*.sh

# Run the XMPP push gateway.
run-push-gateway:
    cargo run -p trix-push-gateway

# Build the XMPP Trix iOS app for a simulator; signing: automatic|unsigned.
trix-ios-build signing="automatic" simulator="iPhone 17": xcodegen-trix-apple
    #!/usr/bin/env bash
    set -euo pipefail
    signing="{{ signing }}"
    simulator="{{ simulator }}"
    build_args=(
      -project "{{ trix_apple_dir }}/TrixMatrix.xcodeproj"
      -scheme TrixMatrixiOS
      -destination "platform=iOS Simulator,name=$simulator"
      -derivedDataPath "{{ trix_ios_derived_data }}"
      build
    )
    case "$signing" in
      automatic) ;;
      unsigned) build_args+=(CODE_SIGNING_ALLOWED=NO) ;;
      *) echo "error: signing must be automatic or unsigned" >&2; exit 1 ;;
    esac
    xcodebuild "${build_args[@]}"

# Build, install, and launch the XMPP Trix iOS app in a simulator.
trix-ios-run signing="automatic" simulator="iPhone 17":
    #!/usr/bin/env bash
    set -euo pipefail
    simulator="{{ simulator }}"
    just --justfile "{{ repo_root }}/justfile" trix-ios-build "{{ signing }}" "$simulator"
    app="{{ trix_ios_derived_data }}/Build/Products/Debug-iphonesimulator/Trix.app"
    [[ -d "$app" ]] || { echo "error: built app not found at $app" >&2; exit 1; }
    xcrun simctl boot "$simulator" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator" -b
    xcrun simctl install "$simulator" "$app"
    xcrun simctl launch --terminate-running-process "$simulator" "{{ trix_app_bundle_id }}"

# Build the XMPP Trix macOS app; signing: automatic|unsigned.
trix-macos-build signing="automatic": xcodegen-trix-apple
    #!/usr/bin/env bash
    set -euo pipefail
    signing="{{ signing }}"
    build_args=(
      -project "{{ trix_apple_dir }}/TrixMatrix.xcodeproj"
      -scheme TrixMatrixMac
      -destination 'platform=macOS'
      -derivedDataPath "{{ trix_macos_derived_data }}"
      build
    )
    case "$signing" in
      automatic) ;;
      unsigned) build_args+=(CODE_SIGNING_ALLOWED=NO) ;;
      *) echo "error: signing must be automatic or unsigned" >&2; exit 1 ;;
    esac
    xcodebuild "${build_args[@]}"

# Build the Trix macOS admin app; signing: automatic|unsigned.
trix-admin-macos-build signing="automatic": xcodegen-trix-apple
    #!/usr/bin/env bash
    set -euo pipefail
    signing="{{ signing }}"
    build_args=(
      -project "{{ trix_apple_dir }}/TrixMatrix.xcodeproj"
      -scheme TrixAdminMac
      -destination 'platform=macOS'
      -derivedDataPath "{{ trix_admin_macos_derived_data }}"
      build
    )
    case "$signing" in
      automatic) ;;
      unsigned) build_args+=(CODE_SIGNING_ALLOWED=NO) ;;
      *) echo "error: signing must be automatic or unsigned" >&2; exit 1 ;;
    esac
    xcodebuild "${build_args[@]}"

# Build and launch the XMPP Trix macOS app.
trix-macos-run signing="automatic":
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{ repo_root }}/justfile" trix-macos-build "{{ signing }}"
    app="{{ trix_macos_derived_data }}/Build/Products/Debug/Trix.app"
    [[ -d "$app" ]] || { echo "error: built app not found at $app" >&2; exit 1; }
    open "$app"

# Build and launch the Trix macOS admin app.
trix-admin-macos-run signing="automatic":
    #!/usr/bin/env bash
    set -euo pipefail
    just --justfile "{{ repo_root }}/justfile" trix-admin-macos-build "{{ signing }}"
    app="{{ trix_admin_macos_derived_data }}/Build/Products/Debug/Trix Admin.app"
    [[ -d "$app" ]] || { echo "error: built app not found at $app" >&2; exit 1; }
    open "$app"

# Regenerate XMPP Trix Apple Xcode project.
xcodegen-trix-apple:
    cd "{{ trix_apple_dir }}" && xcodegen generate

# Format Rust code.
fmt:
    cargo fmt --all

# Check Rust formatting without modifying.
fmt-check:
    cargo fmt --all -- --check

[private]
default:
    @just --list
