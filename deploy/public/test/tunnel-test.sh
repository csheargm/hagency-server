#!/usr/bin/env bash
# Local test of TLS_MODE=tunnel (nothing public): requests are sent the way cloudflared
# sends them (plain HTTP to 127.0.0.1:HTTP_PORT, public Host, CF-Connecting-IP).
# Runs in a throwaway copy as project hagency-tunneltest. Usage: test/tunnel-test.sh [--keep]
# Images: TEST_SERVER_IMAGE / TEST_CADDY_IMAGE (default hagency-pubtest/{server,caddy}:local).
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PUBTEST_DIR:-$(mktemp -d)}"
cp -R "$SRC/." "$WORK/"; rm -rf "$WORK/runtime" "$WORK/secrets" "$WORK/backups"
ENV="$WORK/test/.env.tunnel"; PORT="${TEST_PORT:-18180}"; NET=172.30.19
umask 077
sed -e 's/^DOMAIN=.*/DOMAIN=matrix.tunnel.localhost/' -e 's/^ELEMENT_DOMAIN=.*/ELEMENT_DOMAIN=app.tunnel.localhost/' \
    -e 's/^SERVER_NAME=.*/SERVER_NAME=tunnel.localhost/' -e 's/^TLS_MODE=.*/TLS_MODE=tunnel/' \
    -e "s#^EDGE_SUBNET=.*#EDGE_SUBNET=$NET.0/24#" -e 's/^BIND_ADDR=.*/BIND_ADDR=127.0.0.1/' \
    -e "s/^HTTP_PORT=.*/HTTP_PORT=$PORT/" -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=hagency-tunneltest/' \
    -e 's/^IMAGE_MODE=.*/IMAGE_MODE=local/' -e 's/^CONCIERGE_ENABLED=.*/CONCIERGE_ENABLED=false/' \
    -e "s#^SERVER_IMAGE=.*#SERVER_IMAGE=${TEST_SERVER_IMAGE:-hagency-pubtest/server:local}#" \
    -e "s#^CADDY_IMAGE=.*#CADDY_IMAGE=${TEST_CADDY_IMAGE:-hagency-pubtest/caddy:local}#" \
    "$SRC/.env.example" > "$ENV"
export ENV_FILE="$ENV"
fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi; }
# cloudflared-style request: plain HTTP to the local port, public Host header.
h() { local host="$1"; shift; curl -s --max-time 15 -H "Host: $host" "$@"; }
export -f h; export PORT

"$WORK/deploy.sh" 2>&1 | sed 's/^/  deploy| /'; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL deploy"; exit 1; }
check "idempotent re-run" bash -c "'$WORK/deploy.sh' >/dev/null 2>&1"
check "only 127.0.0.1:$PORT published" bash -c "[ \"\$(docker port hagency-tunneltest-caddy-1 | sort -u)\" = '$PORT/tcp -> 127.0.0.1:$PORT' ]"
check "postgres not published" bash -c "! docker port hagency-tunneltest-postgres-1 2>/dev/null | grep -q ."
check "matrix versions over plain HTTP" bash -c "h matrix.tunnel.localhost http://127.0.0.1:$PORT/_matrix/client/versions | grep -q '\"versions\"'"
check "no HTTPS redirect" bash -c "[ \"\$(h matrix.tunnel.localhost -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/_matrix/client/versions)\" = 200 ]"
check "root well-known server" bash -c "[ \"\$(h tunnel.localhost http://127.0.0.1:$PORT/.well-known/matrix/server)\" = '{\"m.server\":\"matrix.tunnel.localhost:443\"}' ]"
check "root well-known client: https, no port" bash -c "h tunnel.localhost http://127.0.0.1:$PORT/.well-known/matrix/client | grep -q '\"base_url\":\"https://matrix.tunnel.localhost\"}'"
check "root well-known client CORS" bash -c "h tunnel.localhost -D - -o /dev/null http://127.0.0.1:$PORT/.well-known/matrix/client | grep -qi '^access-control-allow-origin: \*'"
check "root redirects to https app" bash -c "h tunnel.localhost -D - -o /dev/null http://127.0.0.1:$PORT/ | grep -qi '^location: https://app.tunnel.localhost/'"
check "element web loads" bash -c "h app.tunnel.localhost http://127.0.0.1:$PORT/ | grep -qi '<title>'"
check "element config https base_url" bash -c "h app.tunnel.localhost http://127.0.0.1:$PORT/config.json | grep -q '\"base_url\": \"https://matrix.tunnel.localhost\"'"
check "_synapse blocked" bash -c "[ \"\$(h matrix.tunnel.localhost -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/_synapse/admin/v1/server_version)\" = 404 ]"
check "palpo trusts only the edge subnet" grep -qx "trusted_proxies = \[\"$NET.0/24\"\]" "$WORK/runtime/config/palpo.toml"
check "caddy trusts only the edge gateway" grep -q "trusted_proxies static $NET.1/32" "$WORK/runtime/Caddyfile"
check "pasion public base is https" bash -c "h matrix.tunnel.localhost http://127.0.0.1:$PORT/auth/.well-known/openid-configuration | grep -q '\"issuer\":\"https://matrix.tunnel.localhost/auth/'"
check "admin password file is 0600" bash -c "[ \"\$(stat -f %Lp '$WORK/secrets/admin_password' 2>/dev/null || stat -c %a '$WORK/secrets/admin_password')\" = 600 ]"
login() { h matrix.tunnel.localhost -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' --data '{}' "$@" "http://127.0.0.1:$PORT/auth/api/v1/auth/login"; }
export -f login
check "rate limit keyed on CF-Connecting-IP" bash -c "for i in \$(seq 1 14); do login -H 'CF-Connecting-IP: 203.0.113.7'; done | grep -q 429"
check "other CF-Connecting-IP not limited" bash -c "! login -H 'CF-Connecting-IP: 203.0.113.8' | grep -q 429"
# An untrusted peer (a container on the edge network) cannot pick its rate-limit key.
check "CF-Connecting-IP ignored from untrusted peer" bash -c "cd '$WORK' && for i in \$(seq 1 14); do docker compose -f docker-compose.yml -f docker-compose.tunnel.yml --env-file '$ENV' exec -T server curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: matrix.tunnel.localhost' -H 'CF-Connecting-IP: 203.0.113.9' -H 'Content-Type: application/json' --data '{}' http://caddy:$PORT/auth/api/v1/auth/login; done | grep -q 429 && ! login -H 'CF-Connecting-IP: 203.0.113.9' | grep -q 429"
check "backup" bash -c "'$WORK/backup.sh' >/dev/null 2>&1 && ls '$WORK'/backups/2*Z/palpo.dump >/dev/null"
if [ "${1:-}" != --keep ]; then
  (cd "$WORK" && docker compose -f docker-compose.yml -f docker-compose.tunnel.yml --env-file "$ENV" down -v --remove-orphans >/dev/null 2>&1)
  rm -rf "$WORK"
fi
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED (work dir $WORK)"; exit 1; }
