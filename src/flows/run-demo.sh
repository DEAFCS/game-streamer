#!/usr/bin/env bash
# Download DEMO_URL and launch cs2 with +playdemo.
# Required env: MATCH_ID, DEMO_URL. CLIP_BATCH_MODE=1 â†’ batch-highlights mode.

set -uo pipefail
SCRIPT_TAG=run-demo

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
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
require_env MATCH_ID DEMO_URL

start_status_reporter

: "${FPS:=60}"
# Demo playback render cap. We capture at 60Hz; 120 gives 2x headroom so cs2 keeps
# delivering >=60 distinct presents/s through frame-time spikes. Present-driven
# capture samples each present and do-timestamp+videorate decimate 120->60 cleanly
# (drops, no dups) â€” headroom keeps the 60fps output dup-free + A/V synced. The GPU
# clock-lock (cs2_autotune) keeps it steady. 0 = uncapped; lower only if heat-limited.
: "${CS2_FPS_MAX:=120}"
# TrueView prediction for the spectated player's view: reconstructs the observed
# player's real camera/aim by re-running client-side prediction instead of showing
# tick-sampled server angles. 2 = always predict (smoothest aim; overrides the
# demo-build-version check so older 5stack demos still get the predicted POV),
# 1 = predict only on build match, 0 = off. Applied in the demo autoexec.
: "${CS2_DEMO_PREDICT:=2}"
# Debug overlay: bake cl_showfps + net_graph into the captured clip (cs2's real
# render fps + frametime, readable straight off the mp4). 0 = off (production,
# clean clips); 1 = on to diagnose a capture/perf issue.
: "${CS2_DEBUG_OVERLAY:=0}"
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
: "${DEMO_DOWNLOAD_TIMEOUT:=300}"
: "${DEMO_FILE:=/tmp/game-streamer/demo.dem}"

mkdir -p "$(dirname "$DEMO_FILE")"

steam_pipe_up || die "Steam isn't running"
xorg_running  || die "Xorg isn't up"
restore_real_steamclient

start_snapshot_loop || warn "start_snapshot_loop failed â€” continuing without thumbnails"

pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
stop_capture "$MATCH_ID"
sleep 1
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

report_status status=downloading_demo \
  "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}"

# game-streamer.sh's `demo` flow downloads in parallel with setup-steam.
# Wait on the marker files; fall back to inline if no parallel download
# was kicked off.
if [ ! -f "$DEMO_FILE" ] && [ ! -f "${DEMO_FILE}.failed" ] \
   && [ -f /tmp/game-streamer/demo-download.pid ]; then
  for _ in $(seq 1 "$DEMO_DOWNLOAD_TIMEOUT"); do
    [ -f "$DEMO_FILE" ] || [ -f "${DEMO_FILE}.failed" ] && break
    sleep 1
  done
fi
if [ -f "${DEMO_FILE}.failed" ]; then
  die "demo download failed from $DEMO_URL"
fi
if [ ! -f "$DEMO_FILE" ]; then
  DEMO_URL_LC=$(printf '%s' "$DEMO_URL" | tr '[:upper:]' '[:lower:]')
  case "${DEMO_URL_LC%%[?#]*}" in
    *.bz2)
      curl --fail --silent --show-error --location \
           --retry 5 --retry-delay 2 --retry-all-errors \
           --max-time "$DEMO_DOWNLOAD_TIMEOUT" \
           --output "${DEMO_FILE}.bz2" \
           "$DEMO_URL" \
        || die "demo download failed from $DEMO_URL"
      bunzip2 -q -c "${DEMO_FILE}.bz2" > "$DEMO_FILE" \
        || die "demo bunzip2 failed for ${DEMO_FILE}.bz2"
      rm -f "${DEMO_FILE}.bz2"
      ;;
    *.gz)
      curl --fail --silent --show-error --location \
           --retry 5 --retry-delay 2 --retry-all-errors \
           --max-time "$DEMO_DOWNLOAD_TIMEOUT" \
           --output "${DEMO_FILE}.gz" \
           "$DEMO_URL" \
        || die "demo download failed from $DEMO_URL"
      gunzip -q -c "${DEMO_FILE}.gz" > "$DEMO_FILE" \
        || die "demo gunzip failed for ${DEMO_FILE}.gz"
      rm -f "${DEMO_FILE}.gz"
      ;;
    *)
      curl --fail --silent --show-error --location \
           --retry 5 --retry-delay 2 --retry-all-errors \
           --max-time "$DEMO_DOWNLOAD_TIMEOUT" \
           --output "$DEMO_FILE" \
           "$DEMO_URL" \
        || die "demo download failed from $DEMO_URL"
      ;;
  esac
fi

CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"
write_cs2_video_cfg demo

read -r -d '' HIDE_UI_CMDS <<'EOF' || true
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
// Demo playback isn't a real server, so these aren't sv_cheats-gated.
cl_drawhud 0
r_drawviewmodel 0
cl_show_observer_crosshair 0
// demo_interpolateview defaults to 1 (smooth camera between ticks); pinned
// here so a config/build change can't silently reintroduce tick-stepping.
demo_interpolateview 1
// cl_demo_predict is env-tunable via CS2_DEMO_PREDICT (injected into
// live_autoexec below), not pinned here.
// Hide assist credits in the kill feed during playback.
mp_display_kill_assists 0
// Don't let cs2 quit when a demo finishes â€” batch-highlights reuses the same
// cs2 process across jobs, so an auto-quit would kill the remaining renders.
demo_quitafterplayback 0
EOF

SPEC_BINDS_BLOCK="$(spec_static_binds_block)"
DEMO_BINDS_BLOCK="$(demo_static_binds_block)"

OBSERVER_SRC="$SRC_DIR/../resources/observer.cfg"
EXEC_OBSERVER=""
if [ -x "${HUD_BIN:-/opt/hud-manager/jts-hud-manager}" ] && [ -f "$OBSERVER_SRC" ]; then
  cp -f "$OBSERVER_SRC" "$CS2_CFG_DIR/observer.cfg"
  EXEC_OBSERVER="exec observer.cfg"
fi

# autoexec.cfg gets auto-execed by cs2 on engine init AND we pass
# +exec live_autoexec on the command line. If both files carry the
# same payload, every `exec observer.cfg` + every bind is interpreted
# twice (~30 binds Ã— 2 passes), visible in console.log. Keep
# autoexec.cfg stubbed; put the real payload in live_autoexec.cfg.
printf '// see live_autoexec.cfg\n' > "$CS2_CFG_DIR/autoexec.cfg"

cat > "$CS2_CFG_DIR/live_autoexec.cfg" <<EOF
con_enable 1
$HIDE_UI_CMDS
$(cs2_perf_autoexec_block)
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
$DEMO_BINDS_BLOCK
// TrueView prediction for the spectated view (see CS2_DEMO_PREDICT above).
cl_demo_predict ${CS2_DEMO_PREDICT}
// X-ray (player outlines through walls): default ON for live demo spectating,
// OFF for batch-highlights (clips are POV â€” x-ray would look wrong).
spec_show_xray $([ "${CLIP_BATCH_MODE:-0}" = "1" ] && echo 0 || echo 1)
// Brighten demo output (cs2 default fullscreen gamma is ~2.2; 2 lifts the
r_fullscreen_gamma 2
// Debug overlay (CS2_DEBUG_OVERLAY=1): bake the fps counter + net_graph into the
// clip so cs2's real render fps/frametime is visible. Emits nothing when off.
$([ "${CS2_DEBUG_OVERLAY:-0}" = "1" ] && printf 'cl_showfps 1\nnet_graph 1')
EOF

# Pre-create empty so cs2's `exec 5stack_exec` doesn't error before
# spec-server writes to it.
: > "$CS2_CFG_DIR/5stack_exec.cfg"

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

ROUND_TICKS_PATH="${LOG_DIR}/demo-round-ticks.json"
if [ -n "${ROUND_TICKS:-}" ]; then
  printf '%s\n' "$ROUND_TICKS" > "$ROUND_TICKS_PATH"
else
  : > "$ROUND_TICKS_PATH"
fi

for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

# Workshop map prefetch (parallel-started in game-streamer.sh demo flow).
# cs2 stalls on a Subscribe prompt if +playdemo touches a workshop map.
if [ -n "${WORKSHOP_ID:-}" ]; then
  report_status status=downloading_workshop_map "workshop_id=${WORKSHOP_ID}"
  WORKSHOP_TARGET="${STEAM_LIBRARY}/steamapps/workshop/content/730/${WORKSHOP_ID}"
  WORKSHOP_FAILED="/tmp/game-streamer/workshop-${WORKSHOP_ID}.failed"
  WORKSHOP_TIMEOUT="${WORKSHOP_DOWNLOAD_TIMEOUT:-180}"
  if ! compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1 \
     && [ -f /tmp/game-streamer/workshop-download.pid ]; then
    for _ in $(seq 1 "$WORKSHOP_TIMEOUT"); do
      compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1 && break
      [ -f "$WORKSHOP_FAILED" ] && break
      sleep 1
    done
  fi
  if [ -f "$WORKSHOP_FAILED" ] \
     || ! compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1; then
    download_workshop_map "$WORKSHOP_ID" \
      || warn "workshop map download failed â€” cs2 may stall on Subscribe prompt"
  fi
fi

report_status status=launching_cs2
# -applaunch scrubs XDG_RUNTIME_DIR, so pin PULSE_SERVER over TCP.
export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER

do_applaunch() {
  # +playdemo on the launch line so cs2 starts loading the demo during
  # engine init â€” the stream never shows the main menu. -condebug tees
  # cs2's console to csgo/console.log.
  #
  # Boot-time trim flags. The set below was the survivor of an
  # empirical pass against the ~5s Panorama main-menu init gap
  # between `server module init ok` and `DELAYED COMMAND: playdemo`.
  # Flags that demonstrably didn't bite on this cs2 build
  # (-nogamestats, -noassert, -allow_third_party_software, -vrmode
  # none, -nominidumps, -language english) were dropped â€” the
  # leaderboards job, localization spam, and BlurTarget warnings all
  # kept firing with them set.
  #   -disable_loadingplaque   recommended Source 2 perf hint
  #   +cl_disablehtmlmotd 1    skip HTML MOTD subsystem init
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
    -insecure -condebug
    -disable_loadingplaque
    +cl_disablehtmlmotd 1
    +fps_max "$CS2_FPS_MAX"
    +exec live_autoexec
    +playdemo "$DEMO_FILE")
  export_cs2_shader_cache_env  # cs2-only GLCache env (pod-wide broke Steam)
  # Confine cs2 to its own cores (disjoint from the capture pipeline's) so the two
  # never share a core â€” the affinity is inherited by the cs2 child of the steam
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

if hud_running; then
  # Forward HUD_MODE as the variant â€” omitting it resets the boot-
  # time variant the auto-overlay set.
  curl -fsS -m 5 -X POST -o /dev/null \
       -H 'content-type: application/json' \
       --data "{\"variant\":\"${HUD_MODE:-horizontal}\"}" \
       "http://${HUD_HOST:-127.0.0.1}:${HUD_PORT:-1349}/api/overlay/start" \
    || warn "/api/overlay/start failed"
fi

if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
  # No mediamtx publish â€” inline-clip-render.sh captures each clip on
  # its own ffmpeg pass.
  report_status status=live "playback_mode=demo"
else
  start_capture "$MATCH_ID" "$FPS" "$VIDEO_KBPS" false 1 \
    || die "capture failed to publish"
  report_status status=live \
    "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}" \
    "playback_mode=demo"
fi

if hud_running; then
  ( position_hud_overlay || true ) &
fi

# Surface a silent cs2 crash so the pod doesn't sit in "status=live but
# no frames".
(
  while kill -0 "$CS2_PID" 2>/dev/null; do sleep 5; done
  warn "cs2 (pid=$CS2_PID) exited"
  command -v report_status >/dev/null 2>&1 \
    && report_status status=errored "error=cs2 process exited unexpectedly"
) &

# Batch mode: process every clip job against this cs2 instance, then
# exit so the Job is reaped. cs2 launch is ~60-90s; reusing the
# instance turns N clips Ã— 90s overhead into a single launch.
if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
  stop_snapshot_loop
  # shellcheck disable=SC1091
  . "$LIB_DIR/batch-highlights.sh"
  process_batch_jobs
  exit 0
fi

# api kills the Job when streaming ends; exit 0 would tear the pod
# down mid-match. cs2/gst are nohup'd so we can't wait on them.
while :; do
  sleep 3600 &
  wait $!
done
