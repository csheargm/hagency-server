# shellcheck shell=bash
# Release lifecycle shared by deploy.sh and rollback.sh. A "release" is an image
# tag, the image IDs it was deployed with, and the config + compose snapshot
# rendered for it: runtime/<env>/<UTC>-<tag>/.
# state/<env>/current and previous each hold one line: "<tag> <release-dir-name>".

# One deploy/rollback/backup at a time per environment.
with_lock() {
  mkdir -p "$STATE"
  exec 9>"$STATE/deploy.lock"
  flock -n 9 || die "another deploy, rollback or backup is running for $ENV_NAME"
}

release_tag() { printf '%s' "${1%% *}"; }
release_dir() { printf '%s' "${1#* }"; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# use_record "<tag> <dir>": point compose at an existing release and check that
# the local images are still the exact bytes that release was deployed with
# (a tag can be re-pulled or re-loaded with different content).
use_record() {
  [ -n "$1" ] || die "no release recorded for $ENV_NAME"
  use_release "$(release_tag "$1")"
  RELEASE_DIR="$RUNTIME/$(release_dir "$1")"; export RELEASE_DIR
  [ -d "$RELEASE_DIR" ] || die "config snapshot $RELEASE_DIR is missing"
  if [ -f "$RELEASE_DIR/images.txt" ]; then
    if ! grep -qx "server=$(image_id "$SERVER_IMAGE")" "$RELEASE_DIR/images.txt" \
       || ! grep -qx "caddy=$(image_id "$CADDY_IMAGE")" "$RELEASE_DIR/images.txt"; then
      die "local images for $(release_tag "$1") differ from the ones this release ran (see $RELEASE_DIR/images.txt)"
    fi
  fi
}

# obtain_images <tag> [archive]: make both images for <tag> present locally.
obtain_images() {
  local tag="$1" archive="${2:-}" img
  if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "image archive $archive not found"
    log "loading images from $archive"
    gunzip -c "$archive" | docker load >/dev/null || die "docker load failed"
  elif [ "$IMAGE_SOURCE" = pull ]; then
    docker pull -q "$(server_image "$tag")" >/dev/null || die "pull failed"
    docker pull -q "$(caddy_image "$tag")" >/dev/null || die "pull failed"
  fi
  for img in "$(server_image "$tag")" "$(caddy_image "$tag")"; do
    [ -n "$(image_id "$img")" ] || die "image $img is not on this host (use --image-archive, IMAGE_SOURCE=pull, or build-image.sh)"
  done
}

# new_release <tag>: render a fresh snapshot and set RECORD. Not meant for $(...):
# errexit must stay on while the snapshot is written.
new_release() {
  local name; name="$(date -u +%Y%m%dT%H%M%SZ)-$1"
  use_release "$1"; RELEASE_DIR="$RUNTIME/$name"; export RELEASE_DIR
  mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
  render_runtime "$RELEASE_DIR"
  printf 'server=%s\ncaddy=%s\n' "$(image_id "$SERVER_IMAGE")" "$(image_id "$CADDY_IMAGE")" > "$RELEASE_DIR/images.txt"
  # shellcheck disable=SC2034 # read by the caller (deploy.sh)
  RECORD="$1 $name"
}

# activate: (re)create every container on the release compose points at.
activate() {
  # shellcheck disable=SC2046
  compose $(compose_profiles) up -d --force-recreate --remove-orphans
}

# Keep the snapshots of the newest 5 releases plus current/previous.
prune_releases() {
  local keep cur prev d
  cur="$(release_dir "$(state_get current)")"; prev="$(release_dir "$(state_get previous)")"
  keep="$(find "$RUNTIME" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' | sort | tail -n 5)"
  while IFS= read -r d; do
    case "$(basename "$d")" in "$cur"|"$prev") continue;; esac
    printf '%s\n' "$keep" | grep -qx "$d" || rm -rf -- "$d"
  done < <(find "$RUNTIME" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*')
}

# newest_backup_for "<record>": the latest complete backup taken while <record> ran.
newest_backup_for() {
  local d
  while IFS= read -r d; do
    if grep -qxF "release=$1" "$d/meta.txt" 2>/dev/null; then printf '%s' "$d"; return 0; fi
  done < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' ! -name '*.partial' 2>/dev/null | sort -r)
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

# rollback_to "<record>" <backup-dir-or-empty> <db-choice>: bring the old release
# back. Returns non-zero when the old release does not come up healthy.
# restore_backup dies (exits the script) on any failed step, even when this
# function runs inside a conditional.
rollback_to() {
  local record="$1" backup="$2" choice="$3"
  use_record "$record"
  log "rolling back to $(release_tag "$record")"
  if [ "$choice" = restore ]; then
    grep -qxF "release=$record" "$backup/meta.txt" \
      || die "$backup was not taken while $(release_tag "$record") ran; restoring it under that release is unsafe"
    restore_backup "$backup"
  elif [ -n "$backup" ]; then
    log "databases kept as they are. To restore later: ./rollback.sh $ENV_NAME --restore-db $backup"
  fi
  activate || { log "compose up of $(release_tag "$record") failed"; return 1; }
  if run_checks; then log "rollback to $(release_tag "$record") healthy"; return 0; fi
  log "rollback release is NOT healthy either; see RUNBOOK 'Both releases fail'"; return 1
}
