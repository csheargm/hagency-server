#!/usr/bin/env bash
# Restore a backup made by backup.sh. Destroys current databases and server data.
#   ./restore.sh backups/20261116T120000Z --yes
source "$(dirname "$0")/lib.sh"
src="${1:-}"; [ -d "$src" ] || die "usage: $0 <backup-dir> --yes"
[ "${2:-}" = --yes ] || die "restore overwrites all data; re-run with --yes"
( cd "$src" && { shasum -a 256 -c SHA256SUMS 2>/dev/null || sha256sum -c SHA256SUMS; } ) >/dev/null || die "checksum mismatch in $src"
# config.tgz (.env + secrets/) is never extracted automatically: .env is sourced as
# shell, so an unchecked archive would run its code. On a fresh host, inspect it and
# extract by hand first:  tar -tzf <dir>/config.tgz; tar -C . -xzf <dir>/config.tgz;
# then review secrets/.env.backup and move it to .env
[ -f "$ENV_FILE" ] && [ -s "$SECRETS/postgres_password" ] || die "restore needs .env and secrets/ in place (see config.tgz in the backup)"
load_env
compose --profile concierge --profile calls stop
compose up -d postgres; wait_healthy postgres 120
for db in hagency palpo pasion; do
  log "restoring $db"
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U hagency -d postgres \
    -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" -c "CREATE DATABASE $db OWNER hagency;"
  compose exec -T postgres pg_restore -U hagency -d "$db" --no-owner --exit-on-error < "$src/$db.dump"
done
log "restoring server data volume"
compose run --rm --no-deps -T --entrypoint sh server -c 'find /app/data -mindepth 1 -delete && tar -C /app/data -xzf -' < "$src/server-data.tgz"
mkdir -p "$RUNTIME"; touch "$RUNTIME/.bootstrapped"
log "restore done; start with ./deploy.sh"
