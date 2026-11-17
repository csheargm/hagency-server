#!/usr/bin/env bash
# Dumps are taken per database while running (not one point in time): run during a
# quiet period or ./deploy.sh kill-agents first. TODO: quiesce writers for a snapshot.
# Back up databases (pg_dump per database), server data (media + signing keys +
# state), secrets and .env into BACKUP_DIR/<timestamp>/; keep the newest BACKUP_KEEP.
# The backup holds secrets: keep BACKUP_DIR private and copy it off the host, encrypted.
source "$(dirname "$0")/lib.sh"
load_env
: "${BACKUP_DIR:=./backups}" "${BACKUP_KEEP:=14}"
case "$BACKUP_DIR" in /*) ;; *) BACKUP_DIR="$BUNDLE/${BACKUP_DIR#./}";; esac
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] && [ "$BACKUP_KEEP" -ge 1 ] || die "BACKUP_KEEP must be >= 1"
umask 077; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
final="$BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)"; dest="$final.partial"; mkdir "$dest"
# Written to .partial and renamed only when complete; rotation sees complete ones only.
trap 'rm -rf -- "$dest"' ERR
for db in hagency palpo pasion; do
  log "pg_dump $db"
  compose exec -T postgres pg_dump -U hagency -Fc "$db" > "$dest/$db.dump"
  [ -s "$dest/$db.dump" ] || die "empty dump for $db"
done
log "server data volume (media, signing keys)"
compose run --rm --no-deps -T --entrypoint tar server -C /app/data -czf - . > "$dest/server-data.tgz"
[ -s "$dest/server-data.tgz" ] || die "empty server-data archive"
cp "$ENV_FILE" "$BUNDLE/secrets/.env.backup"; tar -C "$BUNDLE" -czf "$dest/config.tgz" secrets; rm -f "$BUNDLE/secrets/.env.backup"
( cd "$dest" && shasum -a 256 ./* > SHA256SUMS 2>/dev/null || sha256sum ./* > SHA256SUMS )
mv "$dest" "$final"; log "backup written: $final"
# Rotation: delete all but the newest BACKUP_KEEP timestamped directories.
old=()
while IFS= read -r d; do old+=("$d"); done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort)
for ((i = 0; i < ${#old[@]} - BACKUP_KEEP; i++)); do rm -rf -- "${old[$i]}"; log "rotated out ${old[$i]}"; done
