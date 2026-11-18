#!/usr/bin/env bash
# Staging -> production gate, run ON THE PRODUCTION HOST after the tag passed
# staging (deploy.sh staging + the e2e scenario run). Records who signed off;
# deploy.sh production refuses tags without this record (ALLOW_UNSTAGED=1 overrides).
#   ./promote.sh <tag>
# The image must be the exact one staging ran: load the same archive, or pull
# the same tag from the registry. Nothing is rebuilt for production.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"
tag="${1:-}"; valid_tag "$tag" || { sed -n '2,7p' "$0"; exit 2; }
[ -t 0 ] || die "promotion is a human decision: run it from a terminal"
staging_url="${STAGING_URL:-https://matrix.staging.hagencylabs.xyz}"
if curl -fsS --max-time 10 "$staging_url/_matrix/client/versions" | grep -q '"versions"'; then
  echo "staging answers at $staging_url"
else echo "warning: staging does not answer at $staging_url" >&2; fi
printf 'Has %s passed on staging (deploy checks + e2e scenarios + a manual sign-in)? Type the tag to confirm: ' "$tag" >&2
read -r answer; [ "$answer" = "$tag" ] || die "not confirmed"
umask 077; mkdir -p "$BUNDLE/state/promoted"
printf 'tag=%s\nby=%s\nat=%s\n' "$tag" "${SUDO_USER:-$(id -un)}" "$(date -u +%FT%TZ)" > "$BUNDLE/state/promoted/$tag"
echo "promoted $tag. Next: ./deploy.sh production --tag $tag [--image-archive <the archive staging used>]"
