# Hagency public server bundle

One command brings up a public Hagency server that anyone can reach from a browser:
people sign in through Element Web, and server-hosted agents (the concierge) run on an
Ollama model with daily token budgets.

| Service | What it is | Exposed |
|---|---|---|
| `caddy` | Automatic HTTPS (Let's Encrypt), `.well-known/matrix/*`, reverse proxy | 80, 443 (tcp+udp) |
| `server` | hagency-server: Palpo homeserver **and** Pasion accounts (hidden at `/auth/`) linked into one process; also `/_matrix`, `/hagency` REST and the web app | via Caddy only |
| `postgres` | Postgres 18, databases `hagency`, `palpo`, `pasion` | internal network only |
| `element` | Element Web, config rendered from `.env` | via Caddy (`ELEMENT_DOMAIN`) |
| `concierge` (profile) | `hagency agent concierge`; hosted Agents run Codex against **Ollama** (`OLLAMA_URL`, `OLLAMA_MODEL`), no commercial API key | outbound only |
| `livekit-jwt` (profile `calls`) | Element Call token service for LiveKit Cloud | via Caddy `/livekit/jwt/` |

There is no separate Palpo container: Palpo is a library inside hagency-server
(ADR option D keeps Pasion as the hidden account backend the same way).
Federation uses delegation to port 443 (`/.well-known/matrix/server`), so 8448 is not needed.

## Default layout (hagencylabs.xyz)

| Name | Serves |
|---|---|
| `hagencylabs.xyz` | Matrix server name (user IDs `@name:hagencylabs.xyz`) and the landing page. Must serve `/.well-known/matrix/server` → `{"m.server":"matrix.hagencylabs.xyz:443"}` and `/.well-known/matrix/client` → base_url `https://matrix.hagencylabs.xyz` |
| `matrix.hagencylabs.xyz` | hagency-server with Palpo + Pasion: `/_matrix`, `/auth`, `/hagency` (`DOMAIN`) |
| `app.hagencylabs.xyz` | Element Web (`ELEMENT_DOMAIN`) |

Root handling, two options (`ROOT_MODE` in `.env`):
- `caddy` (default): the root A record points at this box; Caddy serves the two `.well-known`
  files and redirects everything else to `app.`. Replace the redirect with a static site later if wanted.
- `external`: the landing page lives on Cloudflare Pages/Vercel. That host must serve the two
  `.well-known` JSON files above (`Content-Type: application/json`, client file with
  `Access-Control-Allow-Origin: *`); Caddy then serves only `matrix.` and `app.`.
  Check: `curl https://hagencylabs.xyz/.well-known/matrix/server`.

### DNS records

| Type | Name | Value | Note |
|---|---|---|---|
| A (+AAAA if IPv6) | `matrix` | server IP | DNS only (grey) recommended |
| A (+AAAA) | `app` | server IP | may be proxied |
| A (+AAAA) | `@` (root) | server IP | `ROOT_MODE=caddy`; for `external`, the Pages/Vercel record instead |
| CAA (optional) | `@` | `0 issue "letsencrypt.org"` | add the Pages/Vercel CA too if the root is external |

No SRV record and no port 8448: federation is delegated to `matrix.hagencylabs.xyz:443`.

## 10-minute path: Oracle Cloud Always Free (ARM)

1. **VM**: Compute → Create instance → Ampere A1 (4 OCPU / 24 GB is free), Ubuntu 24.04.
   Add your SSH key. Networking → the subnet's security list: allow ingress TCP 80, 443 and UDP 443.
   Ubuntu on OCI also has iptables rules: `sudo iptables -I INPUT 6 -p tcp -m multiport --dports 80,443 -j ACCEPT; sudo iptables -I INPUT 6 -p udp --dport 443 -j ACCEPT; sudo netfilter-persistent save`.
2. **DNS** (Cloudflare or any): the records in "DNS records" above.
   In Cloudflare use **DNS only (grey cloud)** at first so Let's Encrypt and federation reach Caddy directly.
3. **Docker**: `curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER` (log out and in).
4. **Code**: clone `hagency-server` and `hagency-client` side by side into one directory
   (the image build needs both), plus the pinned Palpo copy under `hagency-server/.run/palpo-8c1759f`
   and the prebuilt web assets in `hagency-server/resources/` (see "Build inputs").
5. **Configure**: `cd hagency-server/deploy/public && cp .env.example .env && chmod 600 .env`, then set
   `DOMAIN`, `ELEMENT_DOMAIN`, `SERVER_NAME`, `ACME_EMAIL`, `OLLAMA_URL`/`OLLAMA_MODEL`, optionally GitHub OAuth.
   Ollama on the same VM: install it, `ollama pull qwen2.5-coder:7b`, keep `OLLAMA_URL=http://host.docker.internal:11434`
   and make Ollama listen on the Docker bridge (`OLLAMA_HOST=0.0.0.0`, firewall 11434 from the internet).
6. **Deploy**: `./deploy.sh`. The first build compiles Rust (20-60 min on 4 ARM cores; set `BUILD_JOBS=4`).
   It prints the URLs. The admin password is in `secrets/admin_password`.
7. **Invite people**: `./deploy.sh invite 5` prints five one-time tokens (7 days).

## Generic VPS (amd64 or arm64)

Same steps 2-7 on any Linux host with Docker 24+ and >= 4 GB RAM (8 GB to build on the box).
To avoid building on a small box, build elsewhere with
`docker buildx build --platform linux/amd64,linux/arm64 -f deploy/public/Dockerfile --target server -t <registry>/hagency-server:<tag> --push <workspace>`
(same for `--target concierge`), set `IMAGE_MODE=pull` and the two image names in `.env`.

## Commands

| Command | Does |
|---|---|
| `./deploy.sh` | validate `.env`, generate missing secrets, build/pull, first-start bootstrap (admin + concierge account, with nothing published), start, wait for health, print URLs. Safe to re-run |
| `./deploy.sh invite [n]` | one-time sign-up tokens (invite mode) |
| `./deploy.sh kill-agents` / `resume-agents` | kill switch: stops the concierge and turns agent execution off in hagency-server |
| `./deploy.sh status` / `down` | compose ps / stop and remove containers (volumes kept) |
| `./backup.sh` | `pg_dump` of the 3 databases, server data volume (media, signing keys), `secrets/` and `.env` into `backups/<UTC time>/`, checksums, keeps `BACKUP_KEEP` |
| `./restore.sh <dir> --yes` | verify checksums, replace databases and server data, then `./deploy.sh` |
| `./alerts.sh` | log/health alert hook for cron, posts to `ALERT_WEBHOOK_URL` |
| `./upgrade.sh` | backup, tag current images `:previous`, rebuild/pull, redeploy |

Backups contain secrets and the Matrix signing key: copy them off the host encrypted
(e.g. `restic` to object storage) and keep the directory private. Losing the signing key
loses the server's federation identity.

## Cloudflare notes

- `matrix.`: keep **DNS only (grey)** if federation or long-poll `/sync` misbehaves (Cloudflare
  times out idle requests at 100 s and only proxies standard ports; 8448 is not used here).
  Proxied also works with WebSockets on and SSL **Full (strict)**.

- Start with the grey cloud (DNS only). Caddy gets certificates itself (HTTP-01 on port 80).
- If you turn the orange cloud (proxy) on: set SSL mode **Full (strict)**, keep WebSockets on,
  set `CADDY_TRUSTED_PROXIES` to Cloudflare's published IP ranges so client IPs (and so
  per-IP rate limits) are real, and check federation still works: other servers connect to
  `DOMAIN:443`, which Cloudflare proxies only on standard HTTPS ports.
- Never proxy the LiveKit host; calls use LiveKit Cloud in this bundle.

## Calls (optional)

Create a LiveKit Cloud project, set `CALLS_ENABLED=true`, `LIVEKIT_URL` (wss://...),
`LIVEKIT_KEY`, `LIVEKIT_SECRET`, and re-run `./deploy.sh`. This adds the `calls` profile
(lk-jwt-service) and advertises the focus in `.well-known/matrix/client`. No TURN server
runs here; LiveKit Cloud provides TURN.

## Security checklist before going public

- [ ] `REGISTRATION_MODE=invite` (default) or `closed`. `open` only with caps and someone watching.
      `approval` is refused by `deploy.sh` until the server implements it.
- [ ] `FEDERATION_ALLOWLIST` empty (federate with nobody) until you approve peers.
- [ ] Concierge caps: `CONCIERGE_MAX_AGENTS_PER_USER=1`, `CONCIERGE_DAILY_TOKENS` per Agent per UTC day
      (passed as the Agent's Policy budget). Hosted Agents use Ollama, so there is no API bill;
      Ollama itself must not be reachable from the internet. **Idle timeout: not supported by the
      concierge yet** (hosted Agents stay until the owner stops them or `kill-agents`).
- [ ] Kill switch tested: `./deploy.sh kill-agents`, then `resume-agents`.
- [ ] Caddy per-IP caps (`RL_*`, 429 when exceeded): `/auth` + Matrix login/register 10/min,
      `createRoom` 20/h, message send 60/min, media upload 60/h, everything 600/min.
      Upload size `MAX_UPLOAD_SIZE` (Caddy) = `MAX_UPLOAD_BYTES` (Palpo), default 20 MB.
- [ ] Palpo caps: `max_upload_size`, `max_concurrent_requests`, `rc_message` per user, login and
      registration limiters, DB pool size. Palpo has **no per-user media quota and no room-creation
      limit**; those are covered only by the per-IP Caddy caps above.
- [ ] Postgres: `max_connections=60`, `statement_timeout=60s`, idle-in-transaction timeout.
- [ ] Container caps: every service has `cpus`, `mem_limit`, `pids_limit` (`*_CPUS`, `*_MEM`).
- [ ] Alerts: cron `./alerts.sh` every 5 min with `ALERT_WEBHOOK_URL` (log pattern, unhealthy containers, disk >= `ALERT_DISK_PCT`).
      Media has no per-user quota: put `/var/lib/docker` on its own volume/filesystem and watch the disk alert.
- [ ] Rate limits: Pasion defaults stay on (3 logins/min, 3 sign-ups/hour per IP, strong passwords).
      They key on the client IP Caddy forwards; behind Cloudflare set `CADDY_TRUSTED_PROXIES`.
- [ ] `.env` and `secrets/` are mode 600/700 and not in git (`.gitignore`); API keys only in `.env`.
- [ ] Postgres is on an internal Docker network with no published port; only Caddy publishes ports.
- [ ] Backups: cron `./backup.sh` daily, copy off-host, do one `restore.sh` drill on a spare VM
      **with outbound network blocked** (the restore holds the live signing key).
- [ ] OS: unattended-upgrades on, SSH keys only, firewall allows only 22/80/443.
- [ ] GitHub OAuth callback URL is exactly `https://DOMAIN/auth/upstream/callback/01M7BKN7F5NRSNBNR7P3CEDYGR`.

## Build inputs

The server image is built from the workspace directory that holds `hagency-server/` and
`hagency-client/` (deploy.sh finds it by walking up, or set `HAGENCY_SRC`). It needs:
`hagency-server/.run/palpo-8c1759f` (Palpo copy referenced by `Cargo.toml [patch]`) and
prebuilt `hagency-server/resources/{pasion,frontend/public}` (`cargo xtask prepare-pasion`,
`prepare-frontend`). Base images are pinned by digest in `Dockerfile` and `docker-compose.yml`.

## Local test (nothing public)

`test/local-test.sh` copies the bundle to a temp dir and runs it as project `hagency-pubtest`
on `127.0.0.1:18080/18443` with `*.hagency.localhost` names and Caddy's internal CA, then
checks health, `/versions`, `.well-known`, Element, invite refusal, API sign-up, concierge,
kill switch and backup, and removes containers and volumes.

## Known gaps

- Google sign-in: placeholders only. Email recovery: none (admin reset).
- Invite tokens are created in Pasion's table; entering one in the web sign-up page is untested.
- The GitHub sign-in template keeps `localpart` as a suggestion (no `| lower`, no forced
  username screen); see `evaluation/adr-replace-pasion.md` item 4.
- Single host, single Postgres; no HA. See `evaluation/production-plan.md` for AWS.
- Open security follow-ups (from review, not yet fixed): the app uses the Postgres
  bootstrap superuser for all three databases (split into a non-superuser role); hosted
  agents share one container, uid, API keys and the `edge` network with the concierge
  (isolate per agent, broker credentials); Caddy forwards every path except `/_synapse`
  to the server (switch to an explicit public-route allowlist);  backups are checksummed, not signed or encrypted.
