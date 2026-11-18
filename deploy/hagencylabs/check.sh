#!/usr/bin/env bash
# Health check for monitoring (cron every 5 minutes). Exit 0 = healthy.
#   ./check.sh <env> [--alert]   --alert posts failures to ALERT_WEBHOOK_URL (secrets file)
# Example cron:  */5 * * * * /opt/hagencylabs/deploy/hagencylabs/check.sh production --alert >/dev/null 2>&1
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"
# shellcheck source=scripts/ops.sh
. "$HERE/scripts/ops.sh"
# shellcheck source=scripts/checks.sh
. "$HERE/scripts/checks.sh"
# shellcheck source=scripts/release.sh
. "$HERE/scripts/release.sh"
[ $# -ge 1 ] || { sed -n '2,4p' "$0"; exit 2; }
load_env "$1"; validate_env
use_record "$(state_get current)"
out="$(run_checks --with-host 2>&1)" && status=0 || status=$?
printf '%s\n' "$out"
if [ "$status" != 0 ] && [ "${2:-}" = --alert ] && [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  [[ "$ALERT_WEBHOOK_URL" =~ ^https://[^[:space:]\"]+$ ]] || die "ALERT_WEBHOOK_URL must be https://"
  cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT; chmod 600 "$cfg"
  printf 'url = "%s"\n' "$ALERT_WEBHOOK_URL" > "$cfg"   # the URL is a secret: keep it out of argv
  printf 'Hagency %s (%s) health check failed at %s\n%s\n' "$ENV_NAME" "$SERVER_NAME" "$(date -u +%FT%TZ)" \
    "$(printf '%s\n' "$out" | grep -E 'FAIL|WARN' | head -20)" \
    | python3 -I -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()[:3500]}))' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' --data-binary @- -K "$cfg" >/dev/null \
    || echo "alert webhook post failed" >&2
fi
exit "$status"
