#!/usr/bin/env bash
# Build and push ghcr.io/deafcs/hud-manager from the local hud-manager/
# context.
#
# JTs Hud Manager (upstream JohnTimmermann/JTs-Hud-Manager â€” formerly
# "OpenHud", renamed in v5.x) is consumed by game-streamer's Dockerfile
# via `COPY --from=ghcr.io/deafcs/hud-manager:<tag>`. This script builds
# the Linux unpacked Electron output (patched by auto-overlay.patch,
# which now also injects our own camera-overlay.js -- see
# DEAFCS/deafcs-web#91) and publishes it as :latest plus the pinned
# HUD_REF (so game-streamer can pin a specific HUD version via
# --build-arg HUD_IMAGE=ghcr.io/deafcs/hud-manager:<ref>).
#
# Deliberately our own registry namespace, not ghcr.io/5stackgg/hud-manager
# (upstream's public image) -- our auto-overlay.patch has diverged from
# theirs (camera-overlay.js injection), so we can't just consume their
# prebuilt image anymore.
#
# Usage:
#   ./push-latest.sh                            # build upstream pin from Dockerfile, push :latest + :<ref>
#   HUD_REF=v5.2.26 ./push-latest.sh            # pin a tag
#   HUD_REPO=5stackgg/JTs-Hud-Manager HUD_REF=foo ./push-latest.sh
set -euo pipefail

IMAGE="ghcr.io/deafcs/hud-manager"
CACHE_REF="${IMAGE}:buildcache"

HUD_REPO="${HUD_REPO:-JohnTimmermann/JTs-Hud-Manager}"
HUD_REF="${HUD_REF:-v5.2.26}"

# Sanitize the ref for use as a docker tag: replace anything that isn't
# in [A-Za-z0-9._-] with `-`. Tags like `feature/foo` or refs/heads/...
# would otherwise be rejected by the registry.
REF_TAG="$(printf '%s' "$HUD_REF" | tr -c 'A-Za-z0-9._-' '-')"

cd "$(dirname "$0")"

echo "building $IMAGE from $HUD_REPO @ $HUD_REF"
echo "  -> tags: ${IMAGE}:latest ${IMAGE}:${REF_TAG}"

docker buildx build \
  --platform linux/amd64 \
  --push \
  --build-arg "HUD_REPO=${HUD_REPO}" \
  --build-arg "HUD_REF=${HUD_REF}" \
  --tag "${IMAGE}:latest" \
  --tag "${IMAGE}:${REF_TAG}" \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  .

echo
echo "done. pin in game-streamer with:"
echo "  docker build --build-arg HUD_IMAGE=${IMAGE}:${REF_TAG} ."
