#!/usr/bin/env bash
# Deploy one image tag to staging or production ON THIS HOST.
#   ./deploy.sh <env> --tag <tag> [--image-archive file.tar.gz] [--yes]
#   ./deploy.sh <env> invite [n]     one-time sign-up tokens (REGISTRATION_MODE=invite)
#   ./deploy.sh <env> status | logs [service]
# Steps: images present -> config snapshot -> (first start: create admin) ->
# stop server + backup (pg_dump x3, server-data, env/secrets, image tags) ->
# up -d -> health checks -> on failure automatic rollback to the previous release
# (database restore per ROLLBACK_DB: ask | restore | keep).
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"
# shellcheck source=scripts/ops.sh
. "$HERE/scripts/ops.sh"
# shellcheck source=scripts/checks.sh
. "$HERE/scripts/checks.sh"
# shellcheck source=scripts/release.sh
. "$HERE/scripts/release.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

confirm_production() {
  [ "$ENV_NAME" = production ] || return 0
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "production deploy needs a terminal confirmation or --yes"
  local answer
  printf 'Deploy %s to PRODUCTION (%s)? Type the server name to continue: ' "$1" "$SERVER_NAME" >&2
  read -r answer; [ "$answer" = "$SERVER_NAME" ] || die "not confirmed"
}

# Gate: the tag must already have passed staging with these exact image bytes,
# unless explicitly overridden. Runs after the images are on this host.
require_staged() {
  [ "$ENV_NAME" = production ] || return 0
  [ "${ALLOW_UNSTAGED:-0}" = 1 ] && { log "ALLOW_UNSTAGED=1: skipping the staging sign-off check"; return 0; }
  local marker="$BUNDLE/state/promoted/$1"
  [ -f "$marker" ] || die "tag $1 has no staging sign-off ($marker). Run './promote.sh $1' after staging passes"
  grep -qx "server_id=$(image_id "$(server_image "$1")")" "$marker" \
    || die "the local $1 server image is not the one that was promoted (compare $marker)"
}

# Stop the running release and back it up; on failure restart it and stop.
pre_deploy_backup() {
  local current="$1" tag="$2"
  use_record "$current"
  log "stopping server for a consistent pre-deploy backup (downtime starts)"
  compose stop server >/dev/null || die "cannot stop the running server"
  if ! BACKUP="$(backup_now "pre-$tag")"; then
    activate || true
    die "pre-deploy backup failed; $(release_tag "$current") restarted, nothing deployed"
  fi
  log "backup: $BACKUP"
}

cmd_deploy() {
  local tag="$1" archive="$2" current choice
  valid_tag "$tag" || die "--tag is required (see build-image.sh)"
  confirm_production "$tag"; with_lock
  obtain_images "$tag" "$archive"; require_staged "$tag"
  new_release "$tag"; local record="$RECORD"; use_record "$record"
  log "release $record"
  bootstrap_once
  current="$(state_get current)"; BACKUP=""
  if [ -n "$current" ] && [ "${SKIP_BACKUP:-0}" != 1 ]; then pre_deploy_backup "$current" "$tag"; fi
  use_record "$record"
  # shellcheck disable=SC2119 # run_checks takes an optional flag, not our args
  if activate && run_checks; then
    [ -z "$current" ] || state_set previous "$current"
    state_set current "$record"; prune_releases
    log "deployed $tag to $ENV_NAME"; return 0
  fi
  [ -n "$current" ] || die "first deploy of $tag failed and there is no previous release; containers left for inspection"
  choice="$(decide_db_restore "$BACKUP")"
  if rollback_to "$current" "$BACKUP" "$choice"; then
    die "deploy of $tag failed; rolled back to $(release_tag "$current") (healthy)"
  fi
  die "deploy of $tag failed AND the rollback to $(release_tag "$current") is unhealthy: act now (RUNBOOK section 8)"
}

cmd_invite() {
  [ "$REGISTRATION_MODE" = invite ] || die "REGISTRATION_MODE is $REGISTRATION_MODE, not invite"
  local n="${1:-1}" i tok
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt 100 ]; then die "count must be 1..100"; fi
  use_record "$(state_get current)"
  for ((i = 0; i < n; i++)); do
    tok="$( (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24) )"
    # SQL on stdin: the token never appears in a process argument list.
    printf "INSERT INTO user_registration_tokens (id, token, usage_limit, created_at, expires_at) VALUES (gen_random_uuid(), '%s', 1, now(), now() + interval '7 days');\n" "$tok" \
      | compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U hagency -d pasion >/dev/null
    echo "$tok"
  done
  echo "one-time sign-up tokens above (meant to be handed out), valid 7 days" >&2
}

main() {
  [ $# -ge 1 ] || usage
  local env="$1"; shift
  load_env "$env"; validate_env
  local tag="" archive="" sub="deploy"
  case "${1:-}" in invite|status|logs) sub="$1"; shift;; esac
  case "$sub" in
    invite) cmd_invite "$@"; return;;
    status) use_record "$(state_get current)"; compose ps; echo "current: $(state_get current)"; echo "previous: $(state_get previous)"
            echo "images:"; sed 's/^/  /' "$RELEASE_DIR/images.txt"; return;;
    logs) use_record "$(state_get current)"; compose logs --tail 200 "$@"; return;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2;;
      --image-archive) archive="${2:-}"; shift 2;;
      --yes) ASSUME_YES=1; shift;;
      *) usage;;
    esac
  done
  cmd_deploy "$tag" "$archive"
}

main "$@"
