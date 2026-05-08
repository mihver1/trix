#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="${TRIX_XMPP_COMPOSE_DIR:-/opt/trix-xmpp}"
BACKUP_DIR="${TRIX_XMPP_BACKUP_DIR:-/var/backups/trix-xmpp}"
RETAIN="${TRIX_XMPP_BACKUP_RETAIN:-14}"
PROJECT_NAME="${TRIX_XMPP_COMPOSE_PROJECT_NAME:-trix-xmpp}"
DATABASE_VOLUME="${PROJECT_NAME}_ejabberd-database"
UPLOAD_VOLUME="${PROJECT_NAME}_ejabberd-upload"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="trix-xmpp-${timestamp}"
tmp_dir="${BACKUP_DIR}/.${backup_name}.tmp"
archive_path="${BACKUP_DIR}/${backup_name}.tgz"
stopped=0

finish() {
  status=$?
  if [ "$stopped" -eq 1 ]; then
    cd "$COMPOSE_DIR"
    docker-compose start ejabberd >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
  exit "$status"
}

trap finish EXIT

if ! [[ "$RETAIN" =~ ^[0-9]+$ ]] || [ "$RETAIN" -lt 1 ]; then
  echo "TRIX_XMPP_BACKUP_RETAIN must be a positive integer" >&2
  exit 2
fi

mkdir -p "$BACKUP_DIR" "$tmp_dir"
chmod 700 "$BACKUP_DIR" "$tmp_dir"

cd "$COMPOSE_DIR"
docker-compose stop ejabberd
stopped=1

mkdir -p "$tmp_dir/config/certs"
for file in docker-compose.yml ejabberd.yml .env.example README.md prosody.cfg.lua; do
  if [ -f "$file" ]; then
    cp "$file" "$tmp_dir/config/$file"
  fi
done
if [ -f certs/README.md ]; then
  cp certs/README.md "$tmp_dir/config/certs/README.md"
fi

docker run --rm \
  -v "${DATABASE_VOLUME}:/volumes/ejabberd-database:ro" \
  -v "${UPLOAD_VOLUME}:/volumes/ejabberd-upload:ro" \
  -v "${tmp_dir}:/backup" \
  alpine \
  sh -c 'tar --exclude="./ejabberd-database/certs" --exclude="./ejabberd-database/certs/*" -czf /backup/volumes.tgz -C /volumes .'

{
  echo "name=${backup_name}"
  echo "created_utc=${timestamp}"
  echo "host=$(hostname)"
  echo "compose_dir=${COMPOSE_DIR}"
  echo "database_volume=${DATABASE_VOLUME}"
  echo "upload_volume=${UPLOAD_VOLUME}"
  echo "includes=config without private TLS material; database and upload volumes"
  echo "excludes=cert private keys; ejabberd database cert cache; .env; bootstrap credentials; shell history"
} > "$tmp_dir/MANIFEST.txt"

tar czf "$archive_path" -C "$tmp_dir" .
chmod 600 "$archive_path"

docker-compose start ejabberd
stopped=0

find "$BACKUP_DIR" -maxdepth 1 -type f -name 'trix-xmpp-*.tgz' \
  | sort -r \
  | tail -n +"$((RETAIN + 1))" \
  | xargs -r rm -f

echo "$archive_path"
