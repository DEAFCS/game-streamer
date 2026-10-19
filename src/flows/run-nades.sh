#!/usr/bin/env bash
# Launch CS2 against a nade practice server and render every lineup in
# NADE_BATCH_JOBS from that one session.
# Required env: NADE_BATCH_JOBS, CONNECT_ADDR (+ CONNECT_PASSWORD).

set -uo pipefail
SCRIPT_TAG=run-nades

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/shader-cache.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-perf.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-options.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-tune.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/hud-manager.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/snapshot.sh"

load_env
require_env NADE_BATCH_JOBS

start_status_reporter

if [ -n "${NADE_CONNECT_ADDR:-}" ]; then
  CS2_CONNECT_ADDR="$NADE_CONNECT_ADDR"
  CS2_CONNECT_PASSWORD="${NADE_CONNECT_PASSWORD:-}"
elif [ -n "${CONNECT_ADDR:-}" ]; then
  CS2_CONNECT_ADDR="$CONNECT_ADDR"
  CS2_CONNECT_PASSWORD="${CONNECT_PASSWORD:-}"
else
  die "no practice server to connect to — set CONNECT_ADDR (+CONNECT_PASSWORD)"
fi

# 127.0.0.1:<port>: the api books the practice server on this pod's node, and
# loopback is the one address it accepts a connect on from here.
log "connect target: $CS2_CONNECT_ADDR"

: "${NADE_OUT_DIR:=/tmp/game-streamer/nades}"
: "${NADE_OUTPUT_FPS:=60}"
# A render that keeps snapshotting should not throttle to the 30s "playing"
# cadence the moment GSI flows -- keep it dense so a throw is actually visible.
: "${SNAPSHOT_INTERVAL_SECONDS:=${SNAPSHOT_BOOT_INTERVAL_SECONDS:-5}}"
export SNAPSHOT_INTERVAL_SECONDS
# The capture samples cs2's swapchain, so cs2 must render ABOVE the capture
# rate for every sample to be a fresh frame — same 2x headroom the demo flow
# uses on the vkcapture path.
if vkcapture_available; then
  : "${CS2_FPS_MAX:=$(( NADE_OUTPUT_FPS * 2 ))}"
else
  : "${CS2_FPS_MAX:=$NADE_OUTPUT_FPS}"
fi
: "${CS2_WINDOW_TIMEOUT:=300}"
cs2_autotune

steam_pipe_up || die "Steam isn't running"
xorg_running  || die "Xorg isn't up"
restore_real_steamclient

start_snapshot_loop || warn "start_snapshot_loop failed — continuing without thumbnails"

pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
sleep 1
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR" "$NADE_OUT_DIR"
write_cs2_video_cfg demo

# The clip IS the alignment reference, so the crosshair and viewmodel stay on;
# only the chrome a viewer can't act on is trimmed. cl_draw_only_deathnotices
# keeps the crosshair while dropping the rest of the HUD. The crosshair is a
# fixed small static one, whatever the bot account's profile says, so the
# close-up shows the exact pixel the lineup is aimed at.
read -r -d '' NADE_VIEW_CMDS <<'EOF' || true
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
r_drawviewmodel 1
viewmodel_presetpos 1
cl_draw_only_deathnotices 1
cl_showfps 0
net_graph 0
r_fullscreen_gamma 2
cl_crosshairstyle 4
cl_crosshairsize 2
cl_crosshairgap -2
cl_crosshairthickness 0.6
cl_crosshairdot 0
cl_crosshair_t 0
cl_crosshair_drawoutline 1
cl_crosshair_outlinethickness 1
cl_crosshaircolor 1
cl_crosshairusealpha 1
cl_crosshairalpha 255
snd_musicvolume 0
snd_menumusic_volume 0
snd_roundstart_volume 0
snd_roundend_volume 0
snd_roundaction_volume 0
snd_mapobjective_volume 0
snd_tensecondwarning_volume 0
snd_deathcamera_volume 0
snd_mvp_volume 0
cl_hud_telemetry_frametime_show 0
cl_hud_telemetry_ping_show 0
cl_hud_telemetry_net_misdelivery_show 0
cl_hud_telemetry_net_detailed 0
cl_hud_telemetry_serverrecvmargin_graph_show 0
r_show_build_info 0
EOF

# Also kept as its own cfg: the account's saved config can load after the
# autoexec and bring the music back, so every lineup re-execs this in game.
printf '%s\n' "$NADE_VIEW_CMDS" > "$CS2_CFG_DIR/nade_view.cfg"

printf '// see nade_autoexec.cfg\n' > "$CS2_CFG_DIR/autoexec.cfg"
cat > "$CS2_CFG_DIR/nade_autoexec.cfg" <<EOF
con_enable 1
$NADE_VIEW_CMDS
$(cs2_perf_autoexec_block)
$(spec_static_binds_block)
password "$CS2_CONNECT_PASSWORD"
connect $CS2_CONNECT_ADDR
EOF

# Pre-create empty so cs2's `exec 5stack_exec` (the BACKSPACE bind spec-server
# flushes console commands through) doesn't error before the first write.
: > "$CS2_CFG_DIR/5stack_exec.cfg"

# The session gate (and the per-job join) read the local player's health off
# GSI, and a player standing still on a lineup emits no state changes; pulse
# faster than the gate's 2s freshness window.
: "${GSI_HEARTBEAT:=0.5}"
export GSI_HEARTBEAT
write_gsi_cfg

for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

report_status status=launching_cs2
export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER

do_applaunch() {
  local thread_args=()
  [ "${CS2_THREADS:-0}" != 0 ] && thread_args=(-threads "$CS2_THREADS")
  # -condebug tees cs2's console to csgo/console.log, which is where the
  # practice plugin's [5stack-render] lines are read from.
  local cs2_args=(
    -windowed -noborder
    -width "$CS2_WIDTH" -height "$CS2_HEIGHT"
    -novid -nojoy -high -console -condebug
    "${thread_args[@]}"
    -disable_loadingplaque
    +cl_disablehtmlmotd 1
    +fps_max "$CS2_FPS_MAX"
    +exec nade_autoexec
    +password "$CS2_CONNECT_PASSWORD"
    +connect "$CS2_CONNECT_ADDR")
  export_cs2_shader_cache_env
  compute_cpu_split
  local cs2_pin=(); mapfile -t cs2_pin < <(cs2_cpu_pin)
  if [ "${#cs2_pin[@]}" -gt 0 ]; then
    log "cs2 pinned to cores ${GS_CS2_CPUS} (off the capture cores ${GS_CAPTURE_CPUS}); nproc=$(nproc)"
  fi
  local cmd=("${cs2_pin[@]}" "$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${cs2_args[@]}")
  spawn_logged cs2-launch "${cmd[@]}"
}
do_applaunch
wait_for_cs2_process do_applaunch

minimize_steam_windows
trim_steam_webhelper

report_status status=connecting_to_game
WIN=""
for _ in $(seq 1 "$CS2_WINDOW_TIMEOUT"); do
  WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
    | awk '/"Counter-Strike 2"/{print $1; exit}')
  [ -n "$WIN" ] && break
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
    die "cs2 EXITED early"
  fi
  sleep 1
done
[ -n "$WIN" ] || {
  tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
  die "no CS2 window after ${CS2_WINDOW_TIMEOUT}s"
}

# Nothing reassigns X input focus after the Steam windows are destroyed, and
# every console command we send is an XTest keystroke — so cs2 must hold focus.
timeout 5 xdotool windowfocus --sync "$WIN" 2>/dev/null || true

(
  while kill -0 "$CS2_PID" 2>/dev/null; do sleep 5; done
  warn "cs2 (pid=$CS2_PID) exited"
  command -v report_status >/dev/null 2>&1 \
    && report_status status=errored "error=cs2 process exited unexpectedly"
) &

# The snapshot loop keeps running through the connect/join/wait phase, where a
# render most often wedges and a live view is the whole point; batch-nades.sh
# stops it once the session is up so the screen grab never lands in a clip.
# shellcheck disable=SC1091
. "$LIB_DIR/batch-nades.sh"
process_nade_jobs
exit 0
