# =============================================================================
# JTs Hud Manager (formerly OpenHud — renamed upstream in v5.x) — standalone,
# versioned image.
#
# Upstream JohnTimmermann/JTs-Hud-Manager only publishes Windows/AppImage
# artifacts. We build the Linux x64 `linux-unpacked` electron-builder output
# ourselves here and publish the result as ghcr.io/5stackgg/hud-manager:<tag>.
# game-streamer's Dockerfile pulls from this image via
# `COPY --from=ghcr.io/5stackgg/hud-manager:...` so the HUD versions
# independently of the streamer.
#
# Build:
#   docker build -t ghcr.io/5stackgg/hud-manager:v5.2.26 \
#     --build-arg HUD_REPO=JohnTimmermann/JTs-Hud-Manager \
#     --build-arg HUD_REF=v5.2.26 \
#     hud-manager/
#
# Publish:
#   docker push ghcr.io/5stackgg/hud-manager:v5.2.26
#   docker tag  ghcr.io/5stackgg/hud-manager:v5.2.26 ghcr.io/5stackgg/hud-manager:latest
#   docker push ghcr.io/5stackgg/hud-manager:latest
#
# Then rebuild game-streamer with:
#   docker build --build-arg HUD_IMAGE=ghcr.io/5stackgg/hud-manager:v5.2.26 .
# =============================================================================

# ---- Stage 1: build the Electron app ----------------------------------------
FROM node:22-bookworm AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG HUD_REPO=JohnTimmermann/JTs-Hud-Manager
ARG HUD_REF=v5.2.26

# sqlite3 is a node-gyp native build → needs python3 + a C++ toolchain.
# git fetches the source at the requested ref without baking a tarball
# URL into the image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "$HUD_REF" \
      "https://github.com/${HUD_REPO}.git" . \
      || (git clone "https://github.com/${HUD_REPO}.git" . \
          && git checkout "$HUD_REF")

# Patch (additive only): expose the spectator HUD overlay creation as an
# exported function, auto-open the bundled `default` HUD on app-ready
# when HUD_AUTO_OVERLAY=1, add a POST /api/overlay/start route, and
# serve the Vue admin UI over plain HTTP so the K8s Service / port-
# forward path reaches the same panel. Tracked at
# hud-manager/auto-overlay.patch in the game-streamer repo.
#
# Upstream's v5.x rewrite already does the right thing for the structural
# bits we used to sed-fix in the openhud era (focusable: true is fine
# because the overlay calls setIgnoreMouseEvents/enforceOverlayOnTop;
# the admin window is a separate 1280x720 window). The overlay's old
# hardcoded 1920×1080 BrowserWindow is replaced by auto-overlay.patch
# with `...screen.getPrimaryDisplay().bounds` + fullscreen:true, so the
# overlay tracks whatever resolution Xorg reports (1080p / 1440p).
COPY auto-overlay.patch /tmp/auto-overlay.patch
RUN git apply --verbose /tmp/auto-overlay.patch \
 && rm /tmp/auto-overlay.patch

ENV ELECTRON_BUILDER_CACHE=/tmp/eb-cache \
    ELECTRON_CACHE=/tmp/electron-cache

RUN npm ci --no-audit --no-fund

# `build:unpack` runs: electron-vite build of main+preload+renderer,
# then electron-builder --dir (Linux). Output lands in
# dist/linux-unpacked/ with the binary at dist/linux-unpacked/jts-hud-manager.
# We pass --linux so the platform isn't auto-detected from the (debian)
# build host's architecture in a way that surprises later.
RUN npm run build && npx electron-builder --linux --dir \
 && test -x dist/linux-unpacked/jts-hud-manager \
 && rm -rf /tmp/eb-cache /tmp/electron-cache

# Stage the unpacked binary at a stable path. The default HUD bundle
# lives inside resources/app.asar (under /resources/default-hud) and is
# served by the app itself at http://localhost:1349/huds/default/...
# — we don't extract it. The gamestate_integration cfg is no longer
# shipped as a file in v5.x (it's a const string in src/main/ipc.ts);
# game-streamer's lib/hud-manager.sh:write_hud_gsi_cfg writes a
# matching cfg directly into cs2's cfg dir at runtime.
RUN mkdir -p /out/hud-manager \
 && cp -a dist/linux-unpacked/. /out/hud-manager/

# ---- Stage 2: publishable image ---------------------------------------------
# `scratch` would be ideal for a pure-payload image, but BuildKit's
# remote `COPY --from=<image>` against a scratch image can be flaky on
# older Docker daemons. Stick with a tiny base.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/5stackgg/game-streamer"
LABEL org.opencontainers.image.description="JTs Hud Manager Linux unpacked build, consumed by game-streamer via COPY --from"
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /out/hud-manager /opt/hud-manager
RUN chmod +x /opt/hud-manager/jts-hud-manager

# This image is not meant to run on its own — game-streamer COPY --from's
# /opt/hud-manager out of it. If someone does `docker run` it, print the
# layout so they immediately see what's here.
CMD ["sh", "-c", "ls -la /opt/hud-manager"]
