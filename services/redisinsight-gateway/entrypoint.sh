#!/bin/sh
# Hashes the basic-auth password at start-up (Caddy needs a bcrypt hash) and starts Caddy.
# The plain password only lives in the Railway variable.
set -eu

: "${BASIC_AUTH_USERNAME:?BASIC_AUTH_USERNAME must be set}"
: "${BASIC_AUTH_PASSWORD:?BASIC_AUTH_PASSWORD must be set}"
: "${REDISINSIGHT_UPSTREAM:?REDISINSIGHT_UPSTREAM must be set (e.g. redisinsight.railway.internal:5540)}"

if [ "${#BASIC_AUTH_PASSWORD}" -lt 16 ]; then
	echo "redisinsight-gateway: BASIC_AUTH_PASSWORD must be at least 16 characters" >&2
	exit 1
fi
case "${BASIC_AUTH_USERNAME}" in
	*[!A-Za-z0-9._-]*) echo "redisinsight-gateway: BASIC_AUTH_USERNAME may only contain A-Z a-z 0-9 . _ -" >&2; exit 1 ;;
esac

BASIC_AUTH_HASH="$(caddy hash-password --plaintext "${BASIC_AUTH_PASSWORD}")"
export BASIC_AUTH_HASH
unset BASIC_AUTH_PASSWORD

echo "redisinsight-gateway: basic auth for user ${BASIC_AUTH_USERNAME}, upstream ${REDISINSIGHT_UPSTREAM}, port ${PORT:-8080}"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
