# hagencylabs.xyz runbook (phase 2: formal service)

Status 2026-11-18: **prepared, not executed.** Nothing here has touched alpha, beta or
AWS. The server image has not been built yet (see "Blockers"). What was validated
locally is listed at the end.

## 1. What runs where

| Host | Role | Size | Names (A records) |
|---|---|---|---|
| alpha `3.208.213.20` | **production** | 4 CPU / 15 GB / 48 GB, Ubuntu 26.04 x86_64 | `hagencylabs.xyz`, `matrix.hagencylabs.xyz`, `app.hagencylabs.xyz` (all exist) |
| beta `44.216.75.205` | **staging** | 2 CPU / 7.6 GB / 48 GB, Ubuntu 26.04 x86_64 | `staging.`, `matrix.staging.`, `app.staging.hagencylabs.xyz` (**missing**, owner adds) |

One `docker compose` project per host (`hagencylabs-production` / `hagencylabs-staging`):

| Service | What | Exposed |
|---|---|---|
| `caddy` | Let's Encrypt TLS, `.well-known/matrix/*` delegation, per-IP rate limits, routing | 80/tcp, 443/tcp, 443/udp |
| `server` | hagency-server: Palpo homeserver + agent service + Pasion accounts (`/auth/`) in **one process** | via Caddy only |
| `postgres` | Postgres 18, databases `hagency`, `palpo`, `pasion`, named volume `pgdata` | internal network only |
| `element` | Element Web, the browser client | via Caddy (`app.`) |
| `livekit-jwt` | optional (`CALLS_ENABLED=true`), Element Call tokens for LiveKit Cloud | via Caddy `/livekit/jwt/` |

Routing: `hagencylabs.xyz` is the Matrix server name (user IDs `@anna:hagencylabs.xyz`); it
serves only `/.well-known/matrix/server` → `{"m.server":"matrix.hagencylabs.xyz:443"}` and
`/.well-known/matrix/client`, and redirects everything else to `app.`. `matrix.` carries
client API, federation API (delegated to 443, **no port 8448**), `/auth` and `/hagency`.

Not deployed in this phase: the concierge / server-hosted agents (needs Ollama on a GPU
host; `deploy/public` on the unpushed `feat/public-deploy` branch has a draft). Users' agents
run in the Hagency desktop on their own Macs and connect to `https://matrix.hagencylabs.xyz`.

Files: `Dockerfile` (images), `docker-compose.yml`, `config/*.example` (templates; every
secret is a `${PLACEHOLDER}`), `.env.example`, `gen-secrets.sh`, `build-image.sh`,
`deploy.sh`, `promote.sh`, `rollback.sh`, `backup.sh`, `check.sh`, `test/validate.sh`.
On a host: `env/<env>.env` (settings, 0600), `secrets/<env>.env` (0600),
`runtime/<env>/<UTC>-<tag>/` (rendered config per release), `state/<env>/` (current,
previous, last backup), `/var/backups/hagencylabs/<env>/`.

## 2. Blockers before the first build

1. **Pasion commit not on GitHub.** The server links Pasion `feat/native-auth-api` at
   `f17b381` (local worktree `wt-native-auth-api`); no branch on `csheargm/pasion` contains it.
   Fix: `git -C ~/claudeworkfolder/hagency/wt-native-auth-api push fork feat/native-auth-api`.
   Palpo `7abc2a9c` is already on `csheargm/palpo` `fix/fed-visibility-missing-prev`.
2. **Pasion rate limits behind a proxy.** `crates/backend/src/pasion.rs` hard-codes
   `trusted_proxies: []`, so Pasion sees every request as coming from Caddy. The template
   raises Pasion's limits to global ceilings and relies on Caddy's real per-IP caps. A
   small server change (configurable `trusted_proxies`) should land before open sign-up.
3. **Staging DNS** (owner): three A records → `44.216.75.205` (section 3).

## 3. What the owner (Chris) does

| # | Action | Detail |
|---|---|---|
| 1 | SSH access for Claude | Security groups of alpha and beta: inbound 22/tcp from the Mac's current public IP (`curl -s https://ifconfig.me` on the Mac). Then say go; the key is `~/.ssh/hagency-keys.pem`. |
| 2 | Web ports | Same security groups: inbound 80/tcp, 443/tcp, 443/udp from `0.0.0.0/0` (and `::/0` if IPv6). Nothing else. 8448 stays closed. |
| 3 | Staging DNS | A `staging`, `matrix.staging`, `app.staging` → `44.216.75.205`, DNS only (no proxy). Optional CAA `0 issue "letsencrypt.org"` on the root. |
| 4 | GitHub OAuth apps (2) | github.com → Settings → Developer settings → OAuth Apps → New, once for production, once for staging. Homepage `https://app.hagencylabs.xyz`. Callback URL = the line `./gen-secrets.sh <env>` prints, `https://matrix.hagencylabs.xyz/auth/upstream/callback/<ULID>`. Put the client ID in `env/<env>.env` (`GITHUB_CLIENT_ID`) and the generated secret in `secrets/<env>.env` (`GITHUB_CLIENT_SECRET`) on the host yourself, or hand it over by a channel you trust. |
| 5 | ImprovMX (inbound mail) | Add `hagencylabs.xyz`; forward `ops@` and `support@` to your inbox. DNS: MX `mx1.improvmx.com` (10), `mx2.improvmx.com` (20); TXT on root `v=spf1 include:spf.improvmx.com ~all`. `ops@` receives Let's Encrypt notices (`ACME_EMAIL`). |
| 6 | Resend (outbound mail) | Add domain `hagencylabs.xyz`, add the DKIM / SPF / MX records Resend shows (they sit on `resend._domainkey` and `send.`, so they do not clash with ImprovMX). Create an API key limited to sending from that domain; put it in `secrets/<env>.env` as `RESEND_API_KEY`. Empty = no email, no password recovery. |
| 7 | Decisions | (a) password sign-up on production: `invite` (default here) / `open` / `closed`; GitHub sign-in is open in every mode. (b) federation: allowlist (default: only staging↔production) or open. (c) image registry: none (archives, default) or GHCR `ghcr.io/csheargm/hagency-server` (needs a token on the hosts). (d) off-host backup target: an S3 bucket in the AWS account, or an `age` key pair you keep. (e) external uptime monitor (e.g. UptimeRobot on `https://matrix.hagencylabs.xyz/_matrix/client/versions`). |

## 4. First-time host setup (each host, once)

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install -y ca-certificates curl git perl python3 util-linux age unattended-upgrades
# Docker: the official repo may not publish packages for 26.04 yet. Try it first:
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sudo sh /tmp/get-docker.sh \
  || sudo apt-get install -y docker.io docker-compose-v2 docker-buildx   # Ubuntu's own packages
sudo usermod -aG docker ubuntu && newgrp docker
docker compose version   # needs v2.20+
sudo timedatectl set-ntp true
# beta only (2 CPU / 7.6 GB), if images are built there: 8 GB swap
sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile \
  && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
# Code: this repository at the release branch
sudo mkdir -p /opt/hagencylabs /var/backups/hagencylabs && sudo chown ubuntu: /opt/hagencylabs /var/backups/hagencylabs
chmod 700 /var/backups/hagencylabs
git clone -b deploy/hagencylabs https://github.com/csheargm/hagency-server.git /opt/hagencylabs
cd /opt/hagencylabs/deploy/hagencylabs
ENV=production   # staging on beta
mkdir -p env && cp .env.example env/$ENV.env && chmod 600 env/$ENV.env
$EDITOR env/$ENV.env        # staging: apply every "# staging:" value
./gen-secrets.sh $ENV       # prints the file path and the GitHub callback URL, no secrets
```

Firewall: the AWS security group is the firewall. Do not rely on `ufw` for container ports:
Docker publishes ports through its own iptables rules, ahead of ufw.

DNS check before the first deploy (from anywhere):
`dig +short A hagencylabs.xyz matrix.hagencylabs.xyz app.hagencylabs.xyz` → `3.208.213.20` each
(verified 2026-11-18); staging names → `44.216.75.205` (missing today).

## 5. Build and ship an image

Images are tagged by the hagency-server commit (12 hex chars); production runs the exact
bytes staging ran. The build needs only this repository and GitHub (Palpo and Pasion are
fetched at the pinned commits named in the Dockerfile; Mac `.run/` links are not used).

```bash
# Option A (default): on beta, the staging host
cd /opt/hagencylabs && git pull && cd deploy/hagencylabs
BUILD_JOBS=2 MIN_FREE_GB=25 ./build-image.sh --save     # 1-2 h cold on 2 CPU; prints "tag: <tag>"
# Option B: on the Mac (Docker Desktop with Rosetta for amd64), needs >= 40 GB free
./build-image.sh --save && scp dist/hagencylabs-<tag>.tar.gz ubuntu@beta.hagency.xyz:/opt/hagencylabs/deploy/hagencylabs/dist/
```

Copy the same archive to alpha for promotion (from the Mac):
`scp ubuntu@beta.hagency.xyz:/opt/hagencylabs/deploy/hagencylabs/dist/hagencylabs-<tag>.tar.gz /tmp/ && scp /tmp/hagencylabs-<tag>.tar.gz ubuntu@alpha.hagency.xyz:/opt/hagencylabs/deploy/hagencylabs/dist/`
and compare the sha256 that `build-image.sh` printed.

## 6. Deploy to staging

```bash
cd /opt/hagencylabs/deploy/hagencylabs
./deploy.sh staging --tag <tag> --image-archive dist/hagencylabs-<tag>.tar.gz
```

What `deploy.sh` does, in order:
1. loads and validates `env/` + `secrets/` (refuses a staging file with the production server name and vice versa);
2. loads/pulls the two images and checks both exist;
3. renders a new config snapshot `runtime/staging/<UTC>-<tag>/`;
4. first start only: creates the administrator (`ADMIN_USER`, password in `secrets/`);
5. if a release is running: stops `server`, takes a **backup** (pg_dump of the three
   databases, the `server-data` volume with Palpo's signing key and Pasion's keys, env and
   secrets files, image tags) into `/var/backups/hagencylabs/staging/<UTC>-pre-<tag>/`;
6. `docker compose up -d --force-recreate` with the new image and config;
7. **health checks** through this host's Caddy with real TLS validation: server `readyz`,
   `/_matrix/client/versions`, both `.well-known` files, `/_matrix/federation/v1/version`,
   `/_matrix/key/v2/server` (server name), Pasion issuer, Element config, desktop native
   config; DNS → `HOST_PUBLIC_IP` and federation to each allowlisted peer are reported as
   warnings only;
8. on failure: **automatic rollback** to the previous image and its exact config snapshot;
   database restore according to `ROLLBACK_DB` (`ask` prompts on a terminal, `restore`
   always, `keep` never; the new release may already have migrated the schema).

Downtime: from step 5 to the end of step 7, a few minutes.

Staging sign-off (all on staging, before promotion):
- `./check.sh staging` all PASS; `FEDERATION_TESTER=1 ./check.sh staging` reports FederationOK.
- Hagency desktop: server `https://matrix.staging.hagencylabs.xyz`, sign up (lowercase
  username), GitHub sign-in, create an agent, one `@agent` reply, an approval card.
- Element Web at `https://app.staging.hagencylabs.xyz`: sign in through Pasion, join a room.
- Federation: a staging user and a production user in one room, both see each other's messages.
- The e2e scenario runner pointed at staging (needs a staging profile in `e2e/`; not written yet).

## 7. Promote to production

On alpha, with the same archive:
```bash
cd /opt/hagencylabs/deploy/hagencylabs
./promote.sh <tag>                     # human gate: records who signed off, refuses without a terminal
./deploy.sh production --tag <tag> --image-archive dist/hagencylabs-<tag>.tar.gz   # asks you to type hagencylabs.xyz
```
`deploy.sh production` refuses a tag without the promotion record (`ALLOW_UNSTAGED=1`
overrides, for emergencies only). Phase 3 replaces the manual copy with CI building once
and a room-side approval writing the promotion record.

## 8. Rollback

- Automatic: see step 8 above.
- Manual, image + config only (databases kept): `./rollback.sh production`
- Manual with data: `./rollback.sh production --restore-db` (last pre-deploy backup) or
  `--restore-db /var/backups/hagencylabs/production/<dir>`. Loses everything written after
  that backup. Restores refuse a backup from the other environment.
- `./rollback.sh production --list` shows releases and backups on the host.
- Both releases fail: `./deploy.sh production logs server`, then restore the newest
  `nightly` or `pre-*` backup with the release named in its `meta.txt`.

## 9. Backups

| What | When | Where |
|---|---|---|
| Pre-deploy (server stopped, consistent across all three DBs) | every deploy | `/var/backups/hagencylabs/<env>/<UTC>-pre-<tag>/` |
| Nightly (server running, consistent per database) | cron `17 3 * * *` `./backup.sh production` | `.../<UTC>-nightly/` |
| Off-host | set `BACKUP_AGE_RECIPIENT`; each backup also writes `offsite/<name>.tar.age`; ship with `aws s3 cp` or `rsync` | owner's choice (3d) |
| Docker volumes / EBS | weekly EBS snapshot of each host's root volume (AWS Data Lifecycle Manager) | AWS (owner) |

`BACKUP_KEEP=14` local copies. A backup contains the Matrix signing key and all secrets:
keep it private and encrypted off-host. Losing the signing key loses the server's
federation identity. Restore drill once per month on staging from a **staging** backup
(production backups must never be restored on another host that federates: two servers
would hold one identity).

## 10. Monitoring

- `*/5 * * * * /opt/hagencylabs/deploy/hagencylabs/check.sh production --alert` posts
  failures (checks, unhealthy/restarting containers, disk over 85 %) to `ALERT_WEBHOOK_URL`
  (e.g. a Slack or Matrix webhook, kept in `secrets/`).
- External uptime monitor on `/_matrix/client/versions` (owner, 3e).
- Logs: `./deploy.sh production logs [service]`; json-file, 5 x 20 MB per container.
  `SERVER_RUST_LOG=info` in `env/` for more detail (then redeploy the same tag).
- Certificates: Caddy renews by itself; Let's Encrypt mails `ACME_EMAIL` before expiry.
- Media has no per-user quota: watch disk (alert above) and Caddy's upload caps.

## 11. Client distribution

| Client | How | Status |
|---|---|---|
| Browser | Element Web at `https://app.hagencylabs.xyz` (in this stack) | ready with the stack; Pasion sign-in from Element must be verified on staging |
| Hagency desktop (Mac) | `Hagency.app` DMG on a GitHub Release of `csheargm/hagency`, unsigned (release-bundle-plan, ADR 0013), built LAST after phase 1 is bug-free; `release/build-macos-bundle.sh` | not published. Open: should the release build offer `matrix.hagencylabs.xyz` as its default server instead of the built-in one? |
| Hagency desktop (Linux / Windows) | none yet | unknown |
| `hagency` CLI (agent host, scripts) | `deploy/linux/Dockerfile --target cli` builds it on Linux | not packaged for download |

## 12. Known gaps and open questions

- Pasion `trusted_proxies` (blocker 2). Pasion is also slated for removal (productization
  direction); this stack keeps it because the deployed server still uses it.
- One Postgres superuser (`hagency`) owns all three databases; split roles later.
- `invite` mode: tokens are written straight into Pasion's table (`./deploy.sh production invite 5`);
  entering a token in the desktop sign-up is untested.
- The server image build has not run past the sources stage yet (blocker 1).
- No e2e scenario profile for staging yet; the sign-off list above is manual until then.
- `deploy/public` (branch `feat/public-deploy`, never pushed) and `deploy/linux` overlap this
  bundle; keep one: this one for hagencylabs, retire the other two after the first good deploy.
- The broader AWS design (`evaluation/production-plan.md`: ECS, RDS, S3 media) is the later
  target; this runbook is the two-VM step.

## 13. Validated locally (2026-11-18, Mac, no host)

- `test/validate.sh`: shell syntax and shellcheck v0.10.0 clean on every script; `gen-secrets.sh`
  prints no secret, writes 0600, keeps values on re-run; both environments render with no
  placeholder left; TOML and JSON parse; environment guards refuse cross-environment names;
  `docker compose config` resolves for both; `caddy validate` passes on both rendered
  Caddyfiles with the built Caddy image.
- `docker buildx build --check`: no warnings. Caddy image built (native arch).
- `--target sources`: Palpo `7abc2a9c` fetched by commit from `csheargm/palpo`; Pasion failed
  with `upload-pack: not our ref f17b381…`, which is blocker 1. The server image was
  therefore **not** built or run; nothing past the sources stage is proven yet.
- Health-check endpoints exercised against the running Mac demo server (alpha on 8090):
  `readyz`, client versions, federation version, key server, notary key query for the peer,
  Pasion issuer, native config.
