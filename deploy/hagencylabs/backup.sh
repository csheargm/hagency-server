#!/usr/bin/env bash
# Nightly backup while the service runs (cron). Per-database consistent; for a
# cross-database snapshot deploy.sh stops the server first.
#   ./backup.sh <env>
# Example cron (the ubuntu user's crontab, NOT root; 03:17 UTC):  17 3 * * * /opt/hagencylabs/deploy/hagencylabs/backup.sh production >> /var/log/hagencylabs-backup.log 2>&1
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"
# shellcheck source=scripts/ops.sh
. "$HERE/scripts/ops.sh"
# shellcheck source=scripts/release.sh
. "$HERE/scripts/release.sh"
[ $# -eq 1 ] || { sed -n '2,5p' "$0"; exit 2; }
load_env "$1"; validate_env
with_lock   # never races a deploy, rollback or restore
current="$(state_get current)"; [ -n "$current" ] || die "nothing deployed in $ENV_NAME yet"
use_record "$current"
dir="$(backup_now nightly)" || die "nightly backup failed"
log "backup written: $dir"
