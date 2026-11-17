#!/usr/bin/env bash
# Local end-to-end test of the bundle on 127.0.0.1 high ports (nothing public).
# Runs in a throwaway copy of the bundle so runtime/ and secrets/ never mix with
# a real deployment. Usage: test/local-test.sh [--keep]   (needs prebuilt images
# hagency-pubtest/{server,concierge}:local, or set IMAGE_MODE=build in .env.test)
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PUBTEST_DIR:-$(mktemp -d)}"
cp -R "$SRC/." "$WORK/"; rm -rf "$WORK/runtime" "$WORK/secrets" "$WORK/backups"
ENV="$WORK/test/.env.test"
umask 077
sed -e 's/^DOMAIN=.*/DOMAIN=matrix.hagency.localhost/' -e 's/^ELEMENT_DOMAIN=.*/ELEMENT_DOMAIN=app.hagency.localhost/' \
    -e 's/^SERVER_NAME=.*/SERVER_NAME=hagency.localhost/' -e 's/^TLS_MODE=.*/TLS_MODE=internal/' \
    -e 's/^BIND_ADDR=.*/BIND_ADDR=127.0.0.1/' -e 's/^HTTP_PORT=.*/HTTP_PORT=18080/' -e 's/^HTTPS_PORT=.*/HTTPS_PORT=18443/' \
    -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=hagency-pubtest/' -e "s/^IMAGE_MODE=.*/IMAGE_MODE=${IMAGE_MODE:-local}/" \
    -e 's#^SERVER_IMAGE=.*#SERVER_IMAGE=hagency-pubtest/server:local#' -e 's#^CONCIERGE_IMAGE=.*#CONCIERGE_IMAGE=hagency-pubtest/concierge:local#' \
    -e 's#^CADDY_IMAGE=.*#CADDY_IMAGE=hagency-pubtest/caddy:local#' \
    "$SRC/.env.example" > "$ENV"
TEST_PASSWORD="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
echo "TEST_USER_PASSWORD=$TEST_PASSWORD" >> "$ENV"   # test-only, stays in the throwaway copy
export ENV_FILE="$ENV"
# shellcheck disable=SC1091
source "$WORK/lib.sh"
fail=0
check() { local name="$1"; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi; }
R=(--resolve hagency.localhost:18443:127.0.0.1 --resolve matrix.hagency.localhost:18443:127.0.0.1 --resolve app.hagency.localhost:18443:127.0.0.1)
c() { curl -sk --max-time 15 "${R[@]}" "$@"; }

# pull mode with local images: skip pulling the local-only tags
docker image inspect hagency-pubtest/server:local >/dev/null
"$WORK/deploy.sh" 2>&1 | sed 's/^/  deploy| /' || { echo "FAIL deploy"; exit 1; }
check "idempotent re-run" bash -c "'$WORK/deploy.sh' >/dev/null 2>&1"
check "readyz (in container)" bash -c "cd '$WORK' && ENV_FILE='$ENV' docker compose --env-file '$ENV' exec -T server curl -fsS http://127.0.0.1:8088/readyz >/dev/null"
check "matrix versions via caddy" bash -c "$(declare -p R); $(declare -f c); c https://matrix.hagency.localhost:18443/_matrix/client/versions | grep -q '\"versions\"'"
check "well-known server" bash -c "$(declare -p R); $(declare -f c); c https://matrix.hagency.localhost:18443/.well-known/matrix/server | grep -q 'matrix.hagency.localhost:443'"
check "root well-known server delegation" bash -c "$(declare -p R); $(declare -f c); c https://hagency.localhost:18443/.well-known/matrix/server | grep -q '\"m.server\":\"matrix.hagency.localhost:443\"'"
check "root well-known client" bash -c "$(declare -p R); $(declare -f c); c https://hagency.localhost:18443/.well-known/matrix/client | grep -q 'https://matrix.hagency.localhost:18443'"
check "well-known client" bash -c "$(declare -p R); $(declare -f c); c https://matrix.hagency.localhost:18443/.well-known/matrix/client | grep -q 'base_url'"
check "element web loads" bash -c "$(declare -p R); $(declare -f c); c https://app.hagency.localhost:18443/ | grep -qi '<title>'"
check "element config templated" bash -c "$(declare -p R); $(declare -f c); c https://app.hagency.localhost:18443/config.json | grep -q 'https://matrix.hagency.localhost:18443'"
check "_synapse blocked" bash -c "$(declare -p R); $(declare -f c); [ \"\$(c -o /dev/null -w '%{http_code}' https://matrix.hagency.localhost:18443/_synapse/admin/v1/server_version)\" = 404 ]"
check "postgres not published" bash -c "! docker port hagency-pubtest-postgres-1 2>/dev/null | grep -q ."
check "only 127.0.0.1 bound" bash -c "docker port hagency-pubtest-caddy-1 | grep -v '^.*127.0.0.1:' | grep -q . && exit 1 || exit 0"

reg() { # $1 user -> prints final status json (register + finish), password from .env.test
  local out id
  out="$(printf '{"username":"%s","password":"%s","password_confirm":"%s"}' "$1" "$TEST_PASSWORD" "$TEST_PASSWORD" \
    | c -H 'Content-Type: application/json' -H 'Origin: https://matrix.hagency.localhost:18443' --data-binary @- https://matrix.hagency.localhost:18443/auth/api/v1/auth/register)"
  id="$(printf '%s' "$out" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  [ -n "$id" ] || { printf '%s' "$out"; return; }
  [[ "$out" == *display_name* ]] && printf '{"display_name":"t"}' | c -H 'Content-Type: application/json' -H 'Origin: https://matrix.hagency.localhost:18443' --data-binary @- "https://matrix.hagency.localhost:18443/auth/api/v1/auth/register/$id/display-name" >/dev/null
  printf '{}' | c -H 'Content-Type: application/json' -H 'Origin: https://matrix.hagency.localhost:18443' --data-binary @- "https://matrix.hagency.localhost:18443/auth/api/v1/auth/register/$id/finish"
}
check "invite mode refuses sign-up without token" bash -c "$(declare -p R TEST_PASSWORD); $(declare -f c reg); ! reg pubtest_noinvite | grep -q '\"status\":\"success\"'"
check "invite token created" bash -c "'$WORK/deploy.sh' invite 1 2>/dev/null | grep -Eq '^[A-Za-z0-9]{24}$'"
sed -i.bak 's/^REGISTRATION_MODE=.*/REGISTRATION_MODE=open/' "$ENV" && rm -f "$ENV.bak"
"$WORK/deploy.sh" >/dev/null 2>&1 || echo "FAIL redeploy open"
check "open mode sign-up via API" bash -c "$(declare -p R TEST_PASSWORD); $(declare -f c reg); reg pubtest_user | grep -q '\"status\":\"success\"'"
check "test user password login" bash -c "$(declare -p R); $(declare -f c); printf '{\"username\":\"pubtest_user\",\"password\":\"%s\"}' '$TEST_PASSWORD' | c -H 'Content-Type: application/json' -H 'Origin: https://matrix.hagency.localhost:18443' --data-binary @- https://matrix.hagency.localhost:18443/auth/api/v1/auth/login | grep -q success"
check "concierge running" bash -c "[ \"\$(docker inspect -f '{{.State.Status}}' hagency-pubtest-concierge-1)\" = running ]"
sleep 20
docker logs hagency-pubtest-concierge-1 2>&1 | tail -5 | sed 's/^/  concierge| /'
check "concierge signed in" bash -c "docker logs hagency-pubtest-concierge-1 2>&1 | grep -qiE 'concierge @|enrolled|listening'"
check "kill switch stops concierge" bash -c "'$WORK/deploy.sh' kill-agents >/dev/null 2>&1 && [ \"\$(docker inspect -f '{{.State.Status}}' hagency-pubtest-concierge-1)\" != running ]"
check "upload size cap (413)" bash -c "$(declare -p R); $(declare -f c); for i in 1 2 3; do head -c 22000000 /dev/zero | c -o /dev/null -w '%{http_code}' -X POST --data-binary @- https://matrix.hagency.localhost:18443/_matrix/media/v3/upload | grep -q 413 && exit 0; sleep 3; done; exit 1"
check "postgres max_connections cap" bash -c "cd '$WORK' && docker compose --env-file '$ENV' exec -T postgres psql -U hagency -tAc 'show max_connections' | grep -q '^60$'"
check "server memory cap set" bash -c "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' hagency-pubtest-server-1)\" -gt 0 ]"
check "alerts hook runs" bash -c "'$WORK/alerts.sh' >/dev/null 2>&1; [ \$? -le 1 ]"
check "backup" bash -c "'$WORK/backup.sh' >/dev/null 2>&1 && ls '$WORK'/backups/2*Z/palpo.dump >/dev/null"
check "auth rate limit returns 429" bash -c "$(declare -p R); $(declare -f c); for i in \$(seq 1 14); do c -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' --data '{}' https://matrix.hagency.localhost:18443/auth/api/v1/auth/login; done | grep -q 429"
if [ "${1:-}" != --keep ]; then
  (cd "$WORK" && docker compose --env-file "$ENV" --profile concierge --profile calls down -v --remove-orphans >/dev/null 2>&1)
  rm -rf "$WORK"
fi
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED (work dir $WORK)"; exit 1; }
