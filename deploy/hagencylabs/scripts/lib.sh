# shellcheck shell=bash
# Shared helpers for deploy.sh, rollback.sh, backup.sh, check.sh. Sourced, not run.
# Environment, validation, config rendering and image state. Operations that
# touch containers or data live in ops.sh.
set -euo pipefail
BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Refuse group/world-readable secret-bearing files on Linux hosts.
require_private() {
  [ -f "$1" ] || die "$1 missing"
  [ ! -L "$1" ] || die "$1 must not be a symlink"
  if [ "$(uname)" = Linux ] && [ -n "$(find "$1" -perm /077 2>/dev/null)" ]; then die "$1 is readable by others: chmod 600 $1"; fi
}

# load_env staging|production: sources env/<env>.env and secrets/<env>.env.
load_env() {
  ENV_NAME="${1:-}"
  case "$ENV_NAME" in staging|production) ;; *) die "environment must be staging or production";; esac
  ENV_FILE="${ENV_FILE:-$BUNDLE/env/$ENV_NAME.env}"
  SECRETS_FILE="${SECRETS_FILE:-$BUNDLE/secrets/$ENV_NAME.env}"
  require_private "$ENV_FILE"; require_private "$SECRETS_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  # Secrets stay unexported shell variables: no child process (docker, curl)
  # inherits them. render_runtime exports them only inside its own subshell.
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
  [ "${DEPLOY_ENV:-}" = "$ENV_NAME" ] || die "$ENV_FILE says DEPLOY_ENV=${DEPLOY_ENV:-unset}, not $ENV_NAME"
  RUNTIME="$BUNDLE/runtime/$ENV_NAME"; STATE="$BUNDLE/state/$ENV_NAME"
  BACKUPS="${BACKUP_DIR:-$BUNDLE/backups}/$ENV_NAME"
  PUBLIC_URL="https://$DOMAIN"; ELEMENT_URL="https://$ELEMENT_DOMAIN"
  : "${ACME_CA:=https://acme-v02.api.letsencrypt.org/directory}" "${IMAGE_SOURCE:=local}" "${ROLLBACK_DB:=ask}"
  export ENV_NAME RUNTIME STATE BACKUPS PUBLIC_URL ELEMENT_URL ACME_CA IMAGE_SOURCE ROLLBACK_DB COMPOSE_PROJECT_NAME
}

is_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; }
is_bool() { [ "$1" = true ] || [ "$1" = false ]; }

validate_names() {
  local v
  for v in SERVER_NAME DOMAIN ELEMENT_DOMAIN; do is_hostname "${!v:-}" || die "$v '${!v:-}' is not a lowercase host name"; done
  if [ "$SERVER_NAME" = "$DOMAIN" ] || [ "$DOMAIN" = "$ELEMENT_DOMAIN" ] || [ "$SERVER_NAME" = "$ELEMENT_DOMAIN" ]; then
    die "SERVER_NAME, DOMAIN and ELEMENT_DOMAIN must be three different names"
  fi
  # Production and staging names are fixed here so a copied env file cannot
  # point the wrong environment at the other's server_name.
  if [ "$ENV_NAME" = production ]; then [ "$SERVER_NAME" = hagencylabs.xyz ] || die "production SERVER_NAME must be hagencylabs.xyz"
  else [ "$SERVER_NAME" != hagencylabs.xyz ] || die "staging must not use the production server_name"; fi
  [[ "$COMPOSE_PROJECT_NAME" = "hagencylabs-$ENV_NAME" ]] || die "COMPOSE_PROJECT_NAME must be hagencylabs-$ENV_NAME"
  [[ "${ADMIN_USER:-}" =~ ^[a-z0-9._=-]+$ ]] || die "ADMIN_USER must be a lowercase Matrix localpart"
  [[ "${ACME_EMAIL:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "ACME_EMAIL must be an e-mail address"
  [[ "$ACME_CA" =~ ^https://[A-Za-z0-9./-]+$ ]] || die "ACME_CA must be an https URL"
}

validate_options() {
  local v
  case "${REGISTRATION_MODE:-}" in invite|open|closed) ;; *) die "REGISTRATION_MODE must be invite|open|closed";; esac
  case "${FEDERATION_MODE:-}" in allowlist|open) ;; *) die "FEDERATION_MODE must be allowlist|open";; esac
  case "$IMAGE_SOURCE" in pull|local) ;; *) die "IMAGE_SOURCE must be pull|local";; esac
  case "$ROLLBACK_DB" in ask|restore|keep) ;; *) die "ROLLBACK_DB must be ask|restore|keep";; esac
  for v in AGENTS_ENABLED CALLS_ENABLED; do is_bool "${!v:-}" || die "$v must be true|false"; done
  for v in MAX_UPLOAD_BYTES RL_AUTH_PER_MIN RL_CREATEROOM_PER_HOUR RL_UPLOAD_PER_HOUR RL_GENERAL_PER_MIN RL_FEDERATION_PER_MIN \
           PALPO_RC_MESSAGE_BURST PALPO_MAX_CONCURRENT_REQUESTS PALPO_DB_POOL_SIZE PG_MAX_CONNECTIONS BACKUP_KEEP; do
    [[ "${!v:-}" =~ ^[1-9][0-9]*$ ]] || die "$v must be a positive integer"
  done
  [[ "${PALPO_RC_MESSAGE_PER_SECOND:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "PALPO_RC_MESSAGE_PER_SECOND must be a number"
  [[ "${MAX_UPLOAD_SIZE:-}" =~ ^[0-9]+[KMG]B$ ]] || die "MAX_UPLOAD_SIZE like 20MB"
  [[ "${NATIVE_DESKTOP_CLIENT_ID:-}" =~ ^[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]] || die "NATIVE_DESKTOP_CLIENT_ID must be a ULID"
  [[ "${GITHUB_PROVIDER_ID:-}" =~ ^[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]] || die "GITHUB_PROVIDER_ID missing: run ./gen-secrets.sh $ENV_NAME"
  [[ "${POSTGRES_PASSWORD:-}" =~ ^[A-Za-z0-9]{24,}$ ]] || die "POSTGRES_PASSWORD missing or not alphanumeric: run ./gen-secrets.sh $ENV_NAME"
  [ -n "${ADMIN_PASSWORD:-}" ] || die "ADMIN_PASSWORD missing: run ./gen-secrets.sh $ENV_NAME"
  if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
    [[ "$GITHUB_CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "GITHUB_CLIENT_ID has unexpected characters"
    [ -n "${GITHUB_CLIENT_SECRET:-}" ] || die "GITHUB_CLIENT_ID set but GITHUB_CLIENT_SECRET empty in $SECRETS_FILE"
  fi
  if [ "$CALLS_ENABLED" = true ]; then
    [[ "${LIVEKIT_URL:-}" =~ ^wss://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || die "CALLS_ENABLED=true needs LIVEKIT_URL=wss://host"
    if [ -z "${LIVEKIT_KEY:-}" ] || [ -z "${LIVEKIT_SECRET:-}" ]; then die "CALLS_ENABLED=true needs LIVEKIT_KEY and LIVEKIT_SECRET"; fi
  fi
  [[ "${RESEND_API_KEY:-}" =~ ^[A-Za-z0-9_-]*$ ]] || die "RESEND_API_KEY has unexpected characters"
  # Values pasted into JSON or a compose env file: plain characters only.
  [[ "${BRAND:-}" =~ ^[A-Za-z0-9\ ._-]+$ ]] || die "BRAND may contain letters, digits, space . _ - only"
  [[ "${LIVEKIT_SECRET:-}" =~ ^[A-Za-z0-9]*$ && "${LIVEKIT_KEY:-}" =~ ^[A-Za-z0-9]*$ ]] || die "LIVEKIT_KEY/SECRET must be alphanumeric"
  for v in SERVER_CPUS PG_CPUS; do [[ "${!v:-1.0}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$v must be a number"; done
  for v in SERVER_MEM PG_MEM; do [[ "${!v:-1g}" =~ ^[0-9]+[kmg]$ ]] || die "$v like 2g"; done
  [[ "${SERVER_RUST_LOG:-warn}" =~ ^[A-Za-z0-9_:=,.-]+$ ]] || die "SERVER_RUST_LOG has unexpected characters"
  [[ "${EMAIL_FROM:-}" != *\'* && "${EMAIL_REPLY_TO:-}" != *\'* ]] || die "EMAIL_FROM/EMAIL_REPLY_TO must not contain single quotes"
}

validate_env() { validate_names; validate_options; }

# Compose runs with an EMPTY environment plus the release's own compose.env and
# compose-file copy: no secret reaches compose, and a rollback uses the old
# release's compose definition, limits and profiles, not today's checkout.
compose() {
  if [ -z "${RELEASE_DIR:-}" ] || [ ! -f "$RELEASE_DIR/compose.env" ]; then die "no release selected (RELEASE_DIR)"; fi
  env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} docker compose \
    --project-directory "$BUNDLE" -f "$RELEASE_DIR/docker-compose.yml" --env-file "$RELEASE_DIR/compose.env" \
    -p "$COMPOSE_PROJECT_NAME" "$@"
}

# Replace ${NAME} with the environment value; an unset variable is an error.
render_stdout() {
  perl -pe 's/\$\{([A-Z0-9_]+)\}/exists $ENV{$1} ? $ENV{$1} : die "template variable $1 is not set in $ARGV\n"/ge' "$1"
}
render() { render_stdout "$1" > "$2.tmp" || die "rendering $1 failed"; mv -f "$2.tmp" "$2"; }

# Derived blocks that depend on optional features. They are TOML/Caddyfile text
# substituted into templates, never word-split commands (hence SC2089/SC2090 off).
# shellcheck disable=SC2089,SC2090
export_feature_blocks() {
  case "$REGISTRATION_MODE" in
    open)   PASSWORD_REGISTRATION_ENABLED=true;  REGISTRATION_TOKEN_REQUIRED=false;;
    invite) PASSWORD_REGISTRATION_ENABLED=true;  REGISTRATION_TOKEN_REQUIRED=true;;
    closed) PASSWORD_REGISTRATION_ENABLED=false; REGISTRATION_TOKEN_REQUIRED=true;;
  esac
  PASSWORD_RECOVERY_ENABLED=false; EMAIL_BLOCK="# email off (RESEND_API_KEY empty)"
  if [ -n "${RESEND_API_KEY:-}" ]; then PASSWORD_RECOVERY_ENABLED=true; EMAIL_BLOCK="$(render_stdout "$BUNDLE/config/email-resend.toml.example")" || die "email block"; fi
  GITHUB_PROVIDER_BLOCK="# GitHub sign-in off (GITHUB_CLIENT_ID empty)"
  if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
    GITHUB_PROVIDER_BLOCK="$(render_stdout "$BUNDLE/config/github-provider.toml.example")" || die "GitHub block"
  fi
  FEDERATION_ALLOWED_LINE="# federation open to every server (FEDERATION_MODE=open)"
  if [ "$FEDERATION_MODE" = allowlist ]; then
    local list="" e; IFS=',' read -ra entries <<< "${FEDERATION_ALLOWLIST:-}"
    for e in ${entries[@]+"${entries[@]}"}; do
      e="${e// /}"; [ -z "$e" ] && continue
      [[ "$e" =~ ^(\*\.)?[a-z0-9.-]+(:[0-9]+)?$ ]] || die "bad FEDERATION_ALLOWLIST entry '$e'"
      list+="${list:+, }\"$e\""
    done
    FEDERATION_ALLOWED_LINE="allowed_servers = [$list]"
  fi
  export PASSWORD_REGISTRATION_ENABLED REGISTRATION_TOKEN_REQUIRED PASSWORD_RECOVERY_ENABLED EMAIL_BLOCK
  export GITHUB_PROVIDER_BLOCK FEDERATION_ALLOWED_LINE
}

# shellcheck disable=SC2089,SC2090
export_calls_blocks() {
  WELL_KNOWN_CLIENT_JSON="{\"m.homeserver\":{\"base_url\":\"$PUBLIC_URL\"}"
  RTC_FOCI_BLOCK="# calls off (CALLS_ENABLED=false)"; CALLS_ROUTE="# calls off"
  if [ "$CALLS_ENABLED" = true ]; then
    RTC_FOCI_BLOCK="[[well_known.rtc_foci]]
type = \"livekit\"
livekit_service_url = \"$PUBLIC_URL/livekit/jwt\""
    WELL_KNOWN_CLIENT_JSON+=",\"org.matrix.msc4143.rtc_foci\":[{\"type\":\"livekit\",\"livekit_service_url\":\"$PUBLIC_URL/livekit/jwt\"}]"
    CALLS_ROUTE="handle_path /livekit/jwt/* {
		reverse_proxy livekit-jwt:8080
	}"
  fi
  WELL_KNOWN_CLIENT_JSON+="}"
  export WELL_KNOWN_CLIENT_JSON RTC_FOCI_BLOCK CALLS_ROUTE
}

# render_runtime <dir>: write every rendered file into <dir> (a fresh snapshot
# per deploy, so rollback can return to the exact previous config). Runs in a
# subshell so the secret exports below end with it. Needs use_release first.
render_runtime() (
  set -euo pipefail
  local out="$1" c="$BUNDLE/config"
  [ ! -e "$out" ] || die "snapshot $out already exists"
  export POSTGRES_PASSWORD ADMIN_PASSWORD GITHUB_CLIENT_SECRET RESEND_API_KEY LIVEKIT_SECRET GITHUB_PROVIDER_ID
  umask 077; mkdir -p "$out/config" "$out/secrets"
  export_feature_blocks; export_calls_blocks
  render "$c/hagency.toml.example" "$out/config/hagency.toml"
  render "$c/palpo.toml.example" "$out/config/palpo.toml"
  render "$c/pasion.toml.example" "$out/config/pasion.toml"
  render "$c/Caddyfile.example" "$out/Caddyfile"
  render "$c/element-config.json.example" "$out/element-config.json"
  [ -z "${GITHUB_CLIENT_ID:-}" ] || printf '%s' "$GITHUB_CLIENT_SECRET" > "$out/config/github-client.secret"
  printf '%s' "$POSTGRES_PASSWORD" > "$out/secrets/postgres_password"
  printf '%s' "$ADMIN_PASSWORD" > "$out/secrets/admin_password"
  printf 'LIVEKIT_SECRET=%s\n' "${LIVEKIT_SECRET:-}" > "$out/secrets/livekit.env"
  # Readers: server entrypoint (root, then copies to 0600), Caddy and Element run
  # as non-root and need their files; postgres (uid 70) reads its password.
  # The snapshot directory itself stays 0700, so other host users see nothing.
  chmod 700 "$out"; chmod 755 "$out/config" "$out/secrets"
  chmod 644 "$out/Caddyfile" "$out/element-config.json" "$out/secrets/postgres_password"
  chmod 600 "$out/config/"* "$out/secrets/admin_password" "$out/secrets/livekit.env"
  write_compose_inputs "$out"
)

# The compose file copy, its interpolation values and profiles for this release.
write_compose_inputs() {
  local out="$1" v
  cp "$BUNDLE/docker-compose.yml" "$out/docker-compose.yml"
  {
    printf 'SERVER_IMAGE=%s\nCADDY_IMAGE=%s\nRELEASE_DIR=%s\n' "$SERVER_IMAGE" "$CADDY_IMAGE" "$out"
    for v in SERVER_NAME DOMAIN PG_MAX_CONNECTIONS PG_CPUS PG_MEM SERVER_CPUS SERVER_MEM SERVER_RUST_LOG LIVEKIT_URL LIVEKIT_KEY; do
      printf '%s=%s\n' "$v" "${!v:-}"
    done
  } > "$out/compose.env"
  if [ "$CALLS_ENABLED" = true ]; then echo "--profile calls" > "$out/profiles"; else : > "$out/profiles"; fi
  chmod 600 "$out/compose.env" "$out/profiles" "$out/docker-compose.yml"
}

# --- Image references and deploy state (state/<env>/current, previous) ---
server_image() { printf '%s:%s' "$SERVER_IMAGE_REPO" "$1"; }
caddy_image() { printf '%s:%s' "$CADDY_IMAGE_REPO" "$1"; }
state_get() { if [ -f "$STATE/$1" ]; then cat "$STATE/$1"; fi; }
state_set() { umask 077; mkdir -p "$STATE"; printf '%s\n' "$2" > "$STATE/$1.tmp"; mv -f "$STATE/$1.tmp" "$STATE/$1"; }
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }

# Point compose at a tag and its config snapshot (runtime/<env>/<tag>).
use_release() {
  valid_tag "$1" || die "bad image tag '$1'"
  SERVER_IMAGE="$(server_image "$1")"; CADDY_IMAGE="$(caddy_image "$1")"; RELEASE_DIR="$RUNTIME/$1"
  export SERVER_IMAGE CADDY_IMAGE RELEASE_DIR
}

compose_profiles() { cat "$RELEASE_DIR/profiles"; }
