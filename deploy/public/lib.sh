# Shared helpers for deploy.sh, backup.sh, restore.sh, upgrade.sh. Sourced, not run.
set -euo pipefail
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$BUNDLE/.env}"
SECRETS="$BUNDLE/secrets"
RUNTIME="$BUNDLE/runtime"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE missing: cp .env.example .env and edit it"
  if [ "$(uname)" = Linux ] && [ -n "$(find "$ENV_FILE" -perm /077 2>/dev/null)" ]; then
    die "$ENV_FILE is readable by others: chmod 600 $ENV_FILE"
  fi
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
  : "${COMPOSE_PROJECT_NAME:=hagency-public}" "${BIND_ADDR:=0.0.0.0}" "${HTTP_PORT:=80}" "${HTTPS_PORT:=443}"
  : "${SERVER_NAME:=$DOMAIN}" "${TLS_MODE:=acme}" "${IMAGE_MODE:=build}" "${REGISTRATION_MODE:=invite}"
  : "${CONCIERGE_ENABLED:=true}" "${CALLS_ENABLED:=false}" "${AGENTS_ENABLED:=true}"
  : "${PASION_LOGIN_BURST:=120}" "${PASION_LOGIN_PER_SECOND:=2}" "${PASION_REGISTRATION_BURST:=30}" "${PASION_REGISTRATION_PER_SECOND:=0.2}"
  export PASION_LOGIN_BURST PASION_LOGIN_PER_SECOND PASION_REGISTRATION_BURST PASION_REGISTRATION_PER_SECOND
  export COMPOSE_PROJECT_NAME BIND_ADDR HTTP_PORT HTTPS_PORT SERVER_NAME TLS_MODE IMAGE_MODE
  export REGISTRATION_MODE CONCIERGE_ENABLED CALLS_ENABLED AGENTS_ENABLED
  # tunnel: Cloudflare terminates HTTPS on 443, whatever local port Caddy uses.
  if [ "$HTTPS_PORT" = 443 ] || [ "$TLS_MODE" = tunnel ]; then PUBLIC_URL="https://$DOMAIN"; else PUBLIC_URL="https://$DOMAIN:$HTTPS_PORT"; fi
  if [ "$HTTPS_PORT" = 443 ] || [ "$TLS_MODE" = tunnel ]; then ELEMENT_URL="https://$ELEMENT_DOMAIN"; else ELEMENT_URL="https://$ELEMENT_DOMAIN:$HTTPS_PORT"; fi
  export PUBLIC_URL ELEMENT_URL
  if [ "$TLS_MODE" = internal ] && [ -s "$RUNTIME/ca/bundle.pem" ]; then export EXTRA_CA_BUNDLE=/run/extra-ca/bundle.pem; fi
}

compose() {
  local files=(-f "$BUNDLE/docker-compose.yml")
  [ "${TLS_MODE:-}" != tunnel ] || files+=(-f "$BUNDLE/docker-compose.tunnel.yml")
  docker compose --project-directory "$BUNDLE" "${files[@]}" --env-file "$ENV_FILE" "$@"
}

is_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; }

validate_env() {
  local v
  for v in DOMAIN ELEMENT_DOMAIN SERVER_NAME ADMIN_USER SERVER_IMAGE CONCIERGE_IMAGE CADDY_IMAGE CONCIERGE_USER; do
    [ -n "${!v:-}" ] || die "$v must be set in .env"
  done
  is_hostname "$DOMAIN" || die "DOMAIN '$DOMAIN' is not a lowercase host name"
  is_hostname "$ELEMENT_DOMAIN" || die "ELEMENT_DOMAIN '$ELEMENT_DOMAIN' is not a lowercase host name"
  is_hostname "$SERVER_NAME" || die "SERVER_NAME '$SERVER_NAME' is not a lowercase host name"
  [ "$DOMAIN" != "$ELEMENT_DOMAIN" ] || die "ELEMENT_DOMAIN must differ from DOMAIN (separate origin)"
  [[ "$ADMIN_USER" =~ ^[a-z0-9._=-]+$ ]] || die "ADMIN_USER must be a lowercase Matrix localpart"
  [[ "$CONCIERGE_USER" =~ ^[a-z0-9._=-]+$ ]] || die "CONCIERGE_USER must be a lowercase Matrix localpart"
  [[ -z "${ACME_EMAIL:-}" || "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "ACME_EMAIL is not an e-mail address"
  [[ "${ELEMENT_CALL_URL:-https://call.element.io}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || die "ELEMENT_CALL_URL must be a plain https URL"
  [[ "${CADDY_TRUSTED_PROXIES:-}" =~ ^[0-9a-fA-F.:/\ ]*$ ]] || die "CADDY_TRUSTED_PROXIES must be space-separated CIDRs"
  [[ "${LIVEKIT_URL:-}" =~ ^(wss://[A-Za-z0-9.-]+(:[0-9]+)?/?)?$ ]] || [[ "${LIVEKIT_URL:-}" == wss://your-project.livekit.cloud ]] || die "LIVEKIT_URL must be wss://host"
  case "${ROOT_MODE:-caddy}" in caddy|external) ;; *) die "ROOT_MODE must be caddy|external";; esac
  case "$TLS_MODE" in
    acme) [ -n "${ACME_EMAIL:-}" ] || die "TLS_MODE=acme needs ACME_EMAIL";;
    internal) ;;
    tunnel) validate_tunnel;;
    *) die "TLS_MODE must be acme|internal|tunnel";;
  esac
  case "$IMAGE_MODE" in build|pull|local) ;; *) die "IMAGE_MODE must be build|pull|local";; esac
  case "$REGISTRATION_MODE" in
    invite|open|closed) ;;
    approval) die "REGISTRATION_MODE=approval is not implemented in this server build; use invite";;
    *) die "REGISTRATION_MODE must be invite|approval|open|closed";;
  esac
  for v in CONCIERGE_ENABLED CALLS_ENABLED AGENTS_ENABLED; do
    case "${!v}" in true|false) ;; *) die "$v must be true|false";; esac
  done
  [[ "${CONCIERGE_DAILY_TOKENS:-0}" =~ ^[0-9]+$ ]] || die "CONCIERGE_DAILY_TOKENS must be a number"
  [[ "${CONCIERGE_MAX_AGENTS_PER_USER:-0}" =~ ^[0-9]+$ ]] || die "CONCIERGE_MAX_AGENTS_PER_USER must be a number"
  [[ "${MAX_UPLOAD_SIZE:-20MB}" =~ ^[0-9]+[KMG]B$ ]] || die "MAX_UPLOAD_SIZE like 20MB"
  for v in MAX_UPLOAD_BYTES RL_AUTH_PER_MIN RL_CREATEROOM_PER_HOUR RL_SEND_PER_MIN RL_UPLOAD_PER_HOUR RL_GENERAL_PER_MIN \
           PALPO_RC_MESSAGE_BURST PALPO_MAX_CONCURRENT_REQUESTS PALPO_DB_POOL_SIZE PG_MAX_CONNECTIONS \
           PASION_LOGIN_BURST PASION_REGISTRATION_BURST; do
    [[ "${!v:-}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
  done
  for v in PALPO_RC_MESSAGE_PER_SECOND PASION_LOGIN_PER_SECOND PASION_REGISTRATION_PER_SECOND; do
    [[ "${!v:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$v must be a number"
  done
  if [ "$CONCIERGE_ENABLED" = true ]; then
    [[ "${OLLAMA_URL:-}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "OLLAMA_URL must be http(s)://host[:port]"
    [[ "${OLLAMA_MODEL:-}" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "OLLAMA_MODEL must be set (e.g. qwen2.5-coder:7b)"
  fi
  if [ "$CALLS_ENABLED" = true ]; then
    for v in LIVEKIT_URL LIVEKIT_KEY LIVEKIT_SECRET; do [ -n "${!v:-}" ] || die "CALLS_ENABLED=true needs $v"; done
    [[ "$LIVEKIT_URL" =~ ^wss:// ]] || die "LIVEKIT_URL must start with wss://"
  fi
  if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
    [[ "$GITHUB_CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "GITHUB_CLIENT_ID has unexpected characters"
    [ -n "${GITHUB_CLIENT_SECRET:-}" ] || [ -s "$SECRETS/github_client_secret" ] \
      || die "GITHUB_CLIENT_ID set but no GITHUB_CLIENT_SECRET (env or secrets/github_client_secret)"
  fi
  local s; IFS=',' read -ra s <<< "${FEDERATION_ALLOWLIST:-}"
  for v in ${s[@]+"${s[@]}"}; do v="${v// /}"; [ -z "$v" ] || [[ "$v" =~ ^(\*\.)?[a-z0-9.-]+(:[0-9]+)?$ ]] || die "bad FEDERATION_ALLOWLIST entry '$v'"; done
  if [ "$REGISTRATION_MODE" = open ]; then echo "warning: REGISTRATION_MODE=open lets anyone create accounts" >&2; fi
}

# TLS_MODE=tunnel: cloudflared on this host is the only client, so Caddy must not
# be reachable from the network, and the edge subnet is pinned so the proxy
# addresses that may set client-IP headers are known in advance.
validate_tunnel() {
  case "$BIND_ADDR" in 127.0.0.1|::1) ;; *) die "TLS_MODE=tunnel needs BIND_ADDR=127.0.0.1 (cloudflared connects locally)";; esac
  [[ "${EDGE_SUBNET:-}" =~ ^([0-9]{1,3}\.){3}0/24$ ]] || die "TLS_MODE=tunnel needs EDGE_SUBNET like 172.30.18.0/24"
  # The concierge reaches DOMAIN over HTTPS through Caddy's network alias; there is
  # no TLS inside the box in tunnel mode. TODO: route it through the tunnel instead.
  [ "$CONCIERGE_ENABLED" = false ] || die "TLS_MODE=tunnel does not support the concierge yet; set CONCIERGE_ENABLED=false"
}

# Caddy and Palpo trust settings for TLS_MODE=tunnel. Docker hands published-port
# connections to Caddy from the edge network gateway (.1), so only that address may
# set CF-Connecting-IP; Palpo trusts only the edge subnet (Caddy) for X-Forwarded-For.
tunnel_vars() {
  local prefix="${EDGE_SUBNET%0/24}"
  SITE_SCHEME="http://"; CADDY_GLOBAL_TLS="auto_https off"
  : "${CADDY_TRUSTED_PROXIES:=${prefix}1/32}"
  PALPO_TRUSTED_PROXIES="\"$EDGE_SUBNET\""
}

# pipefail off inside: head closing the pipe makes tr exit 141 (SIGPIPE).
random_secret() { (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"); }

# Create missing secret files. Values are never printed. secrets/ is 0700 so no other
# host user can reach the files; the files are 0644 because compose bind-mounts them
# into containers that read them as non-root uids (postgres 70, agent 10002), except
# admin_password (0600), which only root in the bootstrap container reads.
ensure_secrets() {
  umask 077; [ ! -L "$SECRETS" ] || die "$SECRETS must not be a symlink"
  mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
  local name f
  for name in postgres_password admin_password concierge_password; do
    [ -s "$SECRETS/$name" ] || random_secret 32 > "$SECRETS/$name"
  done
  if [ -n "${GITHUB_CLIENT_SECRET:-}" ]; then printf '%s' "$GITHUB_CLIENT_SECRET" > "$SECRETS/github_client_secret"; fi
  for f in "$SECRETS"/*; do
    [ ! -L "$f" ] || die "secret $f must not be a symlink"
    [ "$(stat -c %u "$f" 2>/dev/null || stat -f %u "$f")" = "$(id -u)" ] || die "secret $f is not owned by $(id -un)"
    chmod 644 "$f"
  done
  # Read only by the operator and by the server entrypoint as root (bootstrap).
  chmod 600 "$SECRETS/admin_password"
}

# Replace ${VAR} with the environment value; an unset variable is an error.
render() {
  perl -pe 's/\$\{([A-Z0-9_]+)\}/exists $ENV{$1} ? $ENV{$1} : die "template variable $1 is not set\n"/ge' "$1" > "$2.tmp"
  # Rewrite in place: compose bind-mounts single files by inode, so a rename would
  # leave running containers on the old file.
  if [ -f "$2" ]; then cat "$2.tmp" > "$2"; rm -f "$2.tmp"; else mv "$2.tmp" "$2"; fi
}

# Render runtime/ from templates. $1 = "bootstrap" opens registration (internal only).
# TODO(R4): over the 50-line budget; split on the per-file seams (Caddy, Palpo, Pasion).
render_runtime() {
  local phase="${1:-final}" t="$BUNDLE/templates"
  umask 077; mkdir -p "$RUNTIME/config"; chmod 700 "$RUNTIME" "$RUNTIME/config"
  SITE_SCHEME=""; PALPO_TRUSTED_PROXIES=""
  if [ "$TLS_MODE" = internal ]; then CADDY_GLOBAL_TLS="local_certs"; else CADDY_GLOBAL_TLS="email ${ACME_EMAIL:-}"; fi
  [ "$TLS_MODE" != tunnel ] || tunnel_vars
  POSTGRES_PASSWORD="$(cat "$SECRETS/postgres_password")"; export POSTGRES_PASSWORD
  local mode="$REGISTRATION_MODE"; [ "$phase" = bootstrap ] && mode=open
  case "$mode" in
    open)   PASSWORD_REGISTRATION_ENABLED=true;  REGISTRATION_TOKEN_REQUIRED=false;;
    invite) PASSWORD_REGISTRATION_ENABLED=true;  REGISTRATION_TOKEN_REQUIRED=true;;
    closed) PASSWORD_REGISTRATION_ENABLED=false; REGISTRATION_TOKEN_REQUIRED=true;;
  esac
  export PASSWORD_REGISTRATION_ENABLED REGISTRATION_TOKEN_REQUIRED
  FEDERATION_ENABLED=true; FEDERATION_ALLOWED_SERVERS=""
  local s e; IFS=',' read -ra s <<< "${FEDERATION_ALLOWLIST:-}"
  for e in ${s[@]+"${s[@]}"}; do e="${e// /}"; [ -z "$e" ] || FEDERATION_ALLOWED_SERVERS+="${FEDERATION_ALLOWED_SERVERS:+, }\"$e\""; done
  export FEDERATION_ENABLED FEDERATION_ALLOWED_SERVERS
  if [ -s "$SECRETS/github_client_secret" ] && [ -n "${GITHUB_CLIENT_ID:-}" ]; then
    install -m 600 "$SECRETS/github_client_secret" "$RUNTIME/config/github-client.secret"
    GITHUB_PROVIDER_BLOCK="$(render_stdout "$t/github-provider.toml.tmpl")"
  else
    rm -f "$RUNTIME/config/github-client.secret"; GITHUB_PROVIDER_BLOCK="# GitHub sign-in off (GITHUB_CLIENT_ID empty)"
  fi
  export GITHUB_PROVIDER_BLOCK
  WELL_KNOWN_CLIENT_JSON="{\"m.homeserver\":{\"base_url\":\"$PUBLIC_URL\"}"
  if [ "$CALLS_ENABLED" = true ]; then
    RTC_FOCI_BLOCK="[[well_known.rtc_foci]]
type = \"livekit\"
livekit_service_url = \"$PUBLIC_URL/livekit/jwt\""
    WELL_KNOWN_CLIENT_JSON+=",\"org.matrix.msc4143.rtc_foci\":[{\"type\":\"livekit\",\"livekit_service_url\":\"$PUBLIC_URL/livekit/jwt\"}]"
    CALLS_ROUTE="handle_path /livekit/jwt/* {
		reverse_proxy livekit-jwt:8080
	}"
  else
    RTC_FOCI_BLOCK="# calls off (CALLS_ENABLED=false)"; CALLS_ROUTE="# calls off"
  fi
  WELL_KNOWN_CLIENT_JSON+="}"
  export RTC_FOCI_BLOCK WELL_KNOWN_CLIENT_JSON CALLS_ROUTE
  # Root (SERVER_NAME) site: Caddy serves .well-known there and sends everything
  # else to Element, unless ROOT_MODE=external (landing page hosted elsewhere).
  ROOT_SITE_BLOCK="# root site not served by Caddy (SERVER_NAME=DOMAIN or ROOT_MODE=external)"
  if [ "$SERVER_NAME" != "$DOMAIN" ] && [ "${ROOT_MODE:-caddy}" = caddy ]; then
    ROOT_SITE_BLOCK="${SITE_SCHEME:-}$SERVER_NAME {
	import security_headers
	handle /.well-known/matrix/server {
		header Content-Type application/json
		respond \`{\"m.server\":\"$DOMAIN:443\"}\` 200
	}
	handle /.well-known/matrix/client {
		header Content-Type application/json
		header Access-Control-Allow-Origin *
		respond \`$WELL_KNOWN_CLIENT_JSON\` 200
	}
	handle {
		redir $ELEMENT_URL{uri} 302
	}
}"
  fi
  export ROOT_SITE_BLOCK
  : "${CADDY_TRUSTED_PROXIES:=}"
  # Separate variable: render_runtime runs twice per deploy (bootstrap, final) and
  # must not wrap an already rendered block again.
  CADDY_SERVERS_BLOCK="# no trusted proxies (CADDY_TRUSTED_PROXIES empty)"
  if [ -n "$CADDY_TRUSTED_PROXIES" ]; then
    CADDY_SERVERS_BLOCK="servers {
		trusted_proxies static $CADDY_TRUSTED_PROXIES
		trusted_proxies_strict
		client_ip_headers CF-Connecting-IP X-Forwarded-For
	}"
  fi
  : "${MAX_UPLOAD_SIZE:=20MB}" "${ELEMENT_CALL_URL:=https://call.element.io}"
  export CADDY_GLOBAL_TLS CADDY_SERVERS_BLOCK MAX_UPLOAD_SIZE ELEMENT_CALL_URL SITE_SCHEME PALPO_TRUSTED_PROXIES
  render "$t/hagency.toml.tmpl" "$RUNTIME/config/hagency.toml"
  render "$t/palpo.toml.tmpl" "$RUNTIME/config/palpo.toml"
  render "$t/pasion.toml.tmpl" "$RUNTIME/config/pasion.toml"
  render "$t/Caddyfile.tmpl" "$RUNTIME/Caddyfile"
  render "$t/element-config.json.tmpl" "$RUNTIME/element-config.json"
  mkdir -p "$RUNTIME/ca"; chmod 755 "$RUNTIME/ca"
  # Element and Caddy run as non-root users and need to read their files.
  chmod 644 "$RUNTIME/Caddyfile" "$RUNTIME/element-config.json"; chmod 755 "$RUNTIME"
  unset POSTGRES_PASSWORD
}

render_stdout() { perl -pe 's/\$\{([A-Z0-9_]+)\}/exists $ENV{$1} ? $ENV{$1} : die "template variable $1 is not set\n"/ge' "$1"; }

# Wait until a compose service reports healthy (or running, if it has no healthcheck).
wait_healthy() {
  local svc="$1" timeout="${2:-300}" id state i
  for ((i = 0; i < timeout; i += 3)); do
    id="$(compose ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
      case "$state" in healthy|running) return 0;; exited|dead) break;; esac
    fi
    sleep 3
  done
  compose logs --tail 40 "$svc" >&2 || true
  die "$svc did not become healthy within ${timeout}s"
}

# Workspace root holding hagency-server/ and hagency-client/ (docker build context).
find_build_context() {
  local d="${HAGENCY_SRC:-$BUNDLE}"
  while [ "$d" != / ]; do
    [ -f "$d/hagency-server/Cargo.toml" ] && [ -f "$d/hagency-client/Cargo.toml" ] && { echo "$d"; return; }
    d="$(dirname "$d")"
  done
  die "cannot find a directory with hagency-server/ and hagency-client/; set HAGENCY_SRC"
}

build_images() {
  local ctx; ctx="$(find_build_context)"
  # The concierge entrypoint is copied from deploy/public inside the context.
  if [ "$BUNDLE" != "$ctx/deploy/public" ]; then
    mkdir -p "$ctx/deploy/public"; cp "$BUNDLE/concierge-entrypoint.sh" "$ctx/deploy/public/concierge-entrypoint.sh"
  fi
  log "building $SERVER_IMAGE (context $ctx; first build takes 20-60 min)"
  nice -n 10 docker buildx build -f "$BUNDLE/Dockerfile" --target server \
    --build-arg BUILD_JOBS="${BUILD_JOBS:-2}" -t "$SERVER_IMAGE" --load "$ctx"
  log "building $CADDY_IMAGE"
  nice -n 10 docker buildx build -f "$BUNDLE/Dockerfile" --target caddy -t "$CADDY_IMAGE" --load "$ctx"
  if [ "$CONCIERGE_ENABLED" = true ]; then
    log "building $CONCIERGE_IMAGE"
    nice -n 10 docker buildx build -f "$BUNDLE/Dockerfile" --target concierge \
      --build-arg BUILD_JOBS="${BUILD_JOBS:-2}" -t "$CONCIERGE_IMAGE" --load "$ctx"
  fi
}

active_profiles() {
  local p=()
  [ "$CONCIERGE_ENABLED" = true ] && [ "$AGENTS_ENABLED" = true ] && p+=(--profile concierge)
  [ "$CALLS_ENABLED" = true ] && p+=(--profile calls)
  echo "${p[@]:-}"
}
