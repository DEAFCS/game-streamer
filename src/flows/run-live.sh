#!/usr/bin/env bash
# Launch CS2 against an active match and start the capture stream.
# Requires: MATCH_ID, and one of PLAYCAST_URL / CONNECT_TV_ADDR+CONNECT_TV_PASSWORD / CONNECT_ADDR+CONNECT_PASSWORD.

set -uo pipefail
SCRIPT_TAG=run-live

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/shader-cache.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/snapshot.sh"
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

load_env
require_env MATCH_ID

start_status_reporter

# Three connect modes mirror api/GameStreamerService:buildConnectEnv.
if [ -n "${PLAYCAST_URL:-}" ]; then
  CS2_CONNECT_MODE=playcast
elif [ -n "${CONNECT_TV_ADDR:-}" ]; then
  CS2_CONNECT_MODE=connect
  CS2_CONNECT_ADDR="$CONNECT_TV_ADDR"
  CS2_CONNECT_PASSWORD="${CONNECT_TV_PASSWORD:-}"
elif [ -n "${CONNECT_ADDR:-}" ]; then
  CS2_CONNECT_MODE=connect
  CS2_CONNECT_ADDR="$CONNECT_ADDR"
  CS2_CONNECT_PASSWORD="${CONNECT_PASSWORD:-}"
else
  die "no connect target â€” set PLAYCAST_URL, CONNECT_TV_ADDR+CONNECT_TV_PASSWORD, or CONNECT_ADDR+CONNECT_PASSWORD"
fi

: "${FPS:=60}"
# Live capture is the cs2-present-hook + HUD composite when available (see
# stream.sh): the consumer samples cs2's swapchain at the capture rate, so cs2 must
# render ABOVE it for every sample to be fresh -> 2x headroom. The ximagesrc
# fallback instead wants cs2 at the capture rate (evenly-spaced grabs). Explicit
# CS2_FPS_MAX env wins either way.
if vkcapture_available; then
  : "${CS2_FPS_MAX:=$(( FPS * 2 ))}"
else
  : "${CS2_FPS_MAX:=$FPS}"
fi
# Per-node hardware tuning: GPU scale-offload (GS_GPU_SCALE) + GPU clock lock from
# the detected GPU class (explicit env still wins; cs2 threads left to the engine).
cs2_autotune
# VIDEO_KBPS scales with the pixel count of CS2_DISPLAY_RES (1440p is
# 1.78x 1080p) so encoder quality stays roughly constant across modes.
# An explicit override (env or pod spec) still wins via `:=` semantics.
case "$CS2_DISPLAY_RES" in
  2560x1440) : "${VIDEO_KBPS:=20000}" ;;
  *)         : "${VIDEO_KBPS:=12000}" ;;
esac
: "${CS2_WINDOW_TIMEOUT:=300}"

steam_pipe_up || die "Steam isn't running"
xorg_running  || die "Xorg isn't up"
restore_real_steamclient

start_snapshot_loop || warn "start_snapshot_loop failed â€” will continue without thumbnails"

pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
stop_capture "$MATCH_ID"
sleep 1
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"
write_cs2_video_cfg live

# Source 2 silently drops +exec from launch args, so we write
# autoexec.cfg (auto-loaded at engine init) AND live_autoexec.cfg
# (referenced explicitly below).
read -r -d '' HIDE_UI_CMDS <<'EOF' || true
// snd_mute_losefocus / engine_no_focus_sleep defaults mute cs2 and
// throttle its tick when it loses focus â€” and the HUD overlay sits
// above cs2, so cs2 never has focus.
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
EOF

SPEC_BINDS_BLOCK="$(spec_static_binds_block)"

OBSERVER_SRC="$SRC_DIR/../resources/observer.cfg"
EXEC_OBSERVER=""
if [ -x "${HUD_BIN:-/opt/hud-manager/jts-hud-manager}" ] && [ -f "$OBSERVER_SRC" ]; then
  cp -f "$OBSERVER_SRC" "$CS2_CFG_DIR/observer.cfg"
  EXEC_OBSERVER="exec observer.cfg"
fi

# autoexec.cfg gets auto-execed by cs2 on engine init AND we pass
# +exec live_autoexec on the command line. If both files carry the
# same payload, every `exec observer.cfg` + every bind is interpreted
# twice. Keep autoexec.cfg stubbed; put the real payload in
# live_autoexec.cfg only.
printf '// see live_autoexec.cfg\n' > "$CS2_CFG_DIR/autoexec.cfg"

if [ "$CS2_CONNECT_MODE" = "playcast" ]; then
  cat > "$CS2_CFG_DIR/live_autoexec.cfg" <<EOF
con_enable 1
$HIDE_UI_CMDS
$(cs2_perf_autoexec_block)
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
playcast "$PLAYCAST_URL"
EOF
else
  cat > "$CS2_CFG_DIR/live_autoexec.cfg" <<EOF
con_enable 1
$HIDE_UI_CMDS
$(cs2_perf_autoexec_block)
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
password "$CS2_CONNECT_PASSWORD"
connect $CS2_CONNECT_ADDR
EOF
fi

# Pre-create empty so cs2's `exec 5stack_exec` (fired by BACKSPACE
# bind for the exec-cfg path) doesn't error before spec-server writes
# to it.
: > "$CS2_CFG_DIR/5stack_exec.cfg"

# GSI cfg is cheap; always (re)write so the URI tracks current code.
# setup-steam.sh does the api seed in the background â€” wait briefly for
# its marker, run inline if it never appeared.
write_gsi_cfg
PREP_MARKER="$LOG_DIR/match-cfgs-prepared"
PREP_FAILED="$LOG_DIR/match-cfgs-failed"
PREP_SKIPPED="$LOG_DIR/match-cfgs-skipped"
if [ ! -f "$PREP_MARKER" ] && [ ! -f "$PREP_SKIPPED" ] && [ ! -f "$PREP_FAILED" ]; then
  for _ in $(seq 1 10); do
    [ -f "$PREP_MARKER" ] || [ -f "$PREP_FAILED" ] && break
    sleep 0.5
  done
fi
if [ ! -f "$PREP_MARKER" ]; then
  seed_hud_db "$MATCH_ID"
fi

write_spec_player_binds \
  "$LOG_DIR/hud-seed-match.json" \
  "$CS2_CFG_DIR/live_autoexec.cfg" \
  "$LOG_DIR/spec-bindings.json"

# cs2 dlopens libpangoft2-1.0.so without the .0 suffix.
for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
# cwd matters for cs2's rpath-relative resolutions during launch handoff.
cd "$(dirname "$CS2_BIN")"

report_status status=launching_cs2
# -applaunch scrubs XDG_RUNTIME_DIR, so pin PULSE_SERVER over TCP.
export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER

do_applaunch() {
  # -windowed -noborder required so the alwaysOnTop Electron overlay
  # actually composites above cs2; exclusive -fullscreen prevents
  # stacking entirely.
  # Boot-trim flags â€” see run-demo.sh for the empirical pass that
  # narrowed this down from a larger experimental set.
  # cs2 threads are left to the engine (auto-detect, Valve's recommendation);
  # we pass -threads ONLY if CS2_THREADS is explicitly set â€” escape hatch for a
  # misbehaving node. Unset/0 omits the flag.
  local thread_args=()
  [ "${CS2_THREADS:-0}" != 0 ] && thread_args=(-threads "$CS2_THREADS")
  local cs2_args=(
    -windowed -noborder
    -width "$CS2_WIDTH" -height "$CS2_HEIGHT"
    -novid -nojoy -high -console
    "${thread_args[@]}"
    -disable_loadingplaque
    +cl_disablehtmlmotd 1
    +fps_max "$CS2_FPS_MAX"
    +exec live_autoexec)
  if [ "$CS2_CONNECT_MODE" = "playcast" ]; then
    cs2_args+=(+playcast "$PLAYCAST_URL")
  else
    cs2_args+=(+password "$CS2_CONNECT_PASSWORD" +connect "$CS2_CONNECT_ADDR")
  fi
  export_cs2_shader_cache_env  # cs2-only GLCache env (pod-wide broke Steam)
  # Confine cs2 to its own cores (disjoint from the capture pipeline's) so the two
  # never share a core â€” affinity is inherited by the cs2 child of the steam
  # wrapper. No-op on <4-core boxes / when taskset is absent (see cs2_cpu_pin).
  compute_cpu_split  # set GS_CS2_CPUS/GS_CAPTURE_CPUS in THIS shell (the pin runs in a subshell)
  local cs2_pin=(); mapfile -t cs2_pin < <(cs2_cpu_pin)
  if [ "${#cs2_pin[@]}" -gt 0 ]; then
    log "cs2 pinned to cores ${GS_CS2_CPUS} (off the capture cores ${GS_CAPTURE_CPUS}); nproc=$(nproc)"
  else
    log "cs2 NOT core-pinned: nproc=$(nproc) < GS_CS2_PIN_MIN_CORES=${GS_CS2_PIN_MIN_CORES:-6} (cs2 shares all cores; capture cores=${GS_CAPTURE_CPUS:-none})"
  fi
  local cmd=("${cs2_pin[@]}" "$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${cs2_args[@]}")
  spawn_logged cs2-launch "${cmd[@]}"
}
do_applaunch
wait_for_cs2_process do_applaunch

minimize_steam_windows

report_status status=connecting_to_game
WIN=""
for i in $(seq 1 "$CS2_WINDOW_TIMEOUT"); do
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

# Bring the HUD overlay over cs2 BEFORE the first capture frame goes
# out. setup-steam.sh's cfg-prep already fired /api/overlay/start once
# the seed completed (during steam-login) so the bundle is most likely
# already painted; the call below is an idempotent refresh that picks
# up the now-live GSI stream, plus position_hud_overlay restacks the
# Electron window above cs2 so the encoder grabs it.
if hud_running; then
  # Fire-and-forget the overlay/start â€” the previous (early) call from
  # cfg-prep already kicked it. We're not gating capture on this any
  # more; the prior shape held everything up if hud-manager was slow.
  # Forward HUD_MODE as the variant â€” omitting it resets the boot-
  # time variant the auto-overlay set.
  ( curl -fsS -m 5 -X POST -o /dev/null \
         -H 'content-type: application/json' \
         --data "{\"variant\":\"${HUD_MODE:-horizontal}\"}" \
         "http://${HUD_HOST:-127.0.0.1}:${HUD_PORT:-1349}/api/overlay/start" \
      || warn "/api/overlay/start failed" ) &
  # Position synchronously so the very first captured frame already
  # has the overlay composited. position_hud_overlay has its own
  # 30s timeout, so it can't stall the broadcast.
  position_hud_overlay || warn "position_hud_overlay failed â€” will continue"
fi

# 5th arg = 1 â†’ include PulseAudio leg.
start_capture "$MATCH_ID" "$FPS" "$VIDEO_KBPS" false 1 \
  || die "capture failed to publish"

report_status status=live \
  "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}"

# The api kills the Job when the stream ends; if we exit 0 the pod
# tears down mid-match. cs2/gst are nohup'd so we can't wait on them.
# Supervise the capture: srtsink auto-reconnect is off, so an SRT drop
# errors the pipeline out instead of silently reconnecting into mediamtx's
# stale HLS muxer (which desyncs audio). Respawn cleanly via restart_capture
# (its 1s gap lets mediamtx expire the old session and rebuild a synced muxer).
while :; do
  if ! stream_running "$MATCH_ID"; then
    warn "live capture down â€” restarting to resync via a fresh mediamtx session"
    restart_capture "$MATCH_ID" || warn "restart_capture failed; will retry"
  fi
  sleep 5 &
  wait $!
done
