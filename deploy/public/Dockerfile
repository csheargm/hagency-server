# syntax=docker/dockerfile:1.7
# Public Hagency server bundle images. Build context: the hagency workspace root
# (the directory holding hagency-server/ and hagency-client/); deploy.sh finds it.
#   target server    : hagency-server with Palpo (homeserver) and Pasion (accounts,
#                      served at /auth/) linked in as libraries -> ONE process.
#                      There is deliberately no separate Palpo image or service.
#   target concierge : the `hagency` CLI running `agent concierge`, plus the Codex
#                      and Claude Code CLIs it drives with API keys from env.
# Multi-arch: docker buildx build --platform linux/amd64,linux/arm64 ...
# Base images are pinned by tag AND digest (multi-arch index digests).
ARG BUILD_JOBS=4

FROM rust:1.99.0-bookworm@sha256:114c7a4425406451c2866b6aafe69fe29b1b298832db1277d411ac73c82d04d6 AS server-build
ARG BUILD_JOBS
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev cmake clang \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/hagency-server
COPY hagency-server/rust-toolchain.toml hagency-server/Cargo.toml hagency-server/Cargo.lock ./
COPY hagency-server/crates ./crates
COPY hagency-server/xtask ./xtask
COPY hagency-server/.run/palpo-8c1759f ./.run/palpo-8c1759f
RUN --mount=type=cache,id=hl-srv-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=hl-srv-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=hl-srv-target-${TARGETARCH},target=/src/hagency-server/target \
    cargo build --release --locked --jobs ${BUILD_JOBS} -p hagency-server --bin hagency-server \
    && install -D target/release/hagency-server /out/hagency-server

FROM rust:1.98.0-bookworm@sha256:82150a52ec202c1b14d7817e14516c392bb7f5cfebd88f1ed531cb37ebd39922 AS cli-build
ARG BUILD_JOBS
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends cmake clang pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/hagency-client
COPY hagency-client/rust-toolchain.toml hagency-client/Cargo.toml hagency-client/Cargo.lock ./
COPY hagency-client/native ./native
COPY hagency-client/docs ./docs
RUN --mount=type=cache,id=hl-cli-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=hl-cli-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=hl-cli-target-${TARGETARCH},target=/src/hagency-client/target \
    cargo build --release --locked --jobs ${BUILD_JOBS} -p hagency \
    && install -D target/release/hagency /out/hagency

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS server
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 ca-certificates gosu curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home hagency && mkdir -p /app/data && chmod 700 /app/data \
    && chown hagency:hagency /app/data
WORKDIR /app
COPY --from=server-build /out/hagency-server /usr/local/bin/hagency-server
# Frontend (Dioxus WASM) and Pasion web assets are architecture-independent and
# taken prebuilt (xtask prepare-frontend / prepare-pasion); see README.
COPY hagency-server/resources/pasion /app/resources/pasion
COPY hagency-server/resources/frontend/public /app/resources/frontend/public
COPY hagency-server/scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
EXPOSE 8088
HEALTHCHECK --interval=10s --timeout=3s --start-period=120s --retries=6 \
    CMD curl --fail --silent --max-time 2 http://127.0.0.1:8088/readyz || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--config", "/app/config/hagency.toml"]

FROM node:22.21.1-bookworm-slim@sha256:25b3eb23a00590b7499f2a2ce939322727fcce1b15fdd69754fcd09536a3ae2c AS concierge
ARG CODEX_VERSION=0.169.0
ARG CLAUDE_CODE_VERSION=2.1.322
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g --omit=dev "@openai/codex@${CODEX_VERSION}" "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force \
    && useradd --uid 10002 --create-home agent
COPY --from=cli-build /out/hagency /usr/local/bin/hagency
COPY deploy/public/concierge-entrypoint.sh /usr/local/bin/concierge-entrypoint.sh
USER agent
WORKDIR /home/agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/concierge-entrypoint.sh"]

# Caddy with the per-IP rate-limit module (stock Caddy has none). Module pinned to a commit.
FROM caddy:2.10.2-builder-alpine@sha256:4cff3ae272ea05842adb4546e35961e4947aeea65f80fa1eb62a35b960e84971 AS caddy-build
RUN xcaddy build v2.10.2 --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db --output /out/caddy
FROM caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d AS caddy
COPY --from=caddy-build /out/caddy /usr/bin/caddy
