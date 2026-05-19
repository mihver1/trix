#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  call-log-audit.sh LOG_FILE_OR_DIR [...]

Scans a captured encrypted-call smoke log bundle for forbidden sensitive value
classes. The report prints only class names, file paths, and line counts; it
never prints the matching log line or secret value.
USAGE
}

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required for call log audit" >&2
  exit 2
}

python3 - "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

VALUE = r"['\"]?(?!\[?redacted\]?|<redacted>|redacted|absent|null|nil|none)([A-Za-z0-9._~+/\-=:]{10,})"

PATTERNS = [
    (
        "authorization_basic",
        re.compile(r"\bAuthorization\s*:\s*Basic\s+[A-Za-z0-9+/=]{16,}|\bBasic\s+[A-Za-z0-9+/=]{24,}", re.IGNORECASE),
    ),
    (
        "bearer_or_auth_token",
        re.compile(r"\b(Bearer\s+[A-Za-z0-9._~+/\-=]{20,}|(auth|access|refresh|bearer|gateway|file)[_-]?token\b\s*[:=]\s*" + VALUE + r")", re.IGNORECASE),
    ),
    (
        "livekit_jwt",
        re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    ),
    (
        "livekit_token_field",
        re.compile(r"\blive[_-]?kit[_-]?(token|jwt)\b\s*[:=]\s*" + VALUE, re.IGNORECASE),
    ),
    (
        "turn_credential_field",
        re.compile(r"\b(turn[_-]?(credential|credentials|password|secret|username)|turnCredential|turnCredentials|turnUsername)\b\s*[:=]\s*" + VALUE, re.IGNORECASE),
    ),
    (
        "turn_rest_username",
        re.compile(r"\b[0-9]{10,}:[A-Za-z0-9._%+\-]+@trix\.selfhost\.ru\b", re.IGNORECASE),
    ),
    (
        "media_key_field",
        re.compile(r"\b(media[_-]?key|mediaKey|call[_-]?key|callKey|e2ee[_-]?key|e2eeKey|shared[_-]?key)\b\s*[:=]\s*" + VALUE, re.IGNORECASE),
    ),
    (
        "xmpp_password_field",
        re.compile(r"\b(xmpp[_-]?)?password\b\s*[:=]\s*" + VALUE + r"|\"password\"\s*:\s*\"" + VALUE, re.IGNORECASE),
    ),
    (
        "apns_token_field",
        re.compile(r"\b(apns|voip|device)[_-]?(token|token_hex)\b\s*[:=]\s*['\"]?(?!\[?redacted\]?|<redacted>|redacted|absent|null|nil|none)[A-Fa-f0-9]{32,}", re.IGNORECASE),
    ),
    (
        "omemo_secret_field",
        re.compile(r"\b(omemo[_-]?(secret|key|session)|identity[_-]?key|identityKey|pre[_-]?key|preKey|signed[_-]?pre[_-]?key|signedPreKey|sender[_-]?key|senderKey|private[_-]?key|trust[_-]?secret)\b\s*[:=]\s*" + VALUE, re.IGNORECASE),
    ),
    (
        "decrypted_content_field",
        re.compile(r"\b(decrypted[_-]?(body|content|message|text)|plaintext|message[_-]?body|body_plaintext)\b\s*[:=]\s*" + VALUE, re.IGNORECASE),
    ),
]

def usage_error(message: str) -> int:
    print(f"call-log-audit error: {message}", file=sys.stderr)
    return 2


def iter_files(args):
    seen = set()
    missing = []
    for raw in args:
        path = Path(raw)
        if not path.exists():
            missing.append(raw)
            continue
        if path.is_dir():
            candidates = (candidate for candidate in path.rglob("*") if candidate.is_file())
        elif path.is_file():
            candidates = (path,)
        else:
            continue
        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if resolved in seen:
                continue
            seen.add(resolved)
            yield candidate
    if missing:
        raise FileNotFoundError(", ".join(missing))


def is_probably_text(data: bytes) -> bool:
    return b"\0" not in data


def display_path(path: Path) -> str:
    try:
        resolved = path.resolve()
        cwd = Path.cwd().resolve()
        return str(resolved.relative_to(cwd))
    except (OSError, ValueError):
        return str(path)


def main(argv: list[str]) -> int:
    try:
        files = list(iter_files(argv))
    except FileNotFoundError as exc:
        return usage_error(f"missing path: {exc}")

    if not files:
        return usage_error("no regular files found")

    scanned = 0
    findings = {}
    for path in files:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if not is_probably_text(data):
            continue
        scanned += 1
        text = data.decode("utf-8", errors="replace")
        per_file = {}
        for line in text.splitlines():
            for name, pattern in PATTERNS:
                if pattern.search(line):
                    per_file[name] = per_file.get(name, 0) + 1
        if per_file:
            findings[display_path(path)] = per_file

    if findings:
        print(f"call-log-audit failed files_scanned={scanned}")
        for path in sorted(findings):
            for name in sorted(findings[path]):
                print(
                    f"call-log-audit finding class={name} file={path} lines={findings[path][name]}"
                )
        return 1

    classes = ",".join(name for name, _ in PATTERNS)
    print(f"call-log-audit ok files_scanned={scanned} forbidden_classes_absent={classes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
PY
