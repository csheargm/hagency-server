# shellcheck shell=bash
# shellcheck disable=SC2153 # STATE, RUNTIME, BACKUPS are set by load_env in lib.sh
# Container and data operations: health waits, first-start bootstrap, backup,
# restore. Sourced after lib.sh and load_env/use_release.

# Wait until a compose service is healthy (or running, if it has no healthcheck).
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
  compose logs --tail 60 "$svc" >&2 || true
  echo "error: $svc did not become healthy within ${timeout}s" >&2
  return 1
}

wait_container_healthy() {
  local cid="$1" timeout="$2" i st
  for ((i = 0; i < timeout; i += 3)); do
    st="$(docker inspect -f '{{.State.Health.Status}} {{.State.Status}}' "$cid")"
    case "$st" in healthy*) return 0;; *exited*|*dead*) docker logs --tail 60 "$cid" >&2; return 1;; esac
    sleep 3
  done
  docker logs --tail 60 "$cid" >&2; return 1
}

# First start only: create the administrator. The server runs unpublished
# (no Caddy) during this step; its password travels as a read-only file mount.
bootstrap_once() {
  local marker="$STATE/bootstrapped" cid
  [ -f "$marker" ] && return 0
  log "first start: creating administrator @$ADMIN_USER:$SERVER_NAME"
  compose up -d postgres; wait_healthy postgres 120 || die "postgres not healthy"
  cid="$(compose run -d --no-deps -v "$RELEASE_DIR/secrets/admin_password:/app/bootstrap-password:ro" server \
    --config /app/config/hagency.toml --bootstrap-admin "$ADMIN_USER" \
    --bootstrap-password-file /run/hagency/bootstrap-password)"
  if ! wait_container_healthy "$cid" 900; then docker rm -f "$cid" >/dev/null; die "bootstrap start failed"; fi
  docker stop "$cid" >/dev/null; docker rm "$cid" >/dev/null
  state_set bootstrapped "$(date -u +%FT%TZ)"
}

sha_tool() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# backup_now <label>: pg_dump of every database, the server-data volume, the
# env + secrets files and the image tags. Prints the backup directory.
# Run with the server stopped for a consistent cross-database snapshot (deploy
# does); the nightly cron run is per-database consistent only.
backup_now() {
  local label="$1" final dest db
  umask 077; mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  final="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-$label"; dest="$final.partial"; mkdir "$dest"
  compose up -d postgres >&2; wait_healthy postgres 120 >&2 || die "postgres not healthy; no backup"
  for db in hagency palpo pasion; do
    compose exec -T postgres pg_dump -U hagency -Fc "$db" > "$dest/$db.dump" || die "pg_dump $db failed"
    [ -s "$dest/$db.dump" ] || die "empty dump for $db"
  done
  compose run --rm --no-deps -T --entrypoint tar server -C /app/data -czf - . > "$dest/server-data.tgz" \
    || die "server-data archive failed"
  [ -s "$dest/server-data.tgz" ] || die "empty server-data archive"
  # Called as `if ! x="$(backup_now)"` (errexit is off there): every step checks itself.
  cp "$ENV_FILE" "$dest/env.env" || die "copying env file failed"
  cp "$SECRETS_FILE" "$dest/secrets.env" || die "copying secrets file failed"
  printf 'env=%s\ncreated=%s\nserver_image=%s\ncaddy_image=%s\nrelease=%s\n' "$ENV_NAME" "$(date -u +%FT%TZ)" \
    "$SERVER_IMAGE" "$CADDY_IMAGE" "$(state_get current)" > "$dest/meta.txt" || die "writing meta.txt failed"
  ( cd "$dest" && sha_tool ./* > SHA256SUMS ) || die "checksums failed"
  mv "$dest" "$final" || die "cannot finalize $final"
  encrypt_offsite "$final" || die "encrypted off-host copy failed"
  rotate_backups
  printf '%s\n' "$final"
}

# Optional encrypted copy for off-host storage (age public key; private key stays off the host).
encrypt_offsite() {
  [ -n "${BACKUP_AGE_RECIPIENT:-}" ] || return 0
  command -v age >/dev/null || die "BACKUP_AGE_RECIPIENT set but age is not installed (apt install age)"
  mkdir -p "$BACKUPS/offsite"
  tar -C "$(dirname "$1")" -cf - "$(basename "$1")" | age -r "$BACKUP_AGE_RECIPIENT" > "$BACKUPS/offsite/$(basename "$1").tar.age"
}

rotate_backups() {
  local dirs=() d i
  while IFS= read -r d; do dirs+=("$d"); done < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '2*Z-*' ! -name '*.partial' | sort)
  for ((i = 0; i < ${#dirs[@]} - BACKUP_KEEP; i++)); do rm -rf -- "${dirs[$i]}"; rm -f -- "$BACKUPS/offsite/$(basename "${dirs[$i]}").tar.age"; done
}

# restore_backup <dir>: replace all three databases and the server-data volume.
# Destroys data written after the backup. Callers stop the server first.
restore_backup() {
  local src="$1" db
  [ -f "$src/SHA256SUMS" ] || die "$src is not a backup directory"
  ( cd "$src" && sha_tool -c SHA256SUMS >/dev/null ) || die "checksum mismatch in $src"
  grep -qx "env=$ENV_NAME" "$src/meta.txt" || die "$src is not a $ENV_NAME backup (never restore across environments)"
  compose stop server caddy >/dev/null 2>&1 || true
  compose up -d postgres; wait_healthy postgres 120 || die "postgres not healthy"
  for db in hagency palpo pasion; do
    log "restoring database $db"
    compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U hagency -d postgres \
      -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" -c "CREATE DATABASE $db OWNER hagency;"
    compose exec -T postgres pg_restore -U hagency -d "$db" --no-owner --exit-on-error < "$src/$db.dump"
  done
  log "restoring server-data volume"
  compose run --rm --no-deps -T --entrypoint sh server -c 'find /app/data -mindepth 1 -delete && tar -C /app/data -xzf -' \
    < "$src/server-data.tgz"
}
