#!/bin/sh
set -eu

if [ "$#" -gt 0 ]; then
    exec certbot "$@"
fi

: "${TRIX_PUBLIC_DOMAIN:=trix.artelproject.tech}"
: "${CERTBOT_EMAIL:=}"
: "${CERTBOT_STAGING:=0}"

set -- certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    --preferred-challenges http \
    -d "${TRIX_PUBLIC_DOMAIN}"

if [ -n "${CERTBOT_EMAIL}" ]; then
    set -- "$@" --email "${CERTBOT_EMAIL}"
else
    set -- "$@" --register-unsafely-without-email
fi

if [ "${CERTBOT_STAGING}" = "1" ]; then
    set -- "$@" --staging
fi

exec certbot "$@"
