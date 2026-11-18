# shellcheck shell=bash
# Health checks used by deploy.sh (gate for automatic rollback) and check.sh
# (cron monitoring). Sourced after lib.sh/ops.sh. Hard failures count; DNS and
# peer federation results are reported but never trigger a rollback, because a
# peer being down is not this release's fault.

CHECK_FAILS=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; CHECK_FAILS=$((CHECK_FAILS + 1)); }
warn() { printf '  WARN %s\n' "$1"; }

# curl through THIS host's Caddy, with real certificate validation, regardless
# of where public DNS points (first deploy, or DNS not switched yet).
# CHECK_INSECURE=1 (only for ACME_CA = Let's Encrypt staging) skips verification.
local_curl() {
  local k=(); [ "${CHECK_INSECURE:-0}" = 1 ] && k=(-k)
  curl -fsS --max-time 15 --resolve "$SERVER_NAME:443:127.0.0.1" --resolve "$DOMAIN:443:127.0.0.1" \
    --resolve "$ELEMENT_DOMAIN:443:127.0.0.1" ${k[@]+"${k[@]}"} "$@"
}

# expect <name> <url> <fixed string the body must contain>; retries while
# Caddy obtains certificates on a first start.
expect() {
  local name="$1" url="$2" want="$3" body="" i; shift 3
  for i in 1 2 3 4 5 6 7 8 9 10; do
    body="$(local_curl "$@" "$url" 2>/dev/null || true)"
    case "$body" in *"$want"*) pass "$name"; return 0;; esac
    [ "$i" = 10 ] || sleep 6
  done
  fail "$name ($url did not contain $want)"
}

check_endpoints() {
  expect "client API versions" "$PUBLIC_URL/_matrix/client/versions" '"versions"'
  expect "server name delegation" "https://$SERVER_NAME/.well-known/matrix/server" "\"m.server\":\"$DOMAIN:443\""
  expect "client discovery" "https://$SERVER_NAME/.well-known/matrix/client" "\"base_url\":\"$PUBLIC_URL\""
  expect "federation API version" "$PUBLIC_URL/_matrix/federation/v1/version" '"server"'
  # Peers following the delegation send Host: <DOMAIN>:443 (spec, server discovery).
  expect "federation via delegated Host:port" "$PUBLIC_URL/_matrix/federation/v1/version" '"server"' -H "Host: $DOMAIN:443"
  expect "server signing key" "$PUBLIC_URL/_matrix/key/v2/server" "\"server_name\":\"$SERVER_NAME\""
  expect "accounts (Pasion) issuer" "$PUBLIC_URL/auth/.well-known/openid-configuration" '"issuer"'
  expect "Element Web config" "$ELEMENT_URL/config.json" "$PUBLIC_URL"
  expect "Hagency desktop native config" "$PUBLIC_URL/auth/api/v1/native/config" "$NATIVE_DESKTOP_CLIENT_ID"
}

check_dns() {
  local name got
  for name in "$SERVER_NAME" "$DOMAIN" "$ELEMENT_DOMAIN"; do
    got="$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [ "$got" = "${HOST_PUBLIC_IP:-}" ]; then pass "DNS $name -> $got"; else warn "DNS $name -> ${got:-nothing}, expected ${HOST_PUBLIC_IP:-unset}"; fi
    # An AAAA record pointing elsewhere sends IPv6 peers and browsers to another host.
    got="$(getent ahostsv6 "$name" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    case "$got" in ""|::ffff:*) ;; *) warn "DNS $name has AAAA $got: make sure it is this host";; esac
  done
  # Same request over real DNS (not forced to loopback): what the world sees.
  if curl -fsS --max-time 15 "$PUBLIC_URL/_matrix/client/versions" 2>/dev/null | grep -q '"versions"'; then
    pass "public path $PUBLIC_URL"; else warn "public path $PUBLIC_URL not answering via DNS"; fi
}

# Outbound federation: ask our own server (as notary) for each allowlisted
# peer's keys, which makes Palpo contact the peer over federation.
check_peers() {
  local peer
  IFS=',' read -ra peers <<< "${FEDERATION_ALLOWLIST:-}"
  for peer in ${peers[@]+"${peers[@]}"}; do
    peer="${peer// /}"
    if [ -z "$peer" ] || [[ "$peer" == \** ]]; then continue; fi
    if local_curl "$PUBLIC_URL/_matrix/key/v2/query/$peer" 2>/dev/null | grep -q "\"server_name\":\"$peer\""; then
      pass "federation reaches $peer"
    else warn "federation to $peer not confirmed (peer down or not deployed yet?)"; fi
  done
  # External view, opt-in (sends the public server name to matrix.org's tester).
  if [ "${FEDERATION_TESTER:-0}" = 1 ]; then
    if curl -fsS --max-time 30 "https://federationtester.matrix.org/api/report?server_name=$SERVER_NAME" | grep -q '"FederationOK":true'; then
      pass "federationtester.matrix.org reports FederationOK"
    else fail "federationtester.matrix.org does not report FederationOK"; fi
  fi
}

check_host() {
  local pct
  pct="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}' || true)"
  if [ "${pct:-0}" -ge "${ALERT_DISK_PCT:-85}" ]; then fail "disk ${pct}% used"; else pass "disk ${pct:-?}% used"; fi
  local bad
  bad="$(docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" --format '{{.Names}} {{.Status}}' \
    | grep -E 'unhealthy|Restarting|Exited' || true)"
  if [ -z "$bad" ]; then pass "containers healthy"; else fail "containers: $bad"; fi
}

# run_checks [--with-host]: returns non-zero when any hard check failed.
run_checks() {
  CHECK_FAILS=0
  log "health checks ($ENV_NAME)"
  if wait_healthy server 900 >/dev/null 2>&1; then pass "server container healthy (readyz)"; else fail "server container not healthy"; fi
  check_endpoints; check_dns; check_peers
  [ "${1:-}" != --with-host ] || check_host
  [ "$CHECK_FAILS" = 0 ]
}
