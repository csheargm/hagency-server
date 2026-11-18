#!/usr/bin/env bash
# Offline validation of the bundle (no host, no network beyond Docker images):
# shell syntax + shellcheck, gen-secrets never prints a secret, templates render
# for both environments with no placeholder left, TOML/JSON parse, environment
# guards refuse cross-environment mistakes, compose config resolves, and (with
# VALIDATE_CADDY_IMAGE set) the rendered Caddyfile passes `caddy validate`.
#   test/validate.sh            VALIDATE_CADDY_IMAGE=hagencylabs/caddy:<tag> test/validate.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Same layout as the repo: <tmp>/hagencylabs plus the shared ../databases.sql.
WORK="$TMP/hagencylabs"; mkdir "$WORK"
cp -R "$SRC/." "$WORK/"; rm -rf "$WORK/env" "$WORK/secrets" "$WORK/runtime" "$WORK/state" "$WORK/backups" "$WORK/dist"
cp "$SRC/../databases.sql" "$TMP/databases.sql"
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

scripts=("$WORK"/*.sh "$WORK"/scripts/*.sh "$WORK"/test/*.sh)
for f in "${scripts[@]}"; do check "bash -n $(basename "$f")" bash -n "$f"; done
if command -v shellcheck >/dev/null; then
  check "shellcheck" shellcheck -x -P "$WORK" -P "$WORK/scripts" "${scripts[@]}"
elif docker image inspect koalaman/shellcheck:v0.10.0 >/dev/null 2>&1 || docker pull -q koalaman/shellcheck:v0.10.0 >/dev/null 2>&1; then
  if out="$(cd "$WORK" && docker run --rm -v "$WORK:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 -x -P /mnt -P /mnt/scripts ./*.sh scripts/*.sh test/*.sh 2>&1)"; then
    ok "shellcheck (docker)"; else bad "shellcheck (docker)"; printf '%s\n' "$out" | head -60; fi
else echo "SKIP shellcheck (not installed, no Docker image)"; fi

# Environment files for both environments, staging values from the comments.
mkdir -p "$WORK/env"; umask 077
cp "$WORK/.env.example" "$WORK/env/production.env"
sed -E -e 's/^DEPLOY_ENV=production/DEPLOY_ENV=staging/' -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=hagencylabs-staging/' \
  -e 's/^SERVER_NAME=.*/SERVER_NAME=staging.hagencylabs.xyz/' -e 's/^DOMAIN=.*/DOMAIN=matrix.staging.hagencylabs.xyz/' \
  -e 's/^ELEMENT_DOMAIN=.*/ELEMENT_DOMAIN=app.staging.hagencylabs.xyz/' -e 's/^FEDERATION_ALLOWLIST=.*/FEDERATION_ALLOWLIST=hagencylabs.xyz/' \
  -e 's/^REGISTRATION_MODE=.*/REGISTRATION_MODE=open/' "$WORK/.env.example" > "$WORK/env/staging.env"

for env in staging production; do
  out="$("$WORK/gen-secrets.sh" "$env")"
  sec="$WORK/secrets/$env.env"
  leaked=0
  for key in POSTGRES_PASSWORD ADMIN_PASSWORD; do
    val="$(sed -n "s/^$key=//p" "$sec")"; [ -n "$val" ] && [[ "$out" != *"$val"* ]] || leaked=1
  done
  if [ "$leaked" = 0 ]; then ok "$env gen-secrets prints no secret"; else bad "$env gen-secrets prints no secret"; fi
  check "$env secrets file is 0600" test "$(stat -c %a "$sec" 2>/dev/null || stat -f %Lp "$sec")" = 600
  before="$(cat "$sec")"; "$WORK/gen-secrets.sh" "$env" >/dev/null
  check "$env gen-secrets re-run keeps values" test "$before" = "$(cat "$sec")"
  # Exercise the optional blocks too: GitHub sign-in and Resend email on.
  sed -i.bak -e 's/^GITHUB_CLIENT_SECRET=$/GITHUB_CLIENT_SECRET=test-not-a-secret/' -e 's/^RESEND_API_KEY=$/RESEND_API_KEY=re_test/' "$sec"; rm -f "$sec.bak"
  sed -i.bak 's/^GITHUB_CLIENT_ID=$/GITHUB_CLIENT_ID=Iv1.testclient/' "$WORK/env/$env.env"; rm -f "$WORK/env/$env.env.bak"
done

render_env() { # env -> renders into $WORK/rendered-<env>
  ( set -euo pipefail; . "$WORK/scripts/lib.sh"; load_env "$1"; validate_env; use_release testtag
    render_runtime "$WORK/rendered-$1" )
}
for env in staging production; do
  if render_env "$env"; then ok "$env renders"; else bad "$env renders"; continue; fi
  d="$WORK/rendered-$env"
  check "$env hagency.toml has public_origin" grep -q '^public_origin = "https://matrix\.' "$d/config/hagency.toml"
  check "$env no placeholder left" bash -c "! grep -rq '\\\${[A-Z0-9_]*}' '$d/config' '$d/Caddyfile' '$d/element-config.json'"
  for t in hagency palpo pasion; do
    check "$env $t.toml parses" python3 -I -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$d/config/$t.toml"
  done
  check "$env element config is JSON" python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$d/element-config.json"
  check "$env palpo server_name" grep -q "^server_name = \"$( [ "$env" = production ] && echo hagencylabs.xyz || echo staging.hagencylabs.xyz )\"" "$d/config/palpo.toml"
  check "$env federation allowlist" grep -q '^allowed_servers = \["' "$d/config/palpo.toml"
  check "$env GitHub provider rendered" grep -q 'client_secret_file = "/run/hagency/config/github-client.secret"' "$d/config/pasion.toml"
  check "$env Resend email rendered" grep -q 'type = "resend"' "$d/config/pasion.toml"
  check "$env snapshot dir is private" test "$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d")" = 700
done

# Guards: a production env file cannot carry a staging server_name and vice versa.
guard() { ( . "$WORK/scripts/lib.sh"; load_env "$1"; validate_env ) >/dev/null 2>&1; }
cp "$WORK/env/staging.env" "$WORK/env/staging.env.orig"
sed -i.bak 's/^SERVER_NAME=.*/SERVER_NAME=hagencylabs.xyz/' "$WORK/env/staging.env"
check "staging refuses production server_name" bash -c "! ( . '$WORK/scripts/lib.sh'; load_env staging; validate_env )"
mv "$WORK/env/staging.env.orig" "$WORK/env/staging.env"
check "DEPLOY_ENV must match argument" bash -c "! ENV_FILE='$WORK/env/staging.env' bash -c '. \"$WORK/scripts/lib.sh\"; load_env production'"
if guard staging; then ok "staging env valid"; else bad "staging env valid"; fi

# docker compose config with the variables deploy.sh exports.
for env in staging production; do
  if ( . "$WORK/scripts/lib.sh"; load_env "$env"; use_release testtag; RELEASE_DIR="$WORK/rendered-$env"; export RELEASE_DIR
       compose --profile calls config -q ); then ok "$env compose config"; else bad "$env compose config"; fi
done

# Secrets must not reach child processes or compose inputs.
for env in staging production; do
  check "$env secrets not exported to children" bash -c ". '$WORK/scripts/lib.sh'; load_env $env; ! env | grep -q '^POSTGRES_PASSWORD='"
  pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$WORK/secrets/$env.env")"
  check "$env compose.env holds no secret" bash -c "! grep -qF '$pw' '$WORK/rendered-$env/compose.env' '$WORK/rendered-$env/docker-compose.yml' '$WORK/rendered-$env/profiles'"
  check "$env snapshot never overwritten" bash -c "! ( . '$WORK/scripts/lib.sh'; load_env $env; use_release testtag; render_runtime '$WORK/rendered-$env' )"
done

if [ -n "${VALIDATE_CADDY_IMAGE:-}" ]; then
  for env in staging production; do
    if docker run --rm -v "$WORK/rendered-$env/Caddyfile:/etc/caddy/Caddyfile:ro" "$VALIDATE_CADDY_IMAGE" \
         caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$WORK/caddy-$env.log" 2>&1; then
      ok "$env caddy validate"; else bad "$env caddy validate"; tail -5 "$WORK/caddy-$env.log"; fi
  done
else echo "SKIP caddy validate (set VALIDATE_CADDY_IMAGE)"; fi

if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
