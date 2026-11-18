#!/usr/bin/env bash
# Roll back staging or production ON THIS HOST to the previous release (image
# tag + its exact config snapshot), optionally restoring the databases.
#   ./rollback.sh <env>                         previous release, databases kept
#   ./rollback.sh <env> --restore-db [<backup>] also restore databases + server-data
#                                               (default backup: the last pre-deploy one)
#   ./rollback.sh <env> --list                  releases and backups on this host
# Restoring the databases loses everything written after that backup. It is
# needed when the newer release migrated a schema the older one cannot read.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"
# shellcheck source=scripts/ops.sh
. "$HERE/scripts/ops.sh"
# shellcheck source=scripts/checks.sh
. "$HERE/scripts/checks.sh"
# shellcheck source=scripts/release.sh
. "$HERE/scripts/release.sh"

list() {
  echo "current:  $(state_get current)"; echo "previous: $(state_get previous)"
  echo "releases:"; find "$RUNTIME" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' -exec basename {} \; 2>/dev/null | sort | sed 's/^/  /'
  echo "backups:";  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' ! -name '*.partial' 2>/dev/null | sort | sed 's/^/  /'
}

main() {
  local env="${1:-}"; [ $# -ge 1 ] || { sed -n '2,9p' "$0"; exit 2; }; shift
  load_env "$env"; validate_env
  local choice=keep backup="" current previous
  case "${1:-}" in
    --list) list; return;;
    --restore-db) choice=restore; backup="${2:-$(state_get last_backup)}"; [ -n "$backup" ] || die "no backup recorded; pass one (see --list)";;
    "") ;;
    *) die "unknown option $1";;
  esac
  current="$(state_get current)"; previous="$(state_get previous)"
  [ -n "$previous" ] || die "no previous release recorded for $ENV_NAME"
  if [ "$ENV_NAME" = production ] && [ -t 0 ]; then
    printf 'Roll PRODUCTION back from %s to %s (databases: %s)? [y/N] ' "$(release_tag "$current")" "$(release_tag "$previous")" "$choice" >&2
    read -r a; case "$a" in y|Y|yes) ;; *) die "not confirmed";; esac
  fi
  with_lock
  rollback_to "$previous" "$backup" "$choice" || die "rollback finished unhealthy"
  state_set previous "$current"; state_set current "$previous"
  log "current release is now $(release_tag "$previous")"
}

main "$@"
