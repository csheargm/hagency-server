#!/usr/bin/env bash
# Create secrets/<env>.env (mode 0600) for one environment. Prints NO secret
# values: only the file path, which keys still need a value from the owner, and
# the (public) GitHub OAuth callback URL. Re-running keeps every existing value
# and only adds keys that are missing, so it is safe after an upgrade.
#   ./gen-secrets.sh staging|production
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_NAME="${1:-}"
case "$ENV_NAME" in staging|production) ;; *) echo "usage: $0 staging|production" >&2; exit 2;; esac
OUT="$HERE/secrets/$ENV_NAME.env"

# pipefail off inside: head closing the pipe makes tr exit 141 (SIGPIPE).
random_alnum() { (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"); }
# Valid ULID (Crockford base32, first char 0-7). Not secret, but must stay stable
# per environment because the GitHub callback URL contains it.
random_ulid() {
  (set +o pipefail
   printf '%s%s' "$(LC_ALL=C tr -dc '0-7' </dev/urandom | head -c 1)" \
     "$(LC_ALL=C tr -dc '0123456789ABCDEFGHJKMNPQRSTVWXYZ' </dev/urandom | head -c 25)")
}

has_key() { [ -f "$OUT" ] && grep -q "^$1=" "$OUT"; }
add_key() { has_key "$1" || printf '%s=%s\n' "$1" "$2" >> "$OUT"; }

umask 077
mkdir -p "$HERE/secrets"; chmod 700 "$HERE/secrets"
[ ! -L "$OUT" ] || { echo "error: $OUT must not be a symlink" >&2; exit 1; }
[ -f "$OUT" ] || printf '# %s secrets for hagencylabs (generated %s). Mode 0600. Never commit.\n' \
  "$ENV_NAME" "$(date -u +%FT%TZ)" > "$OUT"
chmod 600 "$OUT"

add_key POSTGRES_PASSWORD "$(random_alnum 40)"
add_key ADMIN_PASSWORD "$(random_alnum 32)"
add_key GITHUB_PROVIDER_ID "$(random_ulid)"
# Owner-supplied values (left empty = feature off):
add_key GITHUB_CLIENT_SECRET ""
add_key RESEND_API_KEY ""
add_key LIVEKIT_SECRET ""
add_key ALERT_WEBHOOK_URL ""

echo "secrets file: $OUT (mode $(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT"))"
missing="$(grep -E '^[A-Z_]+=$' "$OUT" | cut -d= -f1 | tr '\n' ' ')"
[ -z "$missing" ] || echo "still empty (fill in by editing the file; empty = feature off): $missing"
provider="$(sed -n 's/^GITHUB_PROVIDER_ID=//p' "$OUT")"
domain=""
[ -f "$HERE/env/$ENV_NAME.env" ] && domain="$(sed -n 's/^DOMAIN=\([^ #]*\).*/\1/p' "$HERE/env/$ENV_NAME.env")"
echo "GitHub OAuth app callback URL: https://${domain:-<DOMAIN>}/auth/upstream/callback/$provider"
