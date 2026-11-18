# shellcheck shell=bash
# Release lifecycle shared by deploy.sh and rollback.sh. A "release" is an image
# tag plus the config snapshot rendered for it: runtime/<env>/<UTC>-<tag>/.
# state/<env>/current and previous each hold one line: "<tag> <release-dir-name>".

# One deploy/rollback at a time per environment.
with_lock() {
  mkdir -p "$STATE"
  exec 9>"$STATE/deploy.lock"
  flock -n 9 || die "another deploy or rollback is running for $ENV_NAME"
}

release_tag() { printf '%s' "${1%% *}"; }
release_dir() { printf '%s' "${1#* }"; }

# use_record "<tag> <dir>": point compose at an existing release.
use_record() {
  use_release "$(release_tag "$1")"
  RELEASE_DIR="$RUNTIME/$(release_dir "$1")"; export RELEASE_DIR
  [ -d "$RELEASE_DIR" ] || die "config snapshot $RELEASE_DIR is missing"
}

# obtain_images <tag> [archive]: make both images for <tag> present locally.
obtain_images() {
  local tag="$1" archive="${2:-}" img
  if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "image archive $archive not found"
    log "loading images from $archive"
    gunzip -c "$archive" | docker load >/dev/null
  elif [ "$IMAGE_SOURCE" = pull ]; then
    docker pull -q "$(server_image "$tag")" >/dev/null; docker pull -q "$(caddy_image "$tag")" >/dev/null
  fi
  for img in "$(server_image "$tag")" "$(caddy_image "$tag")"; do
    docker image inspect "$img" >/dev/null 2>&1 || die "image $img is not on this host (use --image-archive, IMAGE_SOURCE=pull, or build-image.sh)"
  done
}

# new_release <tag>: render a fresh config snapshot; prints the record.
new_release() {
  local name; name="$(date -u +%Y%m%dT%H%M%SZ)-$1"
  use_release "$1"; RELEASE_DIR="$RUNTIME/$name"; export RELEASE_DIR
  mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
  render_runtime "$RELEASE_DIR"
  printf '%s %s' "$1" "$name"
}

# activate: (re)create every container on the release compose points at.
activate() {
  # shellcheck disable=SC2046
  compose $(compose_profiles) up -d --force-recreate --remove-orphans
}

# Keep the config snapshots of the newest 5 releases plus current/previous.
prune_releases() {
  local keep cur prev d
  cur="$(release_dir "$(state_get current)")"; prev="$(release_dir "$(state_get previous)")"
  keep="$(find "$RUNTIME" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' | sort | tail -n 5)"
  while IFS= read -r d; do
    case "$(basename "$d")" in "$cur"|"$prev") continue;; esac
    printf '%s\n' "$keep" | grep -qx "$d" || rm -rf -- "$d"
  done < <(find "$RUNTIME" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*')
}

# decide_db_restore <backup-dir>: "restore" or "keep" according to ROLLBACK_DB.
decide_db_restore() {
  local answer
  [ -n "$1" ] || { echo keep; return; }
  case "$ROLLBACK_DB" in
    restore|keep) echo "$ROLLBACK_DB" ;;
    ask)
      if [ -t 0 ]; then
        printf 'Restore the databases from %s?\nData written since then is lost. Needed if the new release migrated the schema. [y/N] ' "$1" >&2
        read -r answer; case "$answer" in y|Y|yes) echo restore;; *) echo keep;; esac
      else echo keep; fi ;;
  esac
}

# rollback_to "<record>" <backup-dir-or-empty> <db-choice>: bring the old release back.
rollback_to() {
  local record="$1" backup="$2" choice="$3"
  use_record "$record"
  log "rolling back to $(release_tag "$record")"
  if [ "$choice" = restore ]; then
    compose stop server >/dev/null 2>&1 || true
    restore_backup "$backup"
  elif [ -n "$backup" ]; then
    log "databases kept as they are. To restore later: ./rollback.sh $ENV_NAME --restore-db $backup"
  fi
  activate
  if run_checks; then log "rollback to $(release_tag "$record") healthy"; return 0; fi
  log "rollback release is NOT healthy either; see RUNBOOK 'Both releases fail'"; return 1
}
