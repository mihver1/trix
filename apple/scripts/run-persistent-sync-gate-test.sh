#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'run-persistent-sync-gate-test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$output"; then
    fail "missing expected output: $needle"
  fi
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/trix-persistent-gate-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

fake_app="$tmpdir/fake-trix"
cat >"$fake_app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE_TRIX mode=%s allow_send=%s allow_trust=%s keychain=%s\n' \
  "${TRIX_XMPP_LIVE_SMOKE_MODE:-}" \
  "${TRIX_XMPP_LIVE_SMOKE_ALLOW_SEND:-}" \
  "${TRIX_XMPP_LIVE_SMOKE_ALLOW_TRUST:-}" \
  "${TRIX_XMPP_LIVE_SMOKE_USE_KEYCHAIN:-}"
EOF
chmod +x "$fake_app"

output="$(
  TRIX_XMPP_LIVE_SMOKE_USER_ID="owner@trix.selfhost.ru" \
  TRIX_XMPP_LIVE_SMOKE_PASSWORD="redacted-owner-password" \
  TRIX_XMPP_LIVE_SMOKE_PEER_ID="peer@trix.selfhost.ru" \
  TRIX_XMPP_LIVE_SMOKE_PEER_PASSWORD="redacted-peer-password" \
  TRIX_XMPP_LIVE_SMOKE_THIRD_ID="third@trix.selfhost.ru" \
  TRIX_XMPP_LIVE_SMOKE_THIRD_PASSWORD="redacted-third-password" \
  "$SCRIPT_DIR/run-persistent-sync-gate.sh" \
    --skip-build \
    --app-executable "$fake_app"
)"

assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_start mode=timeline-restart"
assert_contains "$output" "FAKE_TRIX mode=timeline-restart allow_send=1 allow_trust=1 keychain=0"
assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_done mode=timeline-restart"

assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_start mode=group-timeline-restart"
assert_contains "$output" "FAKE_TRIX mode=group-timeline-restart allow_send=1 allow_trust=1 keychain=0"
assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_done mode=group-timeline-restart"

assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_start mode=dm-backfill-repair"
assert_contains "$output" "FAKE_TRIX mode=dm-backfill-repair allow_send=1 allow_trust=1 keychain=0"
assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE mode_done mode=dm-backfill-repair"

assert_contains "$output" "TRIX_XMPP_PERSISTENT_GATE skip keychain_relaunch=default_disabled"

printf 'run-persistent-sync-gate-test ok\n'
