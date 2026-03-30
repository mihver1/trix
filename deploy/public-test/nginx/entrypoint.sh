#!/bin/sh
set -eu

: "${TRIX_PUBLIC_DOMAIN:=trix.artelproject.tech}"
: "${TRIX_UPSTREAM_HOST:=app}"
: "${TRIX_UPSTREAM_PORT:=8080}"
: "${TRIX_TLS_READY:=0}"
: "${TRIX_CLIENT_MAX_BODY_SIZE:=50m}"

template_root="/opt/trix/nginx"
output_path="/etc/nginx/conf.d/default.conf"
cert_root="/etc/letsencrypt/live/${TRIX_PUBLIC_DOMAIN}"

export TRIX_PUBLIC_DOMAIN
export TRIX_UPSTREAM_HOST
export TRIX_UPSTREAM_PORT
export TRIX_CLIENT_MAX_BODY_SIZE

if [ "${TRIX_TLS_READY}" = "1" ] \
    && [ -f "${cert_root}/fullchain.pem" ] \
    && [ -f "${cert_root}/privkey.pem" ]; then
    envsubst '${TRIX_PUBLIC_DOMAIN} ${TRIX_UPSTREAM_HOST} ${TRIX_UPSTREAM_PORT} ${TRIX_CLIENT_MAX_BODY_SIZE}' \
        < "${template_root}/https.conf.template" \
        > "${output_path}"
else
    envsubst '${TRIX_PUBLIC_DOMAIN} ${TRIX_UPSTREAM_HOST} ${TRIX_UPSTREAM_PORT} ${TRIX_CLIENT_MAX_BODY_SIZE}' \
        < "${template_root}/http.conf.template" \
        > "${output_path}"
fi

exec nginx -g 'daemon off;'
