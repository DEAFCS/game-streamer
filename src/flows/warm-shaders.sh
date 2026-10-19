#!/usr/bin/env bash
# Pre-warm this node's Vulkan shader cache without a match: launch CS2 just
# long enough for Steam to run the shader precache to completion, then exit.
# The compiled cache persists on the node (STEAM_LIBRARY/steamapps/
# shadercache/730), so real matches on this node later start warm. Run as a
# per-GPU-node Job before go-live. Requires setup-steam to have run first.
set -uo pipefail
SCRIPT_TAG=warm-shaders

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-options.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/shader-cache.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/snapshot.sh"

load_env

start_status_reporter

steam_pipe_up || die "Steam isn't running"
xorg_running  || die "Xorg isn't up"
restore_real_steamclient

start_snapshot_loop || warn "start_snapshot_loop failed — continuing without thumbnails"

pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

# Match live's video settings so the warmed shaders are the ones live uses
# (the pipeline set depends on resolution / MSAA / quality).
CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"
write_cs2_video_cfg live

for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER

do_applaunch() {
  # No +connect / +playdemo — just boot CS2 so Steam runs the precache.
  report_status status=launching_cs2
  local cs2_args=(
    -windowed -noborder
    -width "$CS2_WIDTH" -height "$CS2_HEIGHT"
    -novid -nojoy -high -console
    -threads 4
    -disable_loadingplaque
    +cl_disablehtmlmotd 1)
  export_cs2_shader_cache_env
  local cmd=("$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${cs2_args[@]}")
  spawn_logged cs2-launch "${cmd[@]}"
}
do_applaunch
# Returns once cs2 spawns — i.e. the foreground precache finished compiling.
wait_for_cs2_process do_applaunch

# Exit as soon as background shader processing goes quiet instead of a fixed
# wait. shader_report_progress returns 0 while a compile is still active (log
# fresh + pct<100); once it's been idle for WARM_SETTLE_GRACE seconds we're
# done. WARM_SETTLE_MAX caps the total wait as a backstop.
log "foreground shader precache complete — waiting for background compile to settle"
settle_grace="${WARM_SETTLE_GRACE:-8}"
settle_max="${WARM_SETTLE_MAX:-90}"
idle=0
waited=0
while [ "$waited" -lt "$settle_max" ]; do
  if shader_report_progress; then
    idle=0
  else
    idle=$(( idle + 1 ))
    [ "$idle" -ge "$settle_grace" ] && break
  fi
  sleep 1
  waited=$(( waited + 1 ))
done
log "background compile settled after ${waited}s"

pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
log "shaders warmed on this node ($CS2_DIR/.../steamapps/shadercache/730)"
exit 0
