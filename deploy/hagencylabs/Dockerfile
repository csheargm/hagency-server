# syntax=docker/dockerfile:1.7
# hagencylabs.xyz images (staging and production use the SAME image; promotion
# never rebuilds). Build context: the hagency-server repository root.
#   ./build-image.sh            (wraps the commands below and tags by git commit)
#   docker buildx build --platform linux/amd64 -f deploy/hagencylabs/Dockerfile --target server .
#   docker buildx build --platform linux/amd64 -f deploy/hagencylabs/Dockerfile --target caddy .
#
# target server: ONE process. Palpo (homeserver) and Pasion (accounts, served at
# /auth/) are Rust libraries linked into hagency-server, together with the agent
# service. There is deliberately no separate Palpo or Pasion container.
#
# Palpo and Pasion come from Cargo.toml [patch] path dependencies under .run/
# (gitignored on the Mac). This file recreates exactly those paths from pinned
# commits, so the build needs only this repository plus GitHub, never the Mac's
# .run/ directory. Change a pin = change the ARG default here, in a commit.
ARG PALPO_REPO=https://github.com/csheargm/palpo.git
# fix/fed-visibility-missing-prev, the Palpo copy the Mac demo servers run (2026-11-18).
ARG PALPO_REV=7abc2a9c811f9a112d404d2e497e7c76050e8f45
ARG PASION_REPO=https://github.com/csheargm/pasion.git
# feat/native-auth-api (native desktop sign-in, lowercase usernames). Must be
# pushed to PASION_REPO before the first build (see RUNBOOK "Blockers").
ARG PASION_REV=f17b38138d6ac1914a9f269e6d71fb8d80955323
ARG BUILD_JOBS=4

FROM rust:1.99.0-bookworm@sha256:114c7a4425406451c2866b6aafe69fe29b1b298832db1277d411ac73c82d04d6 AS sources
ARG PALPO_REPO
ARG PALPO_REV
ARG PASION_REPO
ARG PASION_REV
WORKDIR /src/hagency-server
COPY rust-toolchain.toml Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY xtask ./xtask
COPY scripts/docker-entrypoint.sh ./scripts/docker-entrypoint.sh
# Fetch by exact commit (GitHub serves reachable SHAs); a moved branch cannot change the build.
RUN set -eu; fetch() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" remote add origin "$2"; \
      git -C "$1" fetch -q --depth 1 origin "$3"; git -C "$1" checkout -q --detach FETCH_HEAD; \
      test "$(git -C "$1" rev-parse HEAD)" = "$3"; rm -rf "$1/.git"; }; \
    fetch .run/palpo-8c1759f "$PALPO_REPO" "$PALPO_REV"; \
    fetch .run/pasion-native-auth "$PASION_REPO" "$PASION_REV"; \
    printf 'palpo %s %s\npasion %s %s\n' "$PALPO_REPO" "$PALPO_REV" "$PASION_REPO" "$PASION_REV" > /src/SOURCES

FROM sources AS server-build
ARG BUILD_JOBS
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev cmake clang \
    && rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,id=hl-srv-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=hl-srv-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=hl-srv-target-${TARGETARCH},target=/src/hagency-server/target \
    cargo build --release --locked --jobs ${BUILD_JOBS} -p hagency-server --bin hagency-server \
    && install -D target/release/hagency-server /out/hagency-server

# Web assets (Dioxus WASM): architecture-independent, built from the same pinned
# sources. xtask downloads dx 0.7.5 and checks its SHA-256 itself.
FROM sources AS web-assets
ARG BUILD_JOBS
ENV CARGO_BUILD_JOBS=${BUILD_JOBS}
RUN --mount=type=cache,id=hl-web-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=hl-web-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=hl-web-xtask,target=/src/hagency-server/target \
    cargo run --quiet --locked --manifest-path xtask/Cargo.toml -- prepare-frontend --output /out/frontend \
    && cargo run --quiet --locked --manifest-path xtask/Cargo.toml -- prepare-pasion \
       --source .run/pasion-native-auth --output /out/pasion

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS server
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 ca-certificates gosu curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home hagency && mkdir -p /app/data && chmod 700 /app/data \
    && chown hagency:hagency /app/data
WORKDIR /app
ARG HAGENCY_COMMIT=unspecified
LABEL org.opencontainers.image.source="https://github.com/csheargm/hagency-server" \
      org.opencontainers.image.revision="$HAGENCY_COMMIT"
COPY --from=server-build /out/hagency-server /usr/local/bin/hagency-server
COPY --from=web-assets /out/pasion /app/resources/pasion
COPY --from=web-assets /out/frontend /app/resources/frontend/public
COPY --from=sources /src/SOURCES /app/SOURCES
COPY --from=sources /src/hagency-server/scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
EXPOSE 8088
# readyz includes the agent service's appservice round trip, not just the listener.
HEALTHCHECK --interval=10s --timeout=3s --start-period=180s --retries=6 \
    CMD curl --fail --silent --max-time 2 http://127.0.0.1:8088/readyz || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--config", "/app/config/hagency.toml"]

# Caddy with the per-IP rate-limit module (stock Caddy has none). Module pinned to a commit.
FROM caddy:2.10.2-builder-alpine@sha256:4cff3ae272ea05842adb4546e35961e4947aeea65f80fa1eb62a35b960e84971 AS caddy-build
RUN xcaddy build v2.10.2 --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db --output /out/caddy
FROM caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d AS caddy
COPY --from=caddy-build /out/caddy /usr/bin/caddy
