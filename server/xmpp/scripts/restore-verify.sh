#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME="${TRIX_XMPP_CONTAINER_RUNTIME:-}"
PROJECT_NAME="${TRIX_XMPP_RESTORE_PROJECT:-trix-xmpp-restore-$$}"
HOST="${TRIX_XMPP_RESTORE_HOST:-trix.selfhost.ru}"
USER_NAME="${TRIX_XMPP_RESTORE_USER:-restore_$$_$(date +%s)}"
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trix-xmpp-restore.XXXXXX")"
C2S_PORT="${TRIX_XMPP_RESTORE_C2S_PORT:-}"
HTTP_PORT="${TRIX_XMPP_RESTORE_HTTP_PORT:-}"
MNESIA_BACKUP="trix-restore-mnesia.backup"
UPLOAD_ARCHIVE="trix-restore-upload.tgz"
UPLOAD_SENTINEL="restore-verify-sentinel.txt"

if [ -z "$PASSWORD" ]; then
  echo "failed to generate disposable restore password" >&2
  exit 2
fi

cleanup() {
  status=$?
  set +e
  if [ -f "$WORK_DIR/docker-compose.yml" ]; then
    (
      cd "$WORK_DIR" &&
        "$RUNTIME" compose -p "$PROJECT_NAME" down -v >/dev/null 2>&1
    )
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}

trap cleanup EXIT

run_with_secret_redaction() {
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" | sed "s/$PASSWORD/[redacted]/g" >&2
    return "$status"
  fi
  return 0
}

compose() {
  "$RUNTIME" compose -p "$PROJECT_NAME" "$@"
}

wait_for_ejabberd() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if compose exec -T ejabberd ejabberdctl status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "restore verification failed: ejabberd did not become ready" >&2
  return 1
}

if [ -z "$RUNTIME" ]; then
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
  else
    echo "podman or docker is required for restore verification" >&2
    exit 2
  fi
fi

command -v "$RUNTIME" >/dev/null 2>&1 || {
  echo "$RUNTIME is not available" >&2
  exit 2
}

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate disposable local TLS material" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to allocate temporary local ports" >&2
  exit 2
}

if [ -z "$C2S_PORT" ] || [ -z "$HTTP_PORT" ]; then
  ports="$(python3 - <<'PY'
import socket

ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    ports.append(str(sock.getsockname()[1]))
    sock.close()
print(" ".join(ports))
PY
)"
  C2S_PORT="${C2S_PORT:-${ports%% *}}"
  HTTP_PORT="${HTTP_PORT:-${ports##* }}"
fi

cp "$SOURCE_DIR/docker-compose.yml" "$WORK_DIR/docker-compose.yml"
cp "$SOURCE_DIR/ejabberd.yml" "$WORK_DIR/ejabberd.yml"
mkdir -p "$WORK_DIR/certs" "$WORK_DIR/backup"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=$HOST" \
  -keyout "$WORK_DIR/certs/local.key" \
  -out "$WORK_DIR/certs/local.crt" >/dev/null 2>&1
cat "$WORK_DIR/certs/local.key" "$WORK_DIR/certs/local.crt" > "$WORK_DIR/certs/local.pem"
cp "$WORK_DIR/certs/local.crt" "$WORK_DIR/cacert.pem"

(
  cd "$WORK_DIR"
  export TRIX_XMPP_C2S_PORT="$C2S_PORT"
  export TRIX_XMPP_HTTP_PORT="$HTTP_PORT"
  compose up -d ejabberd >/dev/null
  wait_for_ejabberd
  run_with_secret_redaction "$RUNTIME" compose -p "$PROJECT_NAME" exec -T ejabberd \
    ejabberdctl register "$USER_NAME" "$HOST" "$PASSWORD" >/dev/null

  compose exec -T ejabberd sh -lc \
    "printf '%s\n' restore-verify > /opt/ejabberd/upload/$UPLOAD_SENTINEL"
  compose exec -T ejabberd \
    ejabberdctl backup "/opt/ejabberd/database/$MNESIA_BACKUP" >/dev/null
  compose run --rm --no-deps \
    -v "$WORK_DIR/backup:/backup" \
    --entrypoint sh \
    ejabberd \
    -lc "set -e; cp /opt/ejabberd/database/$MNESIA_BACKUP /backup/$MNESIA_BACKUP; tar czf /backup/$UPLOAD_ARCHIVE -C /opt/ejabberd/upload ."
  compose exec -T ejabberd rm -f "/opt/ejabberd/database/$MNESIA_BACKUP" >/dev/null

  compose down -v >/dev/null
  compose run --rm --no-deps \
    -v "$WORK_DIR/backup:/backup:ro" \
    --entrypoint sh \
    ejabberd \
    -lc "set -e; tar xzf /backup/$UPLOAD_ARCHIVE -C /opt/ejabberd/upload"

  compose up -d ejabberd >/dev/null
  wait_for_ejabberd
  compose exec -T ejabberd sh -lc "cat > /tmp/$MNESIA_BACKUP" \
    < "$WORK_DIR/backup/$MNESIA_BACKUP"
  compose exec -T ejabberd \
    ejabberdctl restore "/tmp/$MNESIA_BACKUP" >/dev/null
  compose exec -T ejabberd rm -f "/tmp/$MNESIA_BACKUP" >/dev/null

  restored_users="$(compose exec -T ejabberd \
    ejabberdctl registered_users "$HOST")"
  if ! printf '%s\n' "$restored_users" | grep -Fx "$USER_NAME" >/dev/null; then
    echo "restore verification failed: disposable account was not present after native Mnesia restore" >&2
    exit 1
  fi
  if ! compose exec -T ejabberd test -f "/opt/ejabberd/upload/$UPLOAD_SENTINEL"; then
    echo "restore verification failed: upload archive sentinel was not present after restore" >&2
    exit 1
  fi
  python3 - "$HOST" "$USER_NAME" "$PASSWORD" "$C2S_PORT" <<'PY'
import base64
import socket
import ssl
import sys

host, user, password, port = sys.argv[1:5]
jid = f"{user}@{host}"

def recv_until(sock, needles):
    data = b""
    while not any(needle in data for needle in needles):
        chunk = sock.recv(8192)
        if not chunk:
            break
        data += chunk
        if len(data) > 262144:
            raise SystemExit("xmpp restore response exceeded expected size")
    return data

sock = socket.create_connection(("127.0.0.1", int(port)), timeout=10)
try:
    stream = (
        f"<stream:stream to='{host}' xmlns='jabber:client' "
        "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
    ).encode()
    sock.sendall(stream)
    features = recv_until(sock, [b"</stream:features>"])
    if b"urn:ietf:params:xml:ns:xmpp-tls" not in features:
        raise SystemExit("xmpp restore did not advertise STARTTLS")
    sock.sendall(b"<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    proceed = recv_until(sock, [b"<proceed", b"<failure"])
    if b"<proceed" not in proceed:
        raise SystemExit("xmpp restore STARTTLS was not accepted")

    context = ssl._create_unverified_context()
    sock = context.wrap_socket(sock, server_hostname=host)
    sock.sendall(stream)
    features = recv_until(sock, [b"</stream:features>"])
    if b"PLAIN" not in features:
        raise SystemExit("xmpp restore did not advertise SASL PLAIN after TLS")

    initial = base64.b64encode(("\0" + jid + "\0" + password).encode()).decode()
    auth = (
        "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' "
        f"mechanism='PLAIN'>{initial}</auth>"
    ).encode()
    sock.sendall(auth)
    result = recv_until(sock, [b"<success", b"<failure"])
    if b"<success" not in result:
        raise SystemExit("xmpp restore SASL login failed")
finally:
    try:
        sock.close()
    except Exception:
        pass
PY
)

echo "restore verification passed for disposable account ${USER_NAME}@${HOST}"
