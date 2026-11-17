#!/usr/bin/env bash
# Upgrade: back up first, then rebuild (or pull) images and redeploy.
# Roll back = restore.sh with the backup printed below + the previous image tags.
source "$(dirname "$0")/lib.sh"
load_env; validate_env
log "pre-upgrade backup"
"$BUNDLE/backup.sh"
for img in "$SERVER_IMAGE" "$CONCIERGE_IMAGE"; do
  docker image inspect "$img" >/dev/null 2>&1 && docker tag "$img" "${img%%:*}:previous"
done
log "previous images tagged :previous"
"$BUNDLE/deploy.sh"
