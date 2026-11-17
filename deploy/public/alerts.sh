#!/usr/bin/env bash
# Log-based alerting hook. Cron it:  */5 * * * * cd /path/deploy/public && ./alerts.sh
# Scans the last ALERT_WINDOW (default 5m) of all service logs for ALERT_PATTERN, plus
# containers that are unhealthy/restarting, and POSTs a JSON summary to
# ALERT_WEBHOOK_URL (body on stdin, never in argv). Empty webhook: prints only.
source "$(dirname "$0")/lib.sh"
load_env
: "${ALERT_WINDOW:=5m}" "${ALERT_PATTERN:=panic|FATAL|ERROR|OOM|429}"
hits="$(compose --profile concierge --profile calls logs --no-color --since "$ALERT_WINDOW" 2>&1 \
  | grep -E -- "$ALERT_PATTERN" | grep -v '/readyz' | tail -n 20 || true)"
bad="$(docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
  --format '{{.Names}} {{.Status}}' | grep -E 'unhealthy|Restarting|Exited' || true)"
disk="$(df -P /var/lib/docker 2>/dev/null || df -P /)"; pct="$(printf '%s\n' "$disk" | awk 'NR==2 {gsub("%","",$5); print $5}')"
[ "${pct:-0}" -ge "${ALERT_DISK_PCT:-85}" ] && bad+="${bad:+
}disk ${pct}% used (media has no per-user quota)"
[ -z "$hits$bad" ] && exit 0
msg="Hagency $DOMAIN alert ($(date -u +%FT%TZ))
${bad:+Containers:
$bad
}${hits:+Log matches (last $ALERT_WINDOW):
$hits}"
if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  [[ "$ALERT_WEBHOOK_URL" =~ ^https://[^[:space:]\"]+$ ]] || die "ALERT_WEBHOOK_URL must be https://"
  cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT; chmod 600 "$cfg"
  printf 'url = "%s"\n' "$ALERT_WEBHOOK_URL" > "$cfg"   # URL may hold a secret: keep it out of argv
  python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()[:3500]}))' <<< "$msg" \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' --data-binary @- -K "$cfg" >/dev/null
fi
printf '%s\n' "$msg"
