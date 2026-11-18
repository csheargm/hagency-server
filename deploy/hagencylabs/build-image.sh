#!/usr/bin/env bash
# Build the server and Caddy images for one commit of this repository and tag
# both <repo>:<commit-12>. Staging and production then run that same tag.
#   ./build-image.sh [--save] [--push]
#     --save  write dist/hagencylabs-<tag>.tar.gz (both images) to copy to the hosts
#     --push  push both tags (SERVER_IMAGE_REPO/CADDY_IMAGE_REPO must be a registry you are logged in to)
# Env: PLATFORM (default linux/amd64: alpha and beta are x86_64), BUILD_JOBS (default 4),
#      SERVER_IMAGE_REPO / CADDY_IMAGE_REPO (default hagencylabs/server, hagencylabs/caddy),
#      MIN_FREE_GB (default 40; a cold build needs ~25 GB of BuildKit cache).
# First build: 30-90 min (Rust: Palpo + Pasion + hagency-server, plus two WASM front ends).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
: "${PLATFORM:=linux/amd64}" "${BUILD_JOBS:=4}" "${MIN_FREE_GB:=40}"
: "${SERVER_IMAGE_REPO:=hagencylabs/server}" "${CADDY_IMAGE_REPO:=hagencylabs/caddy}"
save=0; push=0
for a in "$@"; do case "$a" in --save) save=1;; --push) push=1;; *) sed -n '2,11p' "$0"; exit 2;; esac; done

# A tag must name exactly one source tree: refuse uncommitted changes.
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || { echo "error: $REPO has uncommitted changes; commit first (the tag is the commit)" >&2; exit 1; }
commit="$(git -C "$REPO" rev-parse HEAD)"; tag="${commit:0:12}"
free_gb="$(df -Pk "$REPO" | awk 'NR==2{print int($4/1048576)}')"
[ "$free_gb" -ge "$MIN_FREE_GB" ] || { echo "error: only ${free_gb} GB free (< MIN_FREE_GB=$MIN_FREE_GB)" >&2; exit 1; }

build() { # target image
  echo "building $2 ($PLATFORM, target $1)"
  docker buildx build --platform "$PLATFORM" -f "$HERE/Dockerfile" --target "$1" \
    --build-arg BUILD_JOBS="$BUILD_JOBS" --build-arg HAGENCY_COMMIT="$commit" -t "$2" --load "$REPO"
}
build server "$SERVER_IMAGE_REPO:$tag"
build caddy "$CADDY_IMAGE_REPO:$tag"
docker run --rm --entrypoint cat "$SERVER_IMAGE_REPO:$tag" /app/SOURCES
if [ "$save" = 1 ]; then
  mkdir -p "$HERE/dist"; out="$HERE/dist/hagencylabs-$tag.tar.gz"
  docker save "$SERVER_IMAGE_REPO:$tag" "$CADDY_IMAGE_REPO:$tag" | gzip -1 > "$out.tmp" && mv "$out.tmp" "$out"
  echo "archive: $out ($(du -h "$out" | cut -f1)); sha256 $(shasum -a 256 "$out" 2>/dev/null | cut -d' ' -f1 || sha256sum "$out" | cut -d' ' -f1)"
fi
if [ "$push" = 1 ]; then docker push "$SERVER_IMAGE_REPO:$tag"; docker push "$CADDY_IMAGE_REPO:$tag"; fi
echo "tag: $tag"
