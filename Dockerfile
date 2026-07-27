# JTs Hud Manager (CS2 spectator HUD; upstream JohnTimmermann/JTs-Hud-Manager,
# renamed from OpenHud in v5.x) is built + published as its own image (see
# hud-manager/Dockerfile). Pin the tag with --build-arg HUD_IMAGE=...,
# defaulting to :latest off our package registry. Declared before the
# first FROM so it can substitute into the stage ref below.
ARG HUD_IMAGE=ghcr.io/5stackgg/hud-manager:latest
FROM ${HUD_IMAGE} AS hud

FROM nvidia/cuda:12.6.3-base-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive

ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all
ENV DISPLAY=:0
ENV HOME=/root
ENV GTK_A11Y=none
ENV NO_AT_BRIDGE=1
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# NB: __GL_SHADER_DISK_CACHE* is NOT set globally — pod-wide it regressed
# Steam bring-up. It's exported per-cs2 in src/lib/shader-cache.sh.

# Common tools + i386 arch for 32-bit Steam client deps.
#   curl       — download Steam bootstrap + steamcmd at image build
#   tini       — PID 1 reaper for the entrypoint
#   procps     — pgrep/pkill used heavily in lib/* and dev/*
#   xz-utils   — needed to extract bootstraplinux*.tar.xz from steam.deb
#   binutils   — `nm` for the dev libpango symbol check
#   gdb,strace — dev/debug-cs2-crash.sh
#   locales    — Steam expects a real UTF-8 locale
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tini procps xz-utils binutils \
      gdb strace locales software-properties-common \
      jq bzip2 gzip \
    && add-apt-repository -y universe \
    && dpkg --add-architecture i386 \
    && apt-get update

# X server + WM + dbus.
#   xdotool   — used to dismiss Steam CEF modals during launch (and, when
#               SHADER_PRECACHE=0, the "Processing Vulkan shaders" dialog)
#               and to drive console-connect.sh
#   xwininfo  — used to detect when the CS2 window appears
#   zenity    — Steam's bootstrap shells out to it for error popups; without
#               it Steam crashes hard on certain failure paths
RUN apt-get update && apt-get install -y --no-install-recommends \
      xserver-xorg-core xserver-xorg-legacy xserver-xorg-video-dummy \
      xinit x11-xserver-utils xauth xdotool x11-utils \
      openbox dbus dbus-x11 zenity

# GPU userspace (NVIDIA runtime injects the actual driver libs at runtime).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgl1 libglx-mesa0 libegl1 libgles2 \
      libvulkan1 mesa-vulkan-drivers vulkan-tools \
      libasound2t64 libpulse0 pulseaudio pulseaudio-utils

# CS2 runtime text/UI deps (the -dev variants are dropped — only runtime libs).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 \
      libfontconfig1 libfreetype6 libharfbuzz0b \
      libxrandr2 libxinerama1 libxi6 libxxf86vm1 libxcursor1 \
      libxcomposite1 libxdamage1 libxfixes3 libxtst6 \
      libnss3 libnspr4 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
      libdbus-1-3 libxkbcommon0 libgbm1 libcurl4t64

# GStreamer capture pipeline.
#   plugins-bad — provides srtsink
#   plugins-ugly — provides x264enc as a software fallback when NVENC fails
#   libav — avenc_aac for the audio leg
#   python3 — used by lib/steam.sh (libraryfolders.vdf manipulation)
RUN apt-get update && apt-get install -y --no-install-recommends \
      gstreamer1.0-tools \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
      gstreamer1.0-libav gstreamer1.0-x \
      ffmpeg \
      python3

# CUDA NVRTC runtime — REQUIRED for GStreamer's cudaconvert/cudascale/
# cudaconvertscale elements, which JIT-compile their colour-convert + scale
# kernels via libnvrtc at element registration. The `-base` CUDA image
# doesn't ship it, so those elements silently fail to register while
# cudaupload (pure memcpy) and nvcudah265enc (libnvidia-encode, injected by
# the container runtime) still work — which forces capture onto the CPU
# videoconvert path (the cs2 firefight-judder source). Installed from the
# CUDA apt repo already configured in the base image; the version component
# must match the base (12.6 -> cuda-nvrtc-12-6).
RUN apt-get update && apt-get install -y --no-install-recommends cuda-nvrtc-12-6 \
 && ln -sf libnvrtc.so.12 \
      /usr/local/cuda/targets/x86_64-linux/lib/libnvrtc.so \
 && ldconfig
# ^ the runtime package ships only libnvrtc.so.12; GStreamer's cuda converter
# dlopens the UNVERSIONED libnvrtc.so, so without this symlink cudaconvert/
# cudascale/cudaconvertscale never register (cudaupload + nvenc still do).

# obs-vkcapture Vulkan present-hook layer (CLIP_CAPTURE_METHOD=vkcapture). Loaded
# into cs2 via OBS_VKCAPTURE=1, it hooks vkQueuePresentKHR and shares the swapchain
# over a unix socket — capture never touches the X server, so it can't stall cs2's
# present. Build the LAYER ONLY (-DBUILD_PLUGIN=OFF drops the libobs dependency);
# vkcapture-consumer (compiled below) is the socket consumer. Pinned to a release
# tag for reproducible builds. Requires nvidia-drm.modeset=1 on the host.
# present-eventfd.patch adds a per-present eventfd poke (see src/vkcapture/) so the
# consumer can frame-lock to cs2's presents; copied in before the clone so `git
# apply` can patch the freshly cloned tree (src/ proper isn't COPY'd until later).
COPY src/vkcapture/present-eventfd.patch /tmp/present-eventfd.patch
RUN set -eux; \
      apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates cmake build-essential pkg-config \
        libvulkan-dev libgl-dev libegl-dev libx11-dev libxcb1-dev \
      && git clone --depth=1 --branch v1.5.6 \
           https://github.com/nowrep/obs-vkcapture /tmp/obs-vkcapture \
      && git -C /tmp/obs-vkcapture apply /tmp/present-eventfd.patch \
      && cmake -S /tmp/obs-vkcapture -B /tmp/obs-vkcapture/build \
           -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DBUILD_PLUGIN=OFF \
      && cmake --build /tmp/obs-vkcapture/build --parallel \
      && cmake --install /tmp/obs-vkcapture/build \
      && test -f /usr/share/vulkan/implicit_layer.d/obs_vkcapture_64.json \
      && rm -rf /tmp/obs-vkcapture /tmp/present-eventfd.patch /var/lib/apt/lists/*

# Node.js — runs src/spectator/server.mjs (cs2 spectator-control HTTP
# daemon, refactored from the single-file src/spec-server.mjs). Ubuntu
# 24.04's apt ships Node 18; the daemon uses only built-in modules
# (node:http, node:child_process, node:fs) so any LTS works. Pull from
# NodeSource to get a current LTS without juggling apt pins.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs

# 32-bit libs required by the Steam client (Steam UI is 32-bit; CS2 itself
# is 64-bit but the launcher path needs the 32-bit stack to run).
RUN apt-get update && apt-get install -y --no-install-recommends \
      lib32gcc-s1 libc6-i386 \
      libsdl2-2.0-0:i386 libncurses6:i386 \
      libxtst6:i386 libx11-6:i386 libxext6:i386 libxrandr2:i386 \
      libxi6:i386 libxfixes3:i386 libxcursor1:i386 libxcomposite1:i386 \
      libxdamage1:i386 libxrender1:i386 libxkbcommon0:i386 libxinerama1:i386 \
      libgl1:i386 libegl1:i386 libgbm1:i386 \
      libnss3:i386 libnspr4:i386 libdbus-1-3:i386 \
      libfreetype6:i386 libpulse0:i386 libva2:i386

# JTs Hud Manager (Electron app) runtime deps not already present from the
# CS2 / Steam stack above. Mostly already covered (libnss3, libgbm1,
# libxkbcommon0, GTK2), but Electron 39+ links against gtk-3 + a handful
# of other libs that aren't in the CS2 path.
#   picom            — X compositor: needed for the HUD's transparent background
#                      to actually composite over CS2 on openbox.
#   wmctrl           — used by lib/hud-manager.sh to raise the overlay window
#                      above cs2 (also used for find/raise of Steam/Friends).
#   libgtk-3-0t64    — Electron renderer GTK stack
#   libxshmfence1    — Chromium GPU process synchronization
#   libsecret-1-0    — Electron uses libsecret for safeStorage on Linux
#   libnotify4       — Electron Notification API
#   libdrm2          — DRM, often picked up by the GPU stack already but
#                      list explicitly so we don't depend on transitive pulls
RUN apt-get update && apt-get install -y --no-install-recommends \
      picom wmctrl \
      libgtk-3-0t64 libxshmfence1 libsecret-1-0 libnotify4 libdrm2
# 32-bit Steam UI deps. steamui.so is 32-bit and uses dlmopen() to load
# its UI stack; dlmopen creates a new linker namespace that does NOT
# honor the bundled Steam runtime's LD_LIBRARY_PATH, so it falls
# through to the system loader. Without these the system has only the
# 64-bit equivalents and the load fails with "wrong ELF class:
# ELFCLASS64" -> Steam exits before webhelper spawns.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libglib2.0-0:i386 libgtk2.0-0:i386 libgdk-pixbuf-2.0-0:i386 \
      libpango-1.0-0:i386 libpangocairo-1.0-0:i386 libpangoft2-1.0-0:i386 \
      libcairo2:i386 libatk1.0-0:i386 \
      libxslt1.1:i386 libxml2:i386

RUN rm -rf /var/lib/apt/lists/*

# steamcmd from Valve's CDN. Always invoked as /opt/steamcmd/steamcmd.sh
# directly — the wrapper-script approach breaks steamcmd's self-relocation.
RUN mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd

# JTs Hud Manager (CS2 spectator HUD) — pulled from the separately-versioned
# image declared as the `hud` stage at the top of this file. The image
# carries the unpacked Electron binary at /opt/hud-manager/jts-hud-manager.
# The gamestate_integration cfg is no longer shipped as a file in v5.x
# (it's a const string in upstream src/main/ipc.ts); lib/hud-manager.sh's
# write_hud_gsi_cfg writes a matching cfg at runtime into cs2's cfg dir.
COPY --from=hud /opt/hud-manager/ /opt/hud-manager/

RUN locale-gen en_US.UTF-8

# Allow non-console user to start Xorg + pre-create the X11 socket dir.
RUN printf 'allowed_users=anybody\nneeds_root_rights=yes\n' >/etc/X11/Xwrapper.config \
 && mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Remove the default ubuntu user (UID 1000), run as root in this dev container.
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi \
 && mkdir -p /opt/game-streamer \
 && chown -R root:root /opt

# Pre-extract the Steam bootstrap into the image so a fresh pod (with an
# empty persistent volume) can launch Steam without first downloading and
# unpacking the .deb. The entrypoint will copy these files into the
# persisted Steam dir on first boot.
RUN mkdir -p /opt/steam-bootstrap \
 && curl -fsSL -o /tmp/steam.deb https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb \
 && dpkg-deb -x /tmp/steam.deb /tmp/steamdeb \
 && tar -xJf "$(find /tmp/steamdeb -name 'bootstraplinux*.tar.xz' | head -1)" \
        -C /opt/steam-bootstrap \
 && rm -rf /tmp/steam.deb /tmp/steamdeb

COPY src/ /opt/game-streamer/src/
COPY resources/ /opt/game-streamer/resources/
COPY resources/xorg-dummy-1080p.conf /etc/X11/xorg-dummy-1080p.conf
COPY resources/xorg-dummy-1440p.conf /etc/X11/xorg-dummy-1440p.conf
# Offscreen software-framebuffer configs (Driver "dummy"): the coexist fallback
# used when the GPU display is owned by a host desktop, so the streamer runs
# alongside a normal Ubuntu desktop (see start_xorg in src/lib/xorg.sh).
COPY resources/xorg-coexist-1080p.conf /etc/X11/xorg-coexist-1080p.conf
COPY resources/xorg-coexist-1440p.conf /etc/X11/xorg-coexist-1440p.conf
RUN chmod +x /opt/game-streamer/src/*.sh \
             /opt/game-streamer/src/*.mjs \
             /opt/game-streamer/src/actions/*.sh \
             /opt/game-streamer/src/dev/*.sh 2>/dev/null || true

# Compile the obs-vkcapture socket consumer (binds the layer's socket, pushes cs2's
# frames into a GStreamer NVENC pipeline). Build-only headers — the gstreamer/glib
# runtime libs are already in the image — so purge them after the build.
RUN set -eux; \
      build_deps="gcc pkg-config libglib2.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev"; \
      apt-get update && apt-get install -y --no-install-recommends $build_deps \
      && gcc -O2 -Wall -Wextra -o /usr/local/bin/vkcapture-consumer \
           /opt/game-streamer/src/vkcapture/vkcapture-consumer.c \
           $(pkg-config --cflags --libs glib-2.0 gio-2.0 gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 gstreamer-allocators-1.0) \
      && test -x /usr/local/bin/vkcapture-consumer \
      && apt-get purge -y $build_deps && apt-get autoremove -y \
      && rm -rf /var/lib/apt/lists/*

# Remotion motion project — owns the branded Outro (pre-rendered into
# resources/video/ at build time) and the per-job PlayerChip overlay
# composited onto each segment by inline-clip-render.sh. We split
# package install + source copy into separate layers so source-only
# edits don't bust the npm-install cache (full install is ~600MB).
COPY motion/package.json motion/package-lock.json /opt/game-streamer/motion/
RUN cd /opt/game-streamer/motion && npm ci --no-audit --no-fund

COPY motion/ /opt/game-streamer/motion/

# Synthesize the outro audio bed first, then pre-download Remotion's
# headless Chrome and pre-render the two standard outro variants
# (1080p60, 720p60). The audio is generated from ffmpeg lavfi (see
# motion/scripts/build-audio.sh) so the WAV stays out of git and the
# image always ships whatever the current script produces. Outros are
# static (no per-job props) — baking them in keeps the render-pod hot
# path to a concat-demux paste at the end of the clip. PlayerChip
# needs the player's name/kills, so it stays a per-job render at clip
# time.
RUN cd /opt/game-streamer/motion \
 && bash scripts/build-audio.sh \
 && node node_modules/.bin/remotion browser ensure \
 && mkdir -p out /opt/game-streamer/resources/video \
 && node node_modules/.bin/remotion render src/index.ts Outro \
      out/outro_1920x1080_60.mp4 \
      --codec=h264 --pixel-format=yuv420p \
      --props='{"width":1920,"height":1080,"fps":60,"durationS":3}' \
 && node node_modules/.bin/remotion render src/index.ts Outro \
      out/outro_1280x720_60.mp4 \
      --codec=h264 --pixel-format=yuv420p \
      --props='{"width":1280,"height":720,"fps":60,"durationS":3}' \
 && cp out/outro_*.mp4 /opt/game-streamer/resources/video/ \
 && rm -rf out

WORKDIR /opt/game-streamer

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/game-streamer/src/game-streamer.sh"]