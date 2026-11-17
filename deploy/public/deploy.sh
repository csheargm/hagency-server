#!/usr/bin/env bash
# One-command deploy of the public Hagency server. Idempotent: safe to re-run.
#   ./deploy.sh              validate .env, build/pull, bootstrap once, start, wait, print URLs
#   ./deploy.sh invite [n]   create n one-time sign-up tokens (REGISTRATION_MODE=invite), valid 7 days
#   ./deploy.sh kill-agents  kill switch: stop the concierge and disable agent execution
#   ./deploy.sh resume-agents
#   ./deploy.sh status | down
source "$(dirname "$0")/lib.sh"

bootstrap_once() {
  local marker="$RUNTIME/.bootstrapped" cid
  [ -f "$marker" ] && return 0
  log "first start: bootstrap (nothing is published to the network during this step)"
  render_runtime bootstrap
  compose up -d postgres; wait_healthy postgres 120
  # hagency-server creates the first administrator during a normal start when given
  # --bootstrap-admin; run that start detached, unpublished, then replace it.
  log "creating administrator @$ADMIN_USER:$SERVER_NAME"
  cid="$(compose run -d --no-deps -v "$SECRETS/admin_password:/app/bootstrap-password:ro" server \
    --config /app/config/hagency.toml --bootstrap-admin "$ADMIN_USER" \
    --bootstrap-password-file /run/hagency/bootstrap-password)"
  BOOT_CID="$cid"; wait_container "$cid" 600
  if [ "$CONCIERGE_ENABLED" = true ]; then
    log "registering @$CONCIERGE_USER:$SERVER_NAME (concierge service account)"
    register_internal "$CONCIERGE_USER" "$SECRETS/concierge_password"
  fi
  docker stop "$cid" >/dev/null; docker rm "$cid" >/dev/null
  touch "$marker"
}

wait_container() {
  local i st
  for ((i = 0; i < $2; i += 3)); do
    st="$(docker inspect -f '{{.State.Health.Status}} {{.State.Status}}' "$1")"
    case "$st" in healthy*) return 0;; *exited*|*dead*) docker logs --tail 40 "$1" >&2; die "bootstrap server exited";; esac
    sleep 3
  done
  docker logs --tail 40 "$1" >&2; die "bootstrap server not healthy in $2s"
}

# Register a password account through Pasion's API from inside the server container,
# so the password travels only over stdin (never argv, never the public network).
register_internal() {
  local user="$1" pwfile="$2" body out id
  body="$(printf '{"username":"%s","password":"%s","password_confirm":"%s"}' "$user" "$(cat "$pwfile")" "$(cat "$pwfile")")"
  out="$(printf '%s' "$body" | docker exec -i "$BOOT_CID" curl -sS --max-time 20 -H 'Content-Type: application/json' \
    -H "Origin: $PUBLIC_URL" --data-binary @- http://127.0.0.1:8088/auth/api/v1/auth/register)"
  case "$out" in *'"status":"success"'*) ;; *) die "registering $user failed: $(printf '%s' "$out" | head -c 300)";; esac
  id="$(printf '%s' "$out" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "registering $user: no registration id"
  if [[ "$out" == *'"next_step":"display_name"'* ]]; then
    printf '{"display_name":"%s"}' "$user" | docker exec -i "$BOOT_CID" curl -sS --max-time 20 -H 'Content-Type: application/json' \
      -H "Origin: $PUBLIC_URL" --data-binary @- "http://127.0.0.1:8088/auth/api/v1/auth/register/$id/display-name" >/dev/null
  fi
  out="$(printf '{}' | docker exec -i "$BOOT_CID" curl -sS --max-time 20 -H 'Content-Type: application/json' \
    -H "Origin: $PUBLIC_URL" --data-binary @- "http://127.0.0.1:8088/auth/api/v1/auth/register/$id/finish")"
  case "$out" in *'"status":"success"'*) ;; *) die "finishing $user registration failed: $(printf '%s' "$out" | head -c 300)";; esac
}

cmd_up() {
  load_env; validate_env; ensure_secrets
  case "$IMAGE_MODE" in
    build) build_images ;;
    pull) docker pull "$SERVER_IMAGE"; docker pull "$CADDY_IMAGE"; [ "$CONCIERGE_ENABLED" = false ] || docker pull "$CONCIERGE_IMAGE" ;;
    local) for i in "$SERVER_IMAGE" "$CADDY_IMAGE"; do docker image inspect "$i" >/dev/null || die "image $i not on this host"; done ;;
  esac
  bootstrap_once
  render_runtime final
  # shellcheck disable=SC2046
  compose $(active_profiles) up -d --remove-orphans
  compose restart server caddy element >/dev/null   # pick up the re-rendered config every run
  wait_healthy server 600; wait_healthy caddy 120; wait_healthy element 120
  if [ "$TLS_MODE" = internal ]; then
    # Local tests only: server and concierge dial the public URL (hairpin through
    # Caddy), so they must trust Caddy's local CA. Public certificate material only.
    local root
    root="$(compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt)" || die "no Caddy local CA yet"
    { compose exec -T server cat /etc/ssl/certs/ca-certificates.crt; printf '%s\n' "$root"; } > "$RUNTIME/ca/bundle.pem"
    printf '%s\n' "$root" > "$RUNTIME/ca/root.crt"; chmod 644 "$RUNTIME/ca/"*
    if [ "${EXTRA_CA_BUNDLE:-}" != /run/extra-ca/bundle.pem ]; then
      export EXTRA_CA_BUNDLE=/run/extra-ca/bundle.pem
      # shellcheck disable=SC2046
      compose $(active_profiles) up -d --force-recreate server $( [ "$CONCIERGE_ENABLED" = true ] && [ "$AGENTS_ENABLED" = true ] && echo concierge)
      wait_healthy server 600
    fi
  else
    rm -f "$RUNTIME/ca/root.crt" "$RUNTIME/ca/bundle.pem"
  fi
  if [ "$CONCIERGE_ENABLED" = true ] && [ "$AGENTS_ENABLED" = true ]; then wait_healthy concierge 120; fi
  print_urls
}

print_urls() {
  cat <<MSG

Hagency is up (project $COMPOSE_PROJECT_NAME).
  Element (sign in here): $ELEMENT_URL
  Server / API:           $PUBLIC_URL   (Matrix: $PUBLIC_URL/_matrix/client/versions)
  Admin:                  @$ADMIN_USER:$SERVER_NAME  (password in $SECRETS/admin_password)
  Registration mode:      $REGISTRATION_MODE$( [ "$REGISTRATION_MODE" = invite ] && echo "  (make tokens: ./deploy.sh invite)")
  Concierge:              $( [ "$CONCIERGE_ENABLED" = true ] && [ "$AGENTS_ENABLED" = true ] && echo "@$CONCIERGE_USER:$SERVER_NAME (DM it \"create agent\")" || echo off)
  Calls:                  $CALLS_ENABLED
MSG
}

cmd_invite() {
  load_env
  [ "$REGISTRATION_MODE" = invite ] || die "REGISTRATION_MODE is $REGISTRATION_MODE, not invite"
  local n="${1:-1}" i tok
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le 100 ] || die "count must be 1..100"
  for ((i = 0; i < n; i++)); do
    tok="$(random_secret 24)"
    # SQL via stdin so the token is not in any process argv; tok is [A-Za-z0-9] only.
    printf "INSERT INTO user_registration_tokens (id, token, usage_limit, created_at, expires_at) VALUES (gen_random_uuid(), '%s', 1, now(), now() + interval '7 days');\n" "$tok" \
      | compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U hagency -d pasion >/dev/null
    echo "$tok"
  done
  echo "one-time sign-up tokens above, valid 7 days; sign up at $ELEMENT_URL" >&2
}

set_agents() {
  load_env; validate_env
  sed -i.bak "s/^AGENTS_ENABLED=.*/AGENTS_ENABLED=$1/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  grep -q '^AGENTS_ENABLED=' "$ENV_FILE" || echo "AGENTS_ENABLED=$1" >> "$ENV_FILE"
  AGENTS_ENABLED="$1"; export AGENTS_ENABLED
  [ "$1" = false ] && compose --profile concierge stop concierge || true
  render_runtime final
  compose restart server; wait_healthy server 600
  # shellcheck disable=SC2046
  [ "$1" = true ] && compose $(active_profiles) up -d
  log "agents enabled = $1"
}

case "${1:-up}" in
  up) cmd_up ;;
  invite) shift; cmd_invite "$@" ;;
  kill-agents) set_agents false ;;
  resume-agents) set_agents true ;;
  status) load_env; compose --profile concierge --profile calls ps ;;
  down) load_env; compose --profile concierge --profile calls down ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
