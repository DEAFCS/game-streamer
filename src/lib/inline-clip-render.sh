#!/usr/bin/env bash
set -uo pipefail
SCRIPT_TAG=inline-clip

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"

require_env CLIP_RENDER_JOB_ID CLIP_RENDER_TOKEN STATUS_API_BASE \
            SPEC_SERVER_URL

# Per-segment hard wall backstop, as a multiple of the segment's expected
# wallclock. The loop normally stops at the billed budget; this only fires for
# a wedged demo. Tight (2x, was 3x) so a misfire can't run deep into the next
# round. Fractional â€” applied via awk.
CLIP_SEGMENT_TIMEOUT_FACTOR="${CLIP_SEGMENT_TIMEOUT_FACTOR:-2}"
# Max time per segment we'll withhold from the budget for a suspected freeze
# (the documented ~2s post-seek stall). Bounds tail over-record to ~this if the
# freeze signal ever misfires.
CLIP_UNBILLED_CAP_MS="${CLIP_UNBILLED_CAP_MS:-2200}"
# Demo time played unrecorded before each segment, so the seek's aftermath (held
# frames, smokes re-blooming, sound restarting) never reaches the clip. 0 disables.
CLIP_PREROLL_MS="${CLIP_PREROLL_MS:-2000}"
CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"
: "${ROUND_TICKS_PATH:=${LOG_DIR:-/tmp/game-streamer}/demo-round-ticks.json}"

LOG_PREFIX="[clip ${CLIP_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

# Millisecond clock into a named var. bash 5's EPOCHREALTIME saves two
# forks per STEP 7 poll; date (+awk seconds-granularity rescue) otherwise.
if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; printf -v "$1" '%s' "${t:0:${#t}-3}"; }
else
  now_ms() {
    local v
    v=$(date +%s%3N 2>/dev/null) || v=""
    case "$v" in ''|*[!0-9]*) v=$(awk 'BEGIN{srand(); printf "%d", systime()*1000}') ;; esac
    printf -v "$1" '%s' "$v"
  }
fi

# --- Capture diagnostics --------------------------------------------------
# While a segment records, sample GPU util/VRAM/clock + cs2 & capture-process CPU
# every ~0.7s into the render log, timestamped from capture start (so the lines
# line up with the clip's seconds). Distinguishes a GPU stall (gpu% low while fps
# tanks) from VRAM thrash (vram near max) from cpu-bound (cs2cpu pegged) on any
# API-triggered render. Gated by CLIP_CAPTURE_DIAG (on by default; set 0 to mute).
CAPTURE_DIAG_PID=""
start_capture_diag() {
  [ "${CLIP_CAPTURE_DIAG:-1}" = "1" ] || return 0
  command -v nvidia-smi >/dev/null 2>&1 || { say "DIAG: nvidia-smi missing â€” skipping"; return 0; }
  local gst_pid="${1:-}"
  (
    cs2_pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    jif() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null; }   # utime+stime
    start_ms=$(date +%s%3N 2>/dev/null || echo 0)
    pcs2=$(jif "$cs2_pid"); pgst=$(jif "$gst_pid"); pms=$start_ms
    while :; do
      sleep 0.7
      now_ms=$(date +%s%3N 2>/dev/null || echo 0)
      dt=$(( now_ms - pms )); [ "$dt" -le 0 ] && dt=700
      g=$(nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,clocks.gr,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
      ccs2=$(jif "$cs2_pid"); cgst=$(jif "$gst_pid")
      cs2cpu=$(awk -v a="${pcs2:-}" -v b="${ccs2:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{ if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100 }')
      gstcpu=$(awk -v a="${pgst:-}" -v b="${cgst:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{ if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100 }')
      el=$(( (now_ms - start_ms) / 1000 ))
      say "DIAG +${el}s: gpu(util,memio,vramMiB,vramTot,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% gstcpu=${gstcpu}%"
      pcs2=$ccs2; pgst=$cgst; pms=$now_ms
    done
  ) &
  CAPTURE_DIAG_PID=$!
}
stop_capture_diag() {
  [ -n "${CAPTURE_DIAG_PID:-}" ] && kill "$CAPTURE_DIAG_PID" 2>/dev/null || true
  CAPTURE_DIAG_PID=""
}

api_status() {
  local body
  body=$(node "$CLIP_HELPERS" status-body "$@")
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status" \
    || say "WARN status post failed: $*"
}

# Progress-only status POST for the capture hot loop: throttled to ~1/s,
# single-flight (skipped while one is in flight) so remote-API RTT never
# stretches the 150ms poll cadence. Body via printf â€” both values are
# script-controlled here, unlike the node status-body path used elsewhere.
API_PROGRESS_PID=""
API_PROGRESS_LAST_MS=0
api_status_progress_async() {
  local now_ms="$1" frac="$2" status="${3:-rendering}"
  API_PROGRESS_LAST_MS=$now_ms
  curl --fail --silent --max-time 10 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/json" \
       --data "$(printf '{"status":"%s","progress":%s}' "$status" "$frac")" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status" \
    >/dev/null 2>&1 &
  API_PROGRESS_PID=$!
}
# Reap/cancel the in-flight progress POST. Default lets a healthy POST
# finish; "kill" is for terminal paths so a stray "rendering" can't land
# after a done/error status.
api_progress_settle() {
  [ -z "$API_PROGRESS_PID" ] && return 0
  if [ "${1:-wait}" = "kill" ]; then kill "$API_PROGRESS_PID" 2>/dev/null || true; fi
  wait "$API_PROGRESS_PID" 2>/dev/null || true
  API_PROGRESS_PID=""
}

# Parse curl's stderr progress meter and re-post it as "uploading" progress.
# The default meter is carriage-return delimited rows whose first column is
# "% Total" = the upload percent for a --upload-file POST. Throttled 1/s +
# single-flight like the render loop. Runs in a process-substitution subshell
# (so it owns its own API_PROGRESS_* copies) and settles its final post at EOF.
parse_upload_progress() {
  local line pct now milli
  while IFS= read -r line; do
    pct=${line%%[![:space:]]*}; pct=${line#"$pct"}; pct=${pct%%[[:space:]]*}
    case "$pct" in ''|*[!0-9]*) continue ;; esac
    [ "$pct" -gt 100 ] && continue
    now_ms now
    if [ $((now - API_PROGRESS_LAST_MS)) -ge 1000 ] \
       && { [ -z "$API_PROGRESS_PID" ] || ! kill -0 "$API_PROGRESS_PID" 2>/dev/null; }; then
      milli=$((pct * 10))
      api_status_progress_async "$now" \
        "$(printf '%d.%03d' $((milli / 1000)) $((milli % 1000)))" uploading
    fi
  done < <(tr '\r' '\n')
  api_progress_settle wait
}

spec_get_state() {
  curl --fail --silent --show-error --max-time 5 \
       "${SPEC_SERVER_URL}/demo/state"
}

spec_post() {
  local path="$1"; shift
  local body="${1:-{\}}"
  local http_code
  http_code=$(printf '%s' "$body" \
    | curl --silent --show-error --max-time 5 \
        --header "content-type: application/json" \
        --data-binary @- \
        --write-out "%{http_code}" \
        --output /dev/null \
        "${SPEC_SERVER_URL}${path}" \
    || echo "000")
  if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
    say "WARN spec POST $path -> $http_code (body=$body)"
  fi
}

die_failed() {
  local msg="$1"
  say "ERROR: $msg"
  api_progress_settle kill
  api_status "status=error" "error=${msg}"
  CLIP_REACHED_TERMINAL=1
  exit 1
}

# Fail the job on the GetClassBaseline crash; drop the sentinel so the batch skips.
fail_on_cs2_fatal() {
  local reason
  reason=$(cs2_fatal_reason "${CS2_LOG_OFFSET:-0}") || return 0
  cs2_mark_fatal "$reason"
  die_failed "cs2 cannot play this demo (${reason}) â€” known unfixed cs2 replay bug"
}

# Flag flipped to 1 once we've POSTed a terminal status (done / error /
# cancelled). The on_exit trap inspects it: if the script exits without
# having reached terminal â€” `set -u` tripped on an unset var,
# inline-clip-render.sh got SIGTERM mid-render, etc â€” the trap POSTs a
# best-effort status=error so the watchdog isn't left staring at a row
# stuck in "rendering" while the pod has already moved on / exited.
# Without this, batch-highlights pods could finish all 10 jobs in
# subshells that died early and exit 0 with every row still in-flight,
# producing the "pod exited cleanly but N job(s) never reached terminal
# state" warning in the api log.
CLIP_REACHED_TERMINAL=0

SAVED_TICK=""
SAVED_PAUSED=""

# Fixed timestep: while a segment records, cs2 advances exactly 1/fps of demo time per
# rendered frame (host_framerate) instead of its measured frame time, so a render
# spike can't make the world jump or the capture repeat a frame. Only with a capture
# that stamps frames by count (CLIP_CAPTURE_FIXED_TIMESTEP, see clip-capture.sh).
FIXED_TIMESTEP_ON=0
HOST_FR_CHECK_OFFSET=""   # console.log offset of the first enable; cleared once reported
set_fixed_timestep() {
  local fps="$1"
  if [ "$fps" = "0" ]; then
    [ "$FIXED_TIMESTEP_ON" = "1" ] || return 0
    # sv_cheats was only turned on for host_framerate; don't leave it on in the session.
    spec_post /demo/exec '{"cmd": "host_framerate 0; sv_cheats 0"}'
    FIXED_TIMESTEP_ON=0
  else
    # First enable of the job also queries the cvar (bare name), so the console echo
    # proves cs2 accepted it — see report_host_framerate.
    local query=""
    if [ -z "$HOST_FR_CHECK_OFFSET" ]; then
      HOST_FR_CHECK_OFFSET=$(wc -c < "${CS2_DIR}/game/csgo/console.log" 2>/dev/null || echo 0)
      HOST_FR_CHECK_OFFSET="${HOST_FR_CHECK_OFFSET//[!0-9]/}"; HOST_FR_CHECK_OFFSET="${HOST_FR_CHECK_OFFSET:-0}"
      query="; host_framerate"
    fi
    spec_post /demo/exec "{\"cmd\": \"sv_cheats 1; host_framerate ${fps}${query}\"}"
    FIXED_TIMESTEP_ON=1
  fi
}

# Once per job: echo cs2's console lines about host_framerate since the first enable
# (the value it reports, or an unknown-command / cheat-protected rejection). Without
# it taking effect the pacing alone still holds 60, but spikes move the world again.
report_host_framerate() {
  [ -n "$HOST_FR_CHECK_OFFSET" ] && [ "$HOST_FR_CHECK_OFFSET" != "done" ] || return 0
  local lines
  lines=$(tail -c "+$((HOST_FR_CHECK_OFFSET + 1))" "${CS2_DIR}/game/csgo/console.log" 2>/dev/null \
    | grep -a 'host_framerate' | tail -4) || true
  if [ -n "$lines" ]; then
    while IFS= read -r l; do say "  host_framerate console: ${l}"; done <<<"$lines"
  else
    say "  host_framerate console: no echo yet (console.log may be buffered)"
  fi
  HOST_FR_CHECK_OFFSET="done"
}

# With a fixed timestep the video runs on game time and the pulsesrc audio on wall
# time. The layer's pacing keeps them together, but a render stall it can't catch up
# leaves the video short of the wall clock, so stretch the audio by wall/video
# (atempo, pitch-preserving) when they differ by more than ~2 frames. The spans come
# from the consumer (timing file), not the container durations, whose start/stop
# tails differ by a few tens of ms even when nothing drifted.
retime_segment_audio() {
  local f="$1" timing="$2" video_ns wall_ns tempo tmp="${1}.retime.mp4"
  if [ -z "$timing" ] || [ ! -s "$timing" ]; then
    say "  audio retime: no timing from the capture — skipped"
    return 0
  fi
  video_ns=$(sed -n 's/.*video_ns=\([0-9]*\).*/\1/p' "$timing")
  wall_ns=$(sed -n 's/.*wall_ns=\([0-9]*\).*/\1/p' "$timing")
  if [ -z "$video_ns" ] || [ -z "$wall_ns" ] || [ "$video_ns" = "0" ]; then
    say "  audio retime: unreadable timing ($(cat "$timing" 2>/dev/null)) — skipped"
    return 0
  fi
  tempo=$(awk -v v="$video_ns" -v w="$wall_ns" 'BEGIN{
    d = v - w; if (d < 0) d = -d
    r = w / v
    if (d <= 35e6) { print "sync"; exit }
    if (r < 0.5 || r > 2.0) { print "range"; exit }
    printf "%.6f", r }')
  local spans="video=$((video_ns / 1000000))ms wall=$((wall_ns / 1000000))ms"
  case "$tempo" in
    sync)  say "  audio retime: ${spans} — in sync"; return 0 ;;
    range) say "  WARN audio retime: ${spans} — ratio outside atempo range, left as captured"; return 0 ;;
  esac
  say "  audio retime: ${spans} -> atempo=${tempo}"
  if ffmpeg -y -hide_banner -loglevel warning -i "$f" \
       -map 0:v -c:v copy -map 0:a -af "atempo=${tempo}" -c:a aac -b:a 192k \
       -movflags +faststart "$tmp"; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp"
    say "  WARN audio retime failed — keeping the raw segment"
  fi
}

restore_user_playback() {
  set_fixed_timestep 0
  if [ -z "$SAVED_TICK" ]; then return 0; fi
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SAVED_TICK}}"
  if [ "$SAVED_PAUSED" != "true" ]; then
    spec_post /demo/toggle '{}'
  fi
}

on_exit() {
  local rc=$?
  if [ "${LIVE_CAPTURE_STOPPED:-0}" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
    restart_capture "$MATCH_ID" || true
    LIVE_CAPTURE_STOPPED=0
  fi
  # Backgrounded chip render â€” kill it if we're exiting before the
  # polish pass had a chance to wait on it (e.g. cs2 stall, SIGTERM).
  if [ -n "${CHIP_RENDER_PID:-}" ] && kill -0 "$CHIP_RENDER_PID" 2>/dev/null; then
    kill -TERM "$CHIP_RENDER_PID" 2>/dev/null || true
    wait "$CHIP_RENDER_PID" 2>/dev/null || true
  fi
  # Backgrounded segment polish â€” same deal on early exit.
  if [ -n "${POLISH_BG_PID:-}" ] && kill -0 "$POLISH_BG_PID" 2>/dev/null; then
    kill -TERM "$POLISH_BG_PID" 2>/dev/null || true
    wait "$POLISH_BG_PID" 2>/dev/null || true
  fi
  [ -n "${POLISH_BG_LOG:-}" ] && rm -f "$POLISH_BG_LOG"
  [ -n "${CHIP_RENDER_LOG:-}" ] && rm -f "$CHIP_RENDER_LOG"
  # ProRes intermediates are ~20MB/s â€” drop the chip mov even on
  # error so a flapping pod doesn't fill its scratch dir.
  if [ -n "${CHIP_MOV:-}" ]; then rm -f "$CHIP_MOV"; fi
  stop_capture_diag
  restore_user_playback
  # Belt-and-suspenders status report. If we exited without having
  # POSTed a terminal status (set -u trip, SIGTERM, early exit before
  # die_failed was reachable), best-effort mark the row error so the
  # batch-highlights watchdog doesn't leave it stuck in-flight.
  api_progress_settle kill
  if [ "$rc" -ne 0 ] && [ "${CLIP_REACHED_TERMINAL:-0}" != "1" ]; then
    api_status "status=error" "error=render exited rc=${rc} before reaching terminal status" \
      || true
  fi
}
trap 'on_exit' EXIT

# Multi-segment input. CLIP_SEGMENTS is a JSON array of
# {start_tick,end_tick} from the api; each one is captured separately
# and the results are concatenated by ffmpeg into the final mp4.
# Falls back to the legacy single-segment env vars when unset so
# operators / tests that still pass CLIP_START_TICK / CLIP_END_TICK
# keep working. Resolved AFTER die_failed + the EXIT trap are in place
# so a misconfigured invocation marks the row error instead of leaving
# it stuck in "queued" while the pod exits cleanly.
if [ -z "${CLIP_SEGMENTS:-}" ]; then
  if [ -z "${CLIP_START_TICK:-}" ] || [ -z "${CLIP_END_TICK:-}" ]; then
    die_failed "CLIP_SEGMENTS or CLIP_START_TICK/CLIP_END_TICK required"
  fi
  CLIP_SEGMENTS="[{\"start_tick\":${CLIP_START_TICK},\"end_tick\":${CLIP_END_TICK}}]"
fi

# Fast capture-fields path: one in-process GET replaces the curl+node
# pipeline per STEP 7 poll. A stale spec-server (dev-pod rsync without a
# restart) 404s â€” fall back to the node parser and warn.
CAPTURE_FIELDS_FAST=0
CF_PROBE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 "${SPEC_SERVER_URL}/demo/capture-fields?pov=0" || echo 000)
if [ "$CF_PROBE" = "200" ]; then
  CAPTURE_FIELDS_FAST=1
else
  say "WARN /demo/capture-fields probe -> ${CF_PROBE} â€” spec-server predates it; using node fallback (restart spec-server)"
fi
POV_STATE_FAST=0
PS_PROBE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 "${SPEC_SERVER_URL}/demo/pov-state?pov=0" || echo 000)
if [ "$PS_PROBE" = "200" ]; then
  POV_STATE_FAST=1
else
  say "WARN /demo/pov-state probe -> ${PS_PROBE} â€” spec-server predates it; using node fallback (restart spec-server)"
fi

SEEK_STATE_FAST=0
SS_PROBE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 "${SPEC_SERVER_URL}/demo/seek-state" || echo 000)
if [ "$SS_PROBE" = "200" ]; then
  SEEK_STATE_FAST=1
else
  say "WARN /demo/seek-state probe -> ${SS_PROBE} — spec-server predates it; using /demo/state fallback (restart spec-server)"
fi

SEEK_STATE_FAST=0
SS_PROBE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 5 "${SPEC_SERVER_URL}/demo/seek-state" || echo 000)
if [ "$SS_PROBE" = "200" ]; then
  SEEK_STATE_FAST=1
else
  say "WARN /demo/seek-state probe -> ${SS_PROBE} — spec-server predates it; using /demo/state fallback (restart spec-server)"
fi

# "spectated_steam_id|pov_slot|slots_count|tick" from the fast endpoint.
spec_pov_state() {
  curl --fail --silent --max-time 5 \
    "${SPEC_SERVER_URL}/demo/pov-state?pov=${1:-}" || true
}

# "1" while cs2 is still executing a demo_gototick, else "0" (also "0" when the
# spec-server is unreachable — never block the render on a dead probe).
seek_in_progress() {
  local line
  if [ "$SEEK_STATE_FAST" = "1" ]; then
    line=$(curl --fail --silent --max-time 5 "${SPEC_SERVER_URL}/demo/seek-state" || true)
    printf '%s' "${line%%|*}"
    return
  fi
  spec_get_state | node "$CLIP_HELPERS" state-seeking 2>/dev/null || printf '0'
}

# Block until cs2 has actually ARRIVED at the last requested tick.
# /demo/seek returns 200 as soon as the gototick is QUEUED — the command itself
# is asynchronous and slow: forward seeks stall ~2s and backward seeks replay
# from tick 0, which is the case every segment hits. Starting capture and
# pressing play against a still-sweeping demo spent the whole 3s pre-kill lead
# before the playhead was even at the lead, so clips opened on the kill.
# Motion is NOT a usable arrival signal here — during the backward replay sweep
# the world is moving and the round clock is ticking, so a motion check reports
# "playing" while cs2 is still mid-sweep.
# Returns 0 on confirmed arrival, 1 on timeout (caller proceeds — a late clip
# beats no clip). Costs nothing in the output: the demo is paused and capture
# has not started, so no frames are produced while we wait.
wait_seek_settled() {
  local label="${1:-seek}"
  local timeout_ms="${2:-${CLIP_SEEK_SETTLE_TIMEOUT_MS:-8000}}"
  local t0 now waited=0
  now_ms t0
  # Real elapsed time: each poll also spends ~30ms in curl, so counting 100ms per
  # sleep let an "8s" ceiling run ~10s.
  while [ "$waited" -lt "$timeout_ms" ]; do
    if [ "$(seek_in_progress)" != "1" ]; then
      [ "$waited" -gt 0 ] && say "  ${label}: seek settled after ${waited}ms"
      return 0
    fi
    sleep 0.1
    now_ms now
    waited=$((now - t0))
  done
  say "WARN ${label}: seek still settling after ${timeout_ms}ms — proceeding anyway"
  return 1
}

# "phase|phase_ends|motion|gsi_age|map_phase|round|pov_kills"; empty on failure.
capture_fields_line() {
  if [ "$CAPTURE_FIELDS_FAST" = "1" ]; then
    curl --fail --silent --max-time 5 \
      "${SPEC_SERVER_URL}/demo/capture-fields?pov=${1:-}" || true
  else
    spec_get_state | node "$CLIP_HELPERS" capture-fields "${1:-}" || true
  fi
}

# "phase_ends|world_motion" — the GSI fields that advance only while the demo is
# actually rolling. Returns 1 (empty) when GSI is stale, so callers can tell
# "no signal" apart from "not moving yet"; pass "any" as $2 to skip that check.
playback_sig() {
  local line _p _pe _mo _age _mp _rn _pk
  line=$(capture_fields_line "${1:-}")
  IFS='|' read -r _p _pe _mo _age _mp _rn _pk <<<"$line"
  if [ "${2:-}" != "any" ]; then
    { [ -n "$_age" ] && [ "$_age" -le 750 ]; } 2>/dev/null || return 1
  fi
  printf '%s|%s' "$_pe" "$_mo"
}

# Block until the demo is demonstrably MOVING after the unpause. cs2 holds the
# paused frame for a while after a big backward seek, and the capture is already
# armed by then — those held frames are what made clips open on a second of
# statues. Unlike the arrival check this runs with playback requested, so the
# signal is unambiguous: either field changing means frames are worth recording.
# Returns 0 on confirmed motion, 1 on timeout (caller opens the gate anyway).
wait_playback_moving() {
  local baseline="$1"
  # Generous by design: while the demo is still frozen no demo time is passing, so
  # holding the gate costs nothing, and the post-seek stall this covers runs ~2s.
  local timeout_ms="${CLIP_PLAY_CONFIRM_TIMEOUT_MS:-2500}"
  local waited=0 sig
  while [ "$waited" -lt "$timeout_ms" ]; do
    sig=$(playback_sig "${SEG_POV_STEAMID:-}") || sig=""
    if [ -n "$sig" ] && [ "$sig" != "$baseline" ]; then
      say "STEP 5: playback moving after ${waited}ms"
      return 0
    fi
    sleep 0.05
    waited=$((waited + 50))
  done
  say "WARN playback not confirmed moving within ${timeout_ms}ms — recording anyway"
  return 1
}

# Hold the capture gate until $1 ms of DEMO time has played, measured off the GSI
# phase clock (flat while frozen), so a post-seek stall can't eat the pre-kill lead.
# $2/$3 = the paused clock value and the unpause time, so the demo time spent on the
# motion check and POV re-press counts too.
wait_preroll() {
  local want="$1" played=0 last_pe="${2:-}" last_t="${3:-0}" t0 now line pe age d
  local cap_ms=$(( want + CLIP_UNBILLED_CAP_MS + 2000 ))
  now_ms t0
  while :; do
    now_ms now
    if [ $(( now - t0 )) -ge "$cap_ms" ]; then
      say "WARN PREROLL: only ${played}ms of ${want}ms demo time after ${cap_ms}ms — opening the gate anyway"
      return 1
    fi
    line=$(capture_fields_line "${SEG_POV_STEAMID:-}")
    IFS='|' read -r _ pe _ age _ <<<"$line"
    if [ -n "$pe" ] && { [ -n "$age" ] && [ "$age" -le 750 ]; } 2>/dev/null; then
      if [ -n "$last_pe" ]; then
        # Countdown drop since the last reading. A rise, or a drop bigger than the wall
        # time between readings, is a countdown reset (freezetime end, bomb plant) — bill wall.
        d=$(awk -v a="$last_pe" -v b="$pe" -v w="$(( now - last_t ))" \
          'BEGIN{d=(a-b)*1000; printf "%d", ((d < 0 || d > w + 500) ? w : d)}')
        played=$(( played + d ))
      fi
      last_pe="$pe"; last_t=$now
      # The reading is $age ms old and the demo kept playing since (at 1x): count it,
      # or the gate opens up to that much late (readings up to 750ms old are taken).
      if [ $(( played + age )) -ge "$want" ]; then
        say "PREROLL: ${want}ms of demo time played in $(( now - t0 ))ms (last reading ${age}ms old)"
        return 0
      fi
    fi
    sleep 0.05
  done
}

# Log whether cs2's demo bar is on screen right now; echoes 1 when it is.
demoui_probe() {
  local line
  line=$(curl --fail --silent --max-time 8 "${SPEC_SERVER_URL}/demo/demoui-score" || echo "?|?|?")
  say "DEMOUI [$1]: visible|score|brightness = ${line}"
  printf '%s' "${line%%|*}"
}

# Last check before recording: the bar can open after the start-of-demo hide (e.g. on a
# slow box), so close it here if it's showing. Once seen closed it stays closed for this
# cs2 process, so later segments and jobs skip the grab (marker reset by batch-highlights).
DEMOUI_MARKER="${CLIP_DEMOUI_MARKER:-/tmp/game-streamer/.demoui-verified}"
hide_demoui_before_recording() {
  [ -f "$DEMOUI_MARKER" ] && return 0
  local tries=0 shown
  while :; do
    shown=$(demoui_probe "seg${SEG_IDX} pre-gate")
    { [ "$shown" = "1" ] && [ "$tries" -lt 3 ]; } || break
    spec_post /demo/exec '{"cmd": "demoui"}'
    tries=$((tries + 1))
    sleep 0.8
  done
  if [ "$shown" = "0" ]; then : > "$DEMOUI_MARKER"; fi
}

log_state() {
  local label="$1"
  local s tick paused motion slots spectated
  s=$(spec_get_state || true)
  if [ -z "$s" ]; then
    say "STATE [$label]: <unreachable>"
    return
  fi
  tick=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-tick)
  paused=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-paused)
  # world_motion is the only REAL playback signal (tick/paused are
  # bookkeeping). slots/spectated expose roster churn at round boundaries,
  # which makes world_motion change without anyone actually moving.
  motion=$(printf '%s' "$s" | node "$CLIP_HELPERS" world-motion)
  slots=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-slots)
  spectated=$(printf '%s' "$s" | node "$CLIP_HELPERS" spectated-steamid)
  # round_phase distinguishes a paused demo (bug) from a playing demo whose
  # players are frozen in the post-round "over" phase (constant motion, but
  # not a bug â€” the segment just extends past the action).
  local phase
  phase=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-round-phase)
  say "STATE [$label]: tick=$tick paused=$paused motion=${motion:-?} phase=${phase:-?} slots=${slots} spec=${spectated:-?}"
}

# Read GSI's currently-spectated steamid64. Returns empty string when
# GSI hasn't fired yet or the field isn't set.
gsi_spectated_steamid() {
  if [ "$POV_STATE_FAST" = "1" ]; then
    local line
    line=$(spec_pov_state)
    printf '%s' "${line%%|*}"
    return
  fi
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" | node "$CLIP_HELPERS" spectated-steamid
}

# Look up the target's CURRENT slot number (1..10) from GSI's
# spec_slots block. cs2 reassigns observer_slot per round, so we
# can't compute this once â€” must read fresh each segment.
gsi_slot_for_steamid() {
  local target_sid="$1"
  if [ "$POV_STATE_FAST" = "1" ]; then
    local line _spect slot _rest
    line=$(spec_pov_state "$target_sid")
    IFS='|' read -r _spect slot _rest <<<"$line"
    printf '%s' "$slot"
    return
  fi
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" | node "$CLIP_HELPERS" slot-for-steamid "$target_sid"
}

# Dump the full GSI spec_slots table (slot/steamid/name + who's spectated)
# so wrong-POV cases are visible in the log.
log_spec_slots() {
  local label="$1" s line
  s=$(spec_get_state || true)
  if [ -z "$s" ]; then say "SLOTS [$label]: <no /demo/state>"; return; fi
  say "SLOTS [$label]:"
  printf '%s' "$s" | node "$CLIP_HELPERS" slots-dump | while IFS= read -r line; do
    say "    $line"
  done
}

# Lock cs2 onto a specific player and confirm via GSI. Uses the
# digit-key (slot) path because spec_player_by_accountid silently
# no-ops on demo playback (verified â€” command runs, GSI never updates).
# Returns 0 on confirmed lock, 1 if it never confirmed.
verify_spec_lock() {
  local target_sid="$1"
  local slot=""
  # Find slot â€” deadline-based (~2s, the old effective window once each
  # try paid a node spawn) in case GSI is between snapshots.
  local find_start=$SECONDS
  while :; do
    slot=$(gsi_slot_for_steamid "$target_sid")
    [ -n "$slot" ] && break
    [ $((SECONDS - find_start)) -ge 2 ] && break
    sleep 0.2
  done
  if [ -z "$slot" ]; then
    say "WARN target ${target_sid} is not in GSI spec_slots â€” POV lock skipped"
    return 1
  fi
  say "  pressing digit key for slot ${slot} -> ${target_sid}"
  spec_post /spec/slot "{\"slot\": ${slot}}"
  # Up to ~4s of polling at ~7Hz (the old 14-iter loop's effective span
  # once each poll paid a node spawn â€” kept so locks don't get LESS time
  # to confirm now that polls are cheap). cs2 GSI fires at ~10Hz so
  # 150ms gives the next tick a chance to land between polls.
  local current verify_start=$SECONDS
  while [ $((SECONDS - verify_start)) -lt 4 ]; do
    sleep 0.15
    current=$(gsi_spectated_steamid)
    if [ "$current" = "$target_sid" ]; then
      say "  POV verified via GSI: spectated=${current}"
      return 0
    fi
  done
  say "WARN POV did not verify â€” wanted=${target_sid} got='${current}' â€” re-pressing slot ${slot}"
  spec_post /spec/slot "{\"slot\": ${slot}}"
  verify_start=$SECONDS
  while [ $((SECONDS - verify_start)) -lt 4 ]; do
    sleep 0.15
    current=$(gsi_spectated_steamid)
    if [ "$current" = "$target_sid" ]; then
      say "  POV verified after retry: spectated=${current}"
      return 0
    fi
  done
  say "WARN POV still not locked to ${target_sid} (got '${current}') — proceeding anyway"
  return 1
}

# Wait until GSI reports at least one populated spec_slot. Cold demo
# loads sometimes start the segment loop before cs2 has emitted its
# first GSI frame â€” the very first spec lock then misses because the
# slot table is empty. Returns 0 when populated, 1 on timeout.
wait_for_gsi_slots() {
  # Deadline matches the old effective window (iters x ~0.4s incl. the
  # node spawn) so cold demo loads keep the same grace.
  local deadline_s=$(( (${1:-40} * 2) / 5 ))
  local start=$SECONDS slots line _a _b
  while [ $((SECONDS - start)) -lt "$deadline_s" ]; do
    if [ "$POV_STATE_FAST" = "1" ]; then
      line=$(spec_pov_state)
      IFS='|' read -r _a _b slots _ <<<"$line"
    else
      slots=$(spec_get_state 2>/dev/null \
        | node "$CLIP_HELPERS" state-slots 2>/dev/null || true)
    fi
    if [ -n "$slots" ] && [ "$slots" != "0" ]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# True if the captured mp4 has an audio stream that ffmpeg can read.
has_audio_stream() {
  local f="$1"
  ffprobe -v error -select_streams a -show_entries stream=codec_type \
    -of csv=p=0 "$f" 2>/dev/null | grep -q audio
}

# Resolve codec end-to-end before any segment runs â€” gst capture and
# ffmpeg concat/polish passes must all agree, otherwise re-encoded
# outputs can drift from captured segments. HEVC needs both NVENC paths
# (gst + ffmpeg); downgrade to h264 if either is missing.
CLIP_VIDEO_CODEC="${CLIP_VIDEO_CODEC:-h264}"
# yuv420p + high@4.2 are required for broad Safari/iOS/Android MP4 playback.
# The delivered encode. NVENC (p6/hq, spatial+temporal AQ, lookahead, B-frames as
# references) at a target bitrate around what the old libx264 veryfast/crf 22 made
# (~8-9Mbps, ~30MB for a 25s clip) — same size, cleaner, and about twice as fast.
# Constant quality 19 tripled the size without a visible difference. NVENC is checked
# with a tiny test encode; the old libx264 encode is the fallback.
# CLIP_FINAL_BITRATE / CLIP_FINAL_MAXRATE tune it; CLIP_FINAL_ENCODER=x264 forces libx264.
H264_X264_ARGS=(-c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -profile:v high -level 4.2)
H264_NVENC_ARGS=(-c:v h264_nvenc -preset p6 -tune hq -multipass qres -rc vbr
  -b:v "${CLIP_FINAL_BITRATE:-9M}" -maxrate "${CLIP_FINAL_MAXRATE:-14M}" -bufsize "${CLIP_FINAL_BUFSIZE:-18M}"
  -spatial-aq 1 -temporal-aq 1 -rc-lookahead 20 -bf 3 -b_ref_mode middle
  -pix_fmt yuv420p -profile:v high -level 4.2)
# True when ffmpeg can encode with these args on this node (driver, GPU, options).
# Bounded: a wedged driver must not hang the batch before STEP 1.
ffmpeg_venc_ok() {
  timeout 20 ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=gray:s=320x240:r=60 \
    -frames:v 8 "$@" -f null - >/dev/null 2>&1
}
# Which NVENC variant works on this node: "full", "nobref" (pre-Turing GPUs reject
# B-frames as references), or none. Each job is its own process, so the answer is
# kept in the pod's probe cache; only a working variant is cached (a failure may be
# transient).
_final_nvenc_pick() {
  _probe_cache_load GS_FINAL_NVENC && { printf '%s' "$GS_FINAL_NVENC"; return 0; }
  local nobref=() a skip=0
  for a in "${H264_NVENC_ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    [ "$a" = "-b_ref_mode" ] && { skip=1; continue; }
    nobref+=("$a")
  done
  if ffmpeg_venc_ok "${H264_NVENC_ARGS[@]}"; then GS_FINAL_NVENC=full
  elif ffmpeg_venc_ok "${nobref[@]}"; then GS_FINAL_NVENC=nobref
  else return 1
  fi
  export GS_FINAL_NVENC; _probe_cache_store GS_FINAL_NVENC
  printf '%s' "$GS_FINAL_NVENC"
}
FINAL_NVENC=""
[ "${CLIP_FINAL_ENCODER:-nvenc}" != "x264" ] && FINAL_NVENC=$(_final_nvenc_pick || true)
if [ "$FINAL_NVENC" = "nobref" ]; then
  _a=(); _skip=0
  for _x in "${H264_NVENC_ARGS[@]}"; do
    if [ "$_skip" = 1 ]; then _skip=0; continue; fi
    [ "$_x" = "-b_ref_mode" ] && { _skip=1; continue; }
    _a+=("$_x")
  done
  H264_NVENC_ARGS=("${_a[@]}"); unset _a _skip _x
fi
if [ -n "$FINAL_NVENC" ]; then
  H264_VENC_ARGS=("${H264_NVENC_ARGS[@]}")
  say "final encode: h264_nvenc p6/hq ${CLIP_FINAL_BITRATE:-9M} (max ${CLIP_FINAL_MAXRATE:-14M})$([ "$FINAL_NVENC" = nobref ] && echo ', no B-frame refs')"
else
  H264_VENC_ARGS=("${H264_X264_ARGS[@]}")
  say "final encode: libx264 veryfast crf 22 (h264_nvenc unavailable or CLIP_FINAL_ENCODER=x264)"
fi

# ffmpeg with the final encoder args (passed in-line as "${FFMPEG_VENC_ARGS[@]}"). If an
# NVENC encode fails mid-job (session limit, driver hiccup), switch this process to
# libx264 and run the same command again, instead of failing the clip.
# FFMPEG_NICE=<n> runs it under nice.
ffmpeg_venc() {
  local pre=() ; [ -n "${FFMPEG_NICE:-}" ] && pre=(nice -n "$FFMPEG_NICE")
  "${pre[@]}" ffmpeg "$@" && return 0
  [ "${FFMPEG_VENC_ARGS[1]:-}" = "h264_nvenc" ] || return 1
  local args=("$@") n=${#FFMPEG_VENC_ARGS[@]} i j match out=()
  for ((i = 0; i < ${#args[@]}; i++)); do
    match=1
    for ((j = 0; j < n; j++)); do
      [ "${args[i+j]:-}" = "${FFMPEG_VENC_ARGS[j]}" ] || { match=0; break; }
    done
    if [ "$match" = 1 ]; then
      out+=("${H264_X264_ARGS[@]}"); i=$((i + n - 1))
    else
      out+=("${args[i]}")
    fi
  done
  say "WARN final encode: h264_nvenc failed — retrying with libx264"
  FFMPEG_VENC_ARGS=("${H264_X264_ARGS[@]}")
  "${pre[@]}" ffmpeg "${out[@]}"
}
case "$CLIP_VIDEO_CODEC" in
  h265|hevc)
    GST_H265_OK=0
    FFMPEG_H265_OK=0
    if h265_available; then
      GST_H265_OK=1
      say "h265 probe: gstreamer NVENC HEVC OK (pick=${GS_NVENC_PICK_H265:-?})"
    else
      say "h265 probe: gstreamer NVENC HEVC unavailable (no nvcudah265enc/nvh265enc element on this pod)"
    fi
    FFMPEG_HEVC_LINE=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E '\bhevc_nvenc\b' || true)
    if [ -n "$FFMPEG_HEVC_LINE" ]; then
      FFMPEG_H265_OK=1
      say "h265 probe: ffmpeg hevc_nvenc OK ($(printf '%s' "$FFMPEG_HEVC_LINE" | awk '{$1=$1};1'))"
    else
      say "h265 probe: ffmpeg hevc_nvenc NOT FOUND in 'ffmpeg -encoders' (this build was compiled without NVENC HEVC)"
    fi
    if [ "$GST_H265_OK" = "1" ] && [ "$FFMPEG_H265_OK" = "1" ]; then
      FFMPEG_VENC_ARGS=(-c:v hevc_nvenc -preset p5 -rc vbr -cq 24 -tag:v hvc1)
      CLIP_VIDEO_CODEC=h265
      say "h265 selected for this render"
    else
      say "h265 requested but unavailable (gst_ok=${GST_H265_OK} ffmpeg_ok=${FFMPEG_H265_OK}) â€” using h264 for this render"
      CLIP_VIDEO_CODEC=h264
      FFMPEG_VENC_ARGS=("${H264_VENC_ARGS[@]}")
    fi
    ;;
  *)
    CLIP_VIDEO_CODEC=h264
    FFMPEG_VENC_ARGS=("${H264_VENC_ARGS[@]}")
    ;;
esac
export CLIP_VIDEO_CODEC

# Parse segments + compute total duration for progress weighting.
SEG_COUNT=$(printf '%s' "$CLIP_SEGMENTS" | node "$CLIP_HELPERS" segs-count)
if [ "$SEG_COUNT" -lt 1 ]; then
  die_failed "CLIP_SEGMENTS contains zero segments"
fi
TOTAL_DURATION_TICKS=$(printf '%s' "$CLIP_SEGMENTS" \
  | node "$CLIP_HELPERS" segs-total-ticks)

say "============================================================"
say "segments=${SEG_COUNT}  total_ticks=${TOTAL_DURATION_TICKS}  output=${CLIP_OUTPUT_DIMS:-?}@${CLIP_OUTPUT_FPS:-?}"
say "============================================================"

# Pre-render cancel check. The user (or admin) can hit cancel on a
# queued/in-flight clip while we're still booting cs2 / processing
# the previous batch entry; the api flips status='cancelled' and we
# read it back here. Skipping cleanly with exit 0 keeps batch-mode
# moving to the next clip without an error log.
api_check_status() {
  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       "${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status" \
    || echo ""
}
PRE_STATUS_RAW=$(api_check_status)
PRE_STATUS=$(printf '%s' "$PRE_STATUS_RAW" | node "$CLIP_HELPERS" status-field)
if [ "$PRE_STATUS" = "cancelled" ]; then
  say "job already cancelled by user â€” skipping (no work, no error)"
  CLIP_REACHED_TERMINAL=1
  exit 0
fi

api_status "status=rendering" "progress=0.02"

say "STEP 1: snapshot"
STATE_JSON=$(spec_get_state || true)
if [ -z "$STATE_JSON" ]; then
  die_failed "spec-server /demo/state unreachable"
fi
SAVED_TICK=$(printf '%s' "$STATE_JSON" | node "$CLIP_HELPERS" state-tick)
SAVED_PAUSED=$(printf '%s' "$STATE_JSON" | node "$CLIP_HELPERS" state-paused)
[ "$SAVED_TICK" = "?" ] && SAVED_TICK=0
say "STEP 1: tick=$SAVED_TICK paused=$SAVED_PAUSED"
api_status "status=rendering" "progress=0.05"

# Disable cs2's built-in auto-director. It auto-follows kills, so it
# yanks the camera off our locked POV right as a segment opens on a frag,
# fighting our slot lock (the POV flickers back and forth). Sent via exec
# rather than the F5 bind because batch mode skips hud-manager, which is
# what binds F5 -> spec_autodirector 0. The cvar persists across seeks,
# so once before the segment loop is enough.
say "STEP 1b: disable cs2 auto-director (spec_autodirector 0)"
# host_framerate 0: a job killed mid-segment can't leave cs2 on a fixed timestep
# through this job's seeks and lead-ins (it's only set while a segment records).
spec_post /demo/exec '{"cmd": "spec_autodirector 0; host_framerate 0"}'

# Fixed timestep / grid pacing (CLIP_FIXED_TIMESTEP / CLIP_PACE): the capture layer paces cs2 to exactly the output rate
# while recording, so fps_max only needs headroom above it (run-demo.sh sets 2x).
# Without it cs2 should render at the capture rate: above it captured frames land one
# or two renders apart and motion steps unevenly. The cap is set at launch
# (run-demo.sh) because cs2 ignores a runtime fps_max.
if [ "${CLIP_FIXED_TIMESTEP:-0}" = "1" ]; then
  say "STEP 1c: fixed timestep — host_framerate ${CLIP_OUTPUT_FPS:-60} + layer pacing while recording (fps_max ${CS2_FPS_MAX:-?})"
elif [ "${CLIP_PACE:-1}" = "1" ]; then
  say "STEP 1c: grid pacing — layer paces to ${CLIP_OUTPUT_FPS:-60}fps while recording, game clock untouched (fps_max ${CS2_FPS_MAX:-?})"
elif [ "${CS2_FPS_MAX:-}" = "${CLIP_OUTPUT_FPS:-60}" ]; then
  say "STEP 1c: render cap fps_max ${CS2_FPS_MAX} matches output"
else
  say "STEP 1c: WARN render cap fps_max ${CS2_FPS_MAX:-?} != output ${CLIP_OUTPUT_FPS:-60}fps — expect uneven motion"
fi

DEMO_TOTAL_TICKS_FOR_GUARD="${CLIP_DEMO_TOTAL_TICKS:-}"
if [ -z "$DEMO_TOTAL_TICKS_FOR_GUARD" ]; then
  DEMO_TOTAL_TICKS_FOR_GUARD=$(printf '%s' "$STATE_JSON" | node "$CLIP_HELPERS" state-total-ticks)
fi
case "$DEMO_TOTAL_TICKS_FOR_GUARD" in
  ''|*[!0-9]*) DEMO_TOTAL_TICKS_FOR_GUARD="" ;;
esac
if [ -z "$DEMO_TOTAL_TICKS_FOR_GUARD" ] && [ -s "$ROUND_TICKS_PATH" ]; then
  DEMO_TOTAL_TICKS_FOR_GUARD=$(node "$CLIP_HELPERS" rounds-last-end-tick "$ROUND_TICKS_PATH" 2>/dev/null || true)
  case "$DEMO_TOTAL_TICKS_FOR_GUARD" in
    ''|*[!0-9]*) DEMO_TOTAL_TICKS_FOR_GUARD="" ;;
    *) say "MATCH_END_GUARD inferred total_ticks=${DEMO_TOTAL_TICKS_FOR_GUARD} from $ROUND_TICKS_PATH" ;;
  esac
fi
MATCH_END_GUARD_SECONDS="${CLIP_MATCH_END_GUARD_SECONDS:-6}"
MATCH_END_GUARD_TICKS=$(awk -v s="$MATCH_END_GUARD_SECONDS" -v r="${CLIP_TICK_RATE:-64}" \
  'BEGIN{printf "%d", s * r}')
say "MATCH_END_GUARD total_ticks=${DEMO_TOTAL_TICKS_FOR_GUARD:-?} guard=${MATCH_END_GUARD_SECONDS}s"

LIVE_CAPTURE_STOPPED=0
if [ -n "${MATCH_ID:-}" ]; then
  say "STEP 1a: stop live capture for $MATCH_ID"
  stop_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=1
fi

# CLIP_BAKE_BRANDING=1 enables the player chip + outro. Default off.
BRANDING_ENABLED="${CLIP_BAKE_BRANDING:-1}"
say "BRANDING enabled=${BRANDING_ENABLED}"

# Player chip overlay â€” rendered once per job by the Remotion
# composition at motion/src/PlayerChip.tsx, then composited onto each
# captured segment via ffmpeg overlay during the polish pass. Mirrors
# the bottom-left chip on web/components/clips/ClipPlayer.vue.
CHIP_NAME=""
CHIP_AVATAR=""
CHIP_KILLS=0
CHIP_MAP=""
CHIP_ROUND=""
CHIP_MOV=""
if [ "$BRANDING_ENABLED" = "1" ] && [ "${CLIP_DISABLE_CHIP:-0}" != "1" ]; then
  CHIP_NAME="${CLIP_DISPLAY_NAME:-}"
  # "Player NNNN" is the api's fallback when no real name was known.
  # Try GSI for a real in-game name before giving up on the placeholder.
  if { [ -z "$CHIP_NAME" ] || printf '%s' "$CHIP_NAME" | grep -qE '^Player [0-9]+$'; } && [ -n "${CLIP_DISPLAY_TARGET_STEAMID:-}" ]; then
    GSI_NAME=$(printf '%s' "$STATE_JSON" \
      | node "$CLIP_HELPERS" name-for-steamid "$CLIP_DISPLAY_TARGET_STEAMID")
    if [ -n "$GSI_NAME" ]; then CHIP_NAME="$GSI_NAME"; fi
  fi
  CHIP_AVATAR="${CLIP_DISPLAY_AVATAR:-}"
  CHIP_KILLS=$(printf '%s' "${CLIP_DISPLAY_KILLS:-}" \
    | awk '{n=int($1); if (n>0) printf "%d", n; else printf "0"}')
  CHIP_MAP="${CLIP_DISPLAY_MAP:-}"
  CHIP_ROUND="${CLIP_DISPLAY_ROUND:-}"
fi

CHIP_OUT_W="${CLIP_OUTPUT_DIMS%x*}"
CHIP_OUT_H="${CLIP_OUTPUT_DIMS#*x}"
[ -z "$CHIP_OUT_W" ] && CHIP_OUT_W=1920
[ -z "$CHIP_OUT_H" ] && CHIP_OUT_H=1080
CHIP_OUT_FPS="${CLIP_OUTPUT_FPS:-60}"

# Chip is ProRes 4444 because this ffmpeg's libvpx-vp9 silently
# strips alpha on webm; ProRes 4444 is the reliable transparent
# intermediate and encodes faster anyway.
MOTION_DIR="${MOTION_DIR:-/opt/game-streamer/motion}"
if [ -n "$CHIP_NAME" ] && [ ! -d "$MOTION_DIR" ]; then
  say "WARN motion project missing at $MOTION_DIR â€” skipping chip"
fi
CHIP_RENDER_PID=""
CHIP_RENDER_LOG=""
if [ -n "$CHIP_NAME" ] && [ -d "$MOTION_DIR" ]; then
  CHIP_MOV="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/${CLIP_RENDER_JOB_ID}-chip.mov"
  CHIP_RENDER_LOG="${CHIP_MOV}.log"
  mkdir -p "$(dirname "$CHIP_MOV")"
  CHIP_PROPS=$(CHIP_NAME="$CHIP_NAME" \
               CHIP_AVATAR="$CHIP_AVATAR" \
               CHIP_KILLS="$CHIP_KILLS" \
               CHIP_MAP="$CHIP_MAP" \
               CHIP_ROUND="$CHIP_ROUND" \
               CHIP_OUT_W="$CHIP_OUT_W" \
               CHIP_OUT_H="$CHIP_OUT_H" \
               CHIP_OUT_FPS="$CHIP_OUT_FPS" \
               node -e 'const r = Number(process.env.CHIP_ROUND);
                        process.stdout.write(JSON.stringify({
                          name: process.env.CHIP_NAME,
                          avatarUrl: process.env.CHIP_AVATAR || null,
                          kills: Number(process.env.CHIP_KILLS) || 0,
                          map: process.env.CHIP_MAP || null,
                          round: Number.isFinite(r) && r >= 0 ? Math.floor(r) : null,
                          width: Number(process.env.CHIP_OUT_W),
                          height: Number(process.env.CHIP_OUT_H),
                          fps: Number(process.env.CHIP_OUT_FPS),
                        }))')
  # Don't launch the heavy Remotion/Chromium render here â€” defer it (see
  # start_chip_render) so it doesn't compete with cs2 during capture.
  CHIP_READY_TO_RENDER=1
fi

# Launch the player-chip render (Remotion/headless Chromium â†’ transparent ProRes
# .mov). Headless Chromium is heavy + multi-threaded, so:
#  - It runs AFTER recording for the fused path (the common case) â€” zero overlap
#    with capture, called post-segment-loop. This was the seg0-tail jitter: an
#    unpinned Chromium render overlapping seg0 preempted cs2 right before the switch.
#  - The non-fused path bakes the chip per-segment mid-loop, so it MUST launch
#    before the loop; there it's pinned to the capture cores + nice 19 (never touches
#    cs2's render cores 0-9; below the capture consumer). Affinity+nice are inherited
#    by the Chromium children.
#  - After recording (start_chip_render after), nothing is capturing and cs2 sits
#    paused, so it runs on every core. Pinned to the 2 capture cores it took ~47s per
#    clip, all of it dead time before STEP 9.
# Idempotent — launches at most once per job (CHIP_LAUNCHED guard).
start_chip_render() {
  [ "${CHIP_READY_TO_RENDER:-0}" = "1" ] || return 0
  [ "${CHIP_LAUNCHED:-0}" = "1" ] && return 0
  CHIP_LAUNCHED=1
  local pin=() niceness=19
  if [ "${1:-}" = after ]; then
    niceness=5
    say "CHIP: rendering for '${CHIP_NAME}' (recording done — all cores, nice ${niceness})"
  else
    compute_cpu_split
    if [ -n "${GS_CAPTURE_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
      pin=(taskset -c "$GS_CAPTURE_CPUS")
    fi
    say "CHIP: rendering for '${CHIP_NAME}' (pinned ${GS_CAPTURE_CPUS:-none} + nice ${niceness})"
  fi
  (
    cd "$MOTION_DIR" && \
    "${pin[@]}" nice -n "$niceness" \
    node node_modules/.bin/remotion render \
        src/index.ts PlayerChip "$CHIP_MOV" \
        --codec=prores --prores-profile=4444 \
        --pixel-format=yuva444p10le --image-format=png \
        --log=error \
        --props="$CHIP_PROPS"
  ) >"$CHIP_RENDER_LOG" 2>&1 &
  CHIP_RENDER_PID=$!
}

wait_for_chip_render() {
  [ -z "$CHIP_RENDER_PID" ] && return 0
  if ! wait "$CHIP_RENDER_PID"; then
    say "WARN chip render failed â€” continuing without chip overlay"
    [ -n "$CHIP_RENDER_LOG" ] && [ -s "$CHIP_RENDER_LOG" ] \
      && sed 's/^/  chip: /' "$CHIP_RENDER_LOG" >&2
    rm -f "$CHIP_MOV"
    CHIP_MOV=""
  fi
  rm -f "$CHIP_RENDER_LOG"
  CHIP_RENDER_PID=""
}

CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
CLIP_THUMB_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.jpg"
rm -f "$CLIP_OUT_FILE" "$CLIP_THUMB_FILE"

OUTRO_CACHE_DIR="${OUTRO_CACHE_DIR:-$CLIP_OUT_DIR/.outro-cache}"

# Cache path for the encoder-matched outro, keyed on everything that changes its
# bytes — source file identity, encoder args, fps — so a codec/tier switch on a
# later clip can never reuse a mismatched file.
matched_outro_cache_path() {
  mkdir -p "$OUTRO_CACHE_DIR" || return 1
  local stamp key
  stamp=$(stat -c '%s:%Y' "$OUTRO_FILE" 2>/dev/null || echo '?')
  key=$(printf '%s|%s|%s|%s' \
          "$OUTRO_FILE" "$stamp" "${FFMPEG_VENC_ARGS[*]}" "${CLIP_OUTPUT_FPS:-60}" \
        | md5sum | cut -c1-12)
  printf '%s/outro-%s.mp4\n' "$OUTRO_CACHE_DIR" "$key"
}

# Precompute: will an outro be appended at concat time? If yes AND we
# would have run a per-segment chip-overlay pass, we can fuse both into
# a single ffmpeg encode at the end â€” eliminating
# one full 1080p60 NVENC pass per clip. The polish-skip gate below
# reads OUTRO_WILL_APPEND; the fused encode reads it at concat time.
OUTRO_WILL_APPEND=0
OUTRO_FUSED_FILE=""
if [ "$BRANDING_ENABLED" = "1" ] && [ "${CLIP_DISABLE_OUTRO:-0}" != "1" ]; then
  OUTRO_DIMS_PRE="${CLIP_OUTPUT_DIMS:-1920x1080}"
  OUTRO_FPS_PRE="${CLIP_OUTPUT_FPS:-60}"
  OUTRO_FUSED_FILE="${OUTRO_DIR:-/opt/game-streamer/resources/video}/outro_${OUTRO_DIMS_PRE}_${OUTRO_FPS_PRE}.mp4"
  if [ -f "$OUTRO_FUSED_FILE" ]; then
    OUTRO_WILL_APPEND=1
  fi
fi
# The fused path overlays the chip via a single filter_complex that
# `split`s the chip into one branch per captured segment and feeds them
# all into one `concat`. split-fan-out â†’ concat deadlocks ffmpeg once the
# branch count gets high â€” it stalls mid-encode with no error (small clips
# are fine, large montages hang). Cap the fuse to small clips; larger ones
# fall back to per-segment chip polish (a split-free single-overlay graph)
# plus a split-free concat.
CLIP_MAX_FUSED_SEGMENTS="${CLIP_MAX_FUSED_SEGMENTS:-6}"
WILL_FUSE_POLISH_OUTRO=0
if [ "$OUTRO_WILL_APPEND" = "1" ] \
   && [ -n "$CHIP_NAME" ] \
   && [ "$SEG_COUNT" -le "$CLIP_MAX_FUSED_SEGMENTS" ]; then
  WILL_FUSE_POLISH_OUTRO=1
elif [ "$OUTRO_WILL_APPEND" = "1" ] && [ -n "$CHIP_NAME" ]; then
  say "concat: ${SEG_COUNT} segments exceeds fuse cap ${CLIP_MAX_FUSED_SEGMENTS} â€” per-segment polish + split-free concat"
fi

# Non-fused path bakes the chip per-segment INSIDE the capture loop, so it has to
# render before the loop (pinned+niced off cs2's cores). The fused path consumes
# the chip only at the final concat â†’ it's deferred to after recording (post-loop
# start_chip_render below) so Chromium never overlaps capture at all.
[ "$WILL_FUSE_POLISH_OUTRO" != "1" ] && start_chip_render

# Per-segment output paths + concat list. We render each segment to
# its own file and let ffmpeg concat-demux glue them â€” this keeps each
# capture session independent (a stall in one doesn't ruin the rest)
# and lets us drop a bad segment without losing the rest of the clip.
SEG_DIR="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.segs"
mkdir -p "$SEG_DIR"
rm -f "$SEG_DIR"/*.mp4 "$SEG_DIR/concat.txt" 2>/dev/null || true
: >"$SEG_DIR/concat.txt"

# Per-segment polish runs in the BACKGROUND so its ~5-8s NVENC encode
# overlaps the NEXT segment's seek+capture instead of sitting between
# them. Concurrency is exactly 1 (reap previous before spawning next):
# capture holds one NVENC session and the GTX 980 limit is 2.
# CLIP_POLISH_OVERLAP=0 reaps immediately after spawn (serial behavior).
# concat.txt is written AFTER the loop from CONCAT_ENTRY (index order) â€”
# it isn't read until then, and entries are recorded before the polish
# that rewrites the file in place has finished.
CLIP_POLISH_OVERLAP="${CLIP_POLISH_OVERLAP:-1}"
# 1 while every valid segment has gone through the per-segment polish
# (one uniform encoder invocation) â€” the precondition for the
# stream-copy concat fast path below.
COPY_ELIGIBLE=1
declare -a CONCAT_ENTRY=()
POLISH_BG_PID=""
POLISH_BG_IDX=""
POLISH_BG_LOG=""
reap_polish_bg() {
  [ -z "$POLISH_BG_PID" ] && return 0
  local rc=0
  wait "$POLISH_BG_PID" || rc=$?
  local idx="$POLISH_BG_IDX" log="$POLISH_BG_LOG"
  POLISH_BG_PID=""; POLISH_BG_IDX=""; POLISH_BG_LOG=""
  if [ -n "$log" ] && [ -s "$log" ]; then
    sed "s/^/  polish[$idx]: /" "$log" >&2
  fi
  rm -f "$log"
  if [ "$rc" -ne 0 ]; then
    die_failed "ffmpeg polish pass failed (segment $idx)"
  fi
}

# Render-phase progress 0..1 (web shows render + upload as separate
# bars; upload is pulse-only since the curl POST has no readback).
# Computed in the capture loop as 0.05 base + 0.95 span, x1000 integer math.
ELAPSED_TICKS_TOTAL=0

# Explicit index (not a `for` over seq) so an empty vkcapture segment can redo
# the SAME index once after falling back to ximagesrc (see validation below).
SEG_IDX=0
VKCAP_FELL_BACK=0
VKCAP_RETRY_SEG=""        # segment being redone on ximagesrc after a one-off failure
VKCAP_ONE_OFF_FAILS=0     # those one-off failures so far (capped, then the job stays on ximagesrc)
# Parse the segment table once (one node spawn) instead of 3x per
# segment iteration. POV accountid = steamid64 - 76561197960265728;
# the lock is applied AFTER seeking + lead-in so the freshly-seeked
# target gets overridden â€” otherwise the clip opens on whoever cs2 was
# last spectating, producing the wrong POV.
declare -a SEG_STARTS=() SEG_ENDS=() SEG_POVS=() SEG_KILLS=()
while IFS='|' read -r _s _e _a _k; do
  SEG_STARTS+=("$_s"); SEG_ENDS+=("$_e"); SEG_POVS+=("$_a"); SEG_KILLS+=("$_k")
done < <(printf '%s' "$CLIP_SEGMENTS" | node "$CLIP_HELPERS" segs-table)

# Snapshot console.log size before any seek so we only match a fatal from this render.
CS2_LOG_OFFSET=$(wc -c < "${CS2_DIR}/game/csgo/console.log" 2>/dev/null || echo 0)
CS2_LOG_OFFSET="${CS2_LOG_OFFSET//[!0-9]/}"; CS2_LOG_OFFSET="${CS2_LOG_OFFSET:-0}"

# Pre-compile cs2's Vulkan pipelines before the first real capture. The FIRST
# segment of a cs2 process renders cold â€” pipelines compile on first encounter,
# stalling the render thread so presents/s collapses (GPU+CPU idle during the dip);
# once compiled they stay warm for the whole process. Steam's Fossilize precache
# (10GiB on disk) does NOT cover these demo-POV pipelines, so the only cure is to
# draw the footage once. We replay each segment's range ONCE — fast and uncaptured —
# and leave the playhead there. Runs BEFORE STEP 2 deliberately: STEP 3's seek back
# to the pre-roll is then a backward seek, and cs2 stalls ~2s after a backward seek
# ([[seek stall]]); the full STEP 2/3/4 lead-in absorbs that stall before capture.
# (Running it after the POV lock instead put the backward seek immediately before
# capture and wrecked the whole segment — do not move it.) Every segment gets its
# own pass: warming only the first left later segments compiling live — the same
# kill in segment 2 held ~0.5s of frames (cs2 ~1000% CPU, GPU ~30%) on every run.
# The marker lists the tick ranges already warmed for this cs2 (one cs2 serves the
# whole batch); a range inside one of them is skipped. CLIP_WARMUP_ONCE=1 warms
# only the first segment, as before.
# On by default (CLIP_WARMUP=0 disables): with the warm-up off, the first segment of
# a pod rendered at ~25fps for ~7s while cs2 compiled pipelines on every core (CPU
# ~1000%, GPU idle) — the 2s pre-roll can't absorb that. After the replay it also
# waits for cs2's CPU to settle (the compile queue draining), up to
# CLIP_WARMUP_SETTLE_MS. CLIP_WARMUP_RATE sets the speed (lower = more thorough).
WARM_MARKER="${CLIP_WARMUP_MARKER:-/tmp/game-streamer/.pipelines-warmed}"

# Wait (bounded) for cs2's pipeline compiles to drain: while it compiles, cs2 burns
# most cores; paused and idle it sits around 100-200%.
warmup_wait_compile() {
  local cap="${CLIP_WARMUP_SETTLE_MS:-12000}" cs2_pid hz a b pct=0 waited=0
  # By process name: a full-cmdline match can hit a launcher/wrapper carrying cs2's path.
  cs2_pid=$(pgrep -x cs2 | head -1)
  [ -n "$cs2_pid" ] || return 0
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  while [ "$waited" -lt "$cap" ]; do
    a=$(awk '{print $14+$15}' "/proc/$cs2_pid/stat" 2>/dev/null) || return 0
    sleep 0.5
    b=$(awk '{print $14+$15}' "/proc/$cs2_pid/stat" 2>/dev/null) || return 0
    waited=$((waited + 500))
    pct=$(( (b - a) * 200 / hz ))   # % of one core over the 0.5s window
    if [ "$pct" -lt "${CLIP_WARMUP_SETTLE_CPU:-400}" ]; then
      say "WARM-UP: compiles settled (cs2 at ${pct}% CPU) after ${waited}ms"
      return 0
    fi
  done
  say "WARM-UP: cs2 still busy (${pct}% CPU) after ${cap}ms — continuing"
}
warm_pipelines_if_cold() {
  local start="$1" dur_ms="$2" end
  [ "${CLIP_WARMUP:-1}" = "1" ] || return 0
  [ "${CLIP_WARMUP_ONCE:-0}" = "1" ] && [ -s "$WARM_MARKER" ] && return 0
  end=$(( start + dur_ms * ${CLIP_TICK_RATE:-64} / 1000 ))
  if [ -f "$WARM_MARKER" ] && awk -v s="$start" -v e="$end" \
       '$1 <= s && $2 >= e { found=1 } END { exit !found }' "$WARM_MARKER"; then
    return 0
  fi
  local rate="${CLIP_WARMUP_RATE:-4}"
  [ "$rate" -lt 1 ] 2>/dev/null && rate=1
  # Demo time to play: the range plus a margin for compile stalls (2s of wall time at
  # $rate). Never past the match-end guard: running into gameover here, uncaptured,
  # makes cs2 close the demo and fails this job and every later one in the batch.
  local play_ms=$(( dur_ms + 2000 * rate )) tick_rate="${CLIP_TICK_RATE:-64}"
  if [ -n "${DEMO_TOTAL_TICKS_FOR_GUARD:-}" ] && [ "${DEMO_TOTAL_TICKS_FOR_GUARD:-0}" -gt 0 ]; then
    local room_ms=$(( (DEMO_TOTAL_TICKS_FOR_GUARD - ${MATCH_END_GUARD_TICKS:-0} - start) * 1000 / tick_rate ))
    if [ "$room_ms" -lt 1000 ]; then
      say "WARM-UP: skipped — ticks ${start}-${end} are within the match-end guard"
      return 0
    fi
    [ "$play_ms" -gt "$room_ms" ] && play_ms=$room_ms
  fi
  local wait_ms=$(( play_ms / rate ))
  # In-world warm only: fast-forward the range so the in-world pipelines (map,
  # effects) compile before the real capture clears the cold opening. We do NOT
  # POV-lock for the first-person viewmodel: deferring the chip render off the
  # capture window (start_chip_render) removed the seg0 stutter, so the viewmodel
  # was never the bottleneck â€” and locking here races the round-transition roster
  # (verify_spec_lock then burns ~8s retrying a stale slot for no gain).
  say "WARM-UP: pre-compiling pipelines — replaying ticks ${start}-${end} (${dur_ms}ms) at ${rate}x (~${wait_ms}ms, uncaptured)"
  spec_post /demo/pause  '{"force": true}'
  spec_post /demo/seek   "{\"tick\": ${start}}"
  # /demo/seek only queues the gototick, and from a pause it lands paused: a toggle
  # sent before it lands gets undone, so the range never played (nothing warmed).
  local settled=1
  wait_seek_settled "WARM-UP seek" || settled=0
  spec_post /demo/speed  "{\"rate\": ${rate}}"
  spec_post /demo/toggle '{}'                  # play through the range fast
  sleep "$(awk -v ms="$wait_ms" 'BEGIN{printf "%.2f", ms/1000}')"
  spec_post /demo/pause  '{"force": true}'
  spec_post /demo/speed  '{"rate": 1}'
  warmup_wait_compile
  # No seek back: STEP 3 seeks to the segment's pre-roll next anyway, and a seek to
  # the tick cs2 is already parked on never shows a GSI change, so it can't settle.
  # Only record the range if the seek landed: a toggle sent before it lands is undone,
  # so nothing played and the next segment over this range should warm it again.
  if [ "$settled" = 1 ]; then
    mkdir -p "$(dirname "$WARM_MARKER")" 2>/dev/null || true
    echo "$start $end" >> "$WARM_MARKER"
    say "WARM-UP: done — ticks ${start}-${end} warmed"
  else
    say "WARM-UP: seek never settled — ticks ${start}-${end} not marked warm"
  fi
}

# Re-press POV after play: the re-seek reset it and the pre-play re-press no-ops
# while paused. observer_slot may also have shifted. Verify via GSI like STEP 4b
# instead of a fire-and-forget spec_post -- a silently missed re-press here is
# what caused the wrong-POV ("mouse bug") clips.
repress_pov_after_play() {
  [ -n "${SEG_POV_STEAMID:-}" ] || return 0
  verify_spec_lock "$SEG_POV_STEAMID" || true
  say "STEP 5: after re-lock, GSI spectated=$(gsi_spectated_steamid)"
}

while [ "$SEG_IDX" -lt "$SEG_COUNT" ]; do
  SEG_START="${SEG_STARTS[$SEG_IDX]:-0}"
  SEG_END="${SEG_ENDS[$SEG_IDX]:-0}"
  SEG_POV_ACCOUNTID="${SEG_POVS[$SEG_IDX]:-}"
  SEG_MATCH_END_GUARDED=0
  if [ -n "$DEMO_TOTAL_TICKS_FOR_GUARD" ] \
     && [ "$DEMO_TOTAL_TICKS_FOR_GUARD" -gt 0 ] \
     && [ "$SEG_END" -ge $((DEMO_TOTAL_TICKS_FOR_GUARD - MATCH_END_GUARD_TICKS)) ]; then
    SEG_MATCH_END_GUARDED=1
    say "MATCH_END_GUARD segment $SEG_IDX: armed (runtime gameover detection) â€” end=${SEG_END} total=${DEMO_TOTAL_TICKS_FOR_GUARD}"
  fi
  SEG_TICKS=$((SEG_END - SEG_START))
  if [ "$SEG_TICKS" -le 0 ]; then
    say "WARN segment $SEG_IDX: invalid ticks start=${SEG_START} end=${SEG_END} â€” dropping segment"
    SEG_IDX=$((SEG_IDX + 1)); continue
  fi
  SEG_DURATION_MS=$(awk -v t="$SEG_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
    'BEGIN{printf "%d", t / r * 1000}')
  SEG_FILE="${SEG_DIR}/seg-$(printf '%03d' "$SEG_IDX").mp4"
  say "------- SEGMENT $((SEG_IDX + 1))/${SEG_COUNT}: ticks=${SEG_START}..${SEG_END} (${SEG_DURATION_MS}ms)"

  # Expected pre-kill lead, so the "KILL seg$N ... ms of demo time into the clip" line below can
  # be compared against what the API actually asked for instead of eyeballed.
  SEG_KILL_TICK="${SEG_KILLS[$SEG_IDX]:-}"
  SEG_LEAD_MS=""
  if [ -n "$SEG_KILL_TICK" ] && [ "$SEG_KILL_TICK" -gt "$SEG_START" ] 2>/dev/null; then
    SEG_LEAD_MS=$(awk -v t="$((SEG_KILL_TICK - SEG_START))" -v r="${CLIP_TICK_RATE:-64}" \
      'BEGIN{printf "%d", t / r * 1000}')
    say "  expected pre-kill lead: ${SEG_LEAD_MS}ms (kill_tick=${SEG_KILL_TICK})"
  fi

  # Warm this segment's Vulkan pipelines, BEFORE the seek/lead-in, so the warm's
  # backward seek is absorbed by STEP 2/3/4 before capture (see the function note).
  warm_pipelines_if_cold "$SEG_START" "$SEG_DURATION_MS"

  # Seek to SEG_PRE and play the pre-roll behind the closed start gate (vkcapture only;
  # ximagesrc records from spawn, so it seeks straight to SEG_START as before).
  SEG_PRE=$SEG_START
  SEG_PREROLL_MS=0
  if [ "${CLIP_PREROLL_MS:-0}" -gt 0 ] && [ "${CLIP_CAPTURE_METHOD:-vkcapture}" = "vkcapture" ] \
     && [ "$VKCAP_FELL_BACK" = "0" ]; then
    SEG_PRE=$(awk -v s="$SEG_START" -v ms="$CLIP_PREROLL_MS" -v r="${CLIP_TICK_RATE:-64}" \
      'BEGIN{p=int(s - ms / 1000 * r); printf "%d", (p < 0 ? 0 : p)}')
    SEG_PREROLL_MS=$(awk -v t="$((SEG_START - SEG_PRE))" -v r="${CLIP_TICK_RATE:-64}" \
      'BEGIN{printf "%d", t / r * 1000}')
  fi

  say "STEP 2: force-pause"
  spec_post /demo/pause '{"force": true}'
  say "STEP 3: seek to $SEG_PRE (segment starts $SEG_START, pre-roll ${SEG_PREROLL_MS}ms)"
  spec_post /demo/seek "{\"tick\": ${SEG_PRE}}"
  wait_seek_settled "STEP 3" || true

  # Lead-in: unpause so cs2 processes the seek + the spec lock (spec
  # commands no-op while paused). toggle reliably flips state; demo_resume
  # did not unpause on this build, which is why every POV lock missed.
  say "STEP 4: lead-in (toggle play)"
  spec_post /demo/toggle '{}'
  sleep 0.6

  # Cold boot: GSI slot table can be empty, so the first lock misses.
  if [ "$SEG_IDX" = "0" ] && [ -n "$SEG_POV_ACCOUNTID" ]; then
    wait_for_gsi_slots 40 || say "WARN GSI spec_slots empty â€” first POV may miss"
  fi

  if [ -n "$SEG_POV_ACCOUNTID" ]; then
    SEG_POV_STEAMID=$((SEG_POV_ACCOUNTID + 76561197960265728))
    say "STEP 4b: WANT accountid=${SEG_POV_ACCOUNTID} steamid=${SEG_POV_STEAMID}"
    log_spec_slots "before-lock"
    verify_spec_lock "$SEG_POV_STEAMID" || true
    say "STEP 4b: after lock, GSI spectated=$(gsi_spectated_steamid)"
  fi

  # Re-pause + re-seek for a deterministic SEG_PRE (lead-in drifted
  # forward). The re-seek resets cs2's POV, so we re-press the slot below.
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SEG_PRE}}"
  # Never record at an inherited timescale — stale 2x/4x = double-speed clips.
  spec_post /demo/speed '{"rate": 1}'
  # The lead-in above played for 0.6s + the POV lock's polling, so this is a
  # backward seek. Everything below (capture spawn, play, wall-clock billing)
  # assumes the playhead is at SEG_PRE, so wait for it — but only briefly: it lands
  # in 0.9-1.9s, and when the lead-in barely moved (cs2 stalls ~2s after STEP 3's
  # backward seek, the case for every segment once the warm-up has run past it)
  # GSI shows no change and it never reports settled, which burned the full 8s.
  wait_seek_settled "STEP 4d re-seek" "${CLIP_RESEEK_SETTLE_TIMEOUT_MS:-3000}" || true
  sleep 0.2

  # Re-press slot before capture (re-seek reset POV); queued for play.
  if [ -n "${SEG_POV_STEAMID:-}" ]; then
    POV_SLOT_AFTER_SEEK=$(gsi_slot_for_steamid "$SEG_POV_STEAMID")
    say "STEP 4c: re-press slot=${POV_SLOT_AFTER_SEEK:-NONE} for ${SEG_POV_STEAMID}"
    [ -n "$POV_SLOT_AFTER_SEEK" ] && spec_post /spec/slot "{\"slot\": ${POV_SLOT_AFTER_SEEK}}"
  fi

  WALLCLOCK_MS=$SEG_DURATION_MS
  WALLCLOCK_DEADLINE_MS=$(awk -v w="$WALLCLOCK_MS" -v f="$CLIP_SEGMENT_TIMEOUT_FACTOR" \
    'BEGIN{printf "%d", w * f}')

  # Start capture while the demo is still PAUSED at SEG_PRE, THEN press play.
  # Recording therefore opens exactly at the pre-roll — previously we played
  # first and only started capturing after wait-advancing + POV re-press + the
  # ~0.3s gst spawn, during which the demo drifted ~1-2s past SEG_START and ate
  # most of the 3s lead (the kill landed almost immediately). The capture arms
  # here but records nothing yet — it holds every frame until STEP 5 confirms the
  # demo is moving and opens its gate, so the SEG_START frame cs2 holds while it
  # digests a big backward unpause never reaches the mp4 (clips opened on a second
  # of statues). The ximagesrc fallback has no gate and still records it.
  say "STEP 6: start capture (paused at $SEG_PRE) -> $SEG_FILE"
  # The gate now also waits out the pre-roll; keep the consumer's record-anyway backstop past it.
  export VKCAP_START_TIMEOUT_MS="${VKCAP_START_TIMEOUT_MS:-20000}"
  if ! start_clip_capture "$SEG_FILE" "${CLIP_OUTPUT_FPS:-60}" "${CLIP_VIDEO_KBPS:-24000}" 1; then
    die_failed "clip capture failed to start (segment $SEG_IDX)"
  fi
  say "STEP 6: pid=${CLIP_CAPTURE_PID:-?}"
  if [ "$SEG_PREROLL_MS" -gt 0 ] && [ -z "${CLIP_CAPTURE_START_FILE:-}" ]; then
    # Fell back to a gateless capture: it would record the pre-roll, so drop it.
    say "WARN capture has no start gate — dropping the pre-roll, re-seeking to $SEG_START"
    spec_post /demo/seek "{\"tick\": ${SEG_START}}"
    wait_seek_settled "pre-roll drop" || true
    SEG_PRE=$SEG_START
    SEG_PREROLL_MS=0
  fi
  # Spawning the capture is not the same as recording it: on the vkcapture path
  # cs2's obs-vkcapture layer retries connect() on a 1s cadence and the swapchain
  # handshake follows, so the first buffer can be ~0.5-2s out. Playing before
  # then fed the pre-kill lead into a pipeline that recorded none of it.
  wait_clip_capture_ready || true
  start_capture_diag "${CLIP_CAPTURE_PID:-}"

  # Force-pause then toggle â†’ deterministic PLAYING (a bare relative toggle
  # could pause a demo the re-seek left playing).
  # No pre-roll to hide it in, so check while still paused (costs no lead).
  [ "$SEG_PREROLL_MS" -gt 0 ] || hide_demoui_before_recording
  say "STEP 5: PRESS PLAY (force-pause then toggle)"
  spec_post /demo/pause '{"force": true}'
  sleep 0.15
  # GSI stops while paused, so this baseline is usually stale — that's fine: fresh
  # GSI only resumes once the demo rolls, which is exactly what we wait for.
  PLAY_SIG_BEFORE=$(playback_sig "${SEG_POV_STEAMID:-}" any) || PLAY_SIG_BEFORE=""
  if [ "${CLIP_CAPTURE_FIXED_TIMESTEP:-0}" = "1" ]; then
    say "STEP 5: fixed timestep on (host_framerate ${CLIP_OUTPUT_FPS:-60})"
    set_fixed_timestep "${CLIP_OUTPUT_FPS:-60}"
  fi
  now_ms PLAY_T0
  spec_post /demo/toggle '{}'

  # The capture is armed but holding: open its gate only once the demo is really
  # rolling, so the clip opens on motion instead of on the frame cs2 holds while it
  # digests the unpause.
  wait_playback_moving "$PLAY_SIG_BEFORE" || true

  # With a pre-roll the POV re-press (and any camera settle) lands before the gate.
  if [ "$SEG_PREROLL_MS" -gt 0 ]; then
    repress_pov_after_play
    hide_demoui_before_recording
    log_spec_slots "after-play"
    wait_preroll "$SEG_PREROLL_MS" "${PLAY_SIG_BEFORE%%|*}" "$PLAY_T0" || true
    clip_capture_go
    now_ms GATE_MS
  else
    clip_capture_go
    now_ms GATE_MS
    repress_pov_after_play
    log_spec_slots "after-play"
  fi
  # The game clock (phase countdown) at the gate, so the KILL line can report the real
  # demo time into the clip, not wall time rescaled into ticks.
  IFS='|' read -r _ GATE_PE _ GATE_AGE _ <<<"$(capture_fields_line "${SEG_POV_STEAMID:-}")"

  # STEP 7: record SEG_DURATION of playback, billed by WALL-CLOCK. rate is
  # forced to 1, so wall-time == demo-time once playing (we opened the capture
  # paused at SEG_START, then pressed play). We bill every poll so a quiet hold
  # can't stretch the window
  # â€” flat world_motion is a LEGIT gameplay state (players pre-aiming), and the
  # old loop mis-read it as a stall and over-recorded into the next round. The
  # one real exception is the documented ~2s post-seek FREEZE that can land
  # mid-clip before the kill: we detect it via the GSI phase clock
  # (phase_ends_in), which advances with demo time during a live round but goes
  # FLAT when playback truly stalls â€” independent of whether players move. While
  # it's flat (capped at CLIP_UNBILLED_CAP_MS) we withhold the time and kick, so
  # the kill isn't cut; the cap bounds any tail over-record if the signal ever
  # misfires. WALLCLOCK_DEADLINE_MS is a hard backstop against a wedged demo.
  say "STEP 7: capturing ${SEG_DURATION_MS}ms wall-clock (target tick ${SEG_END}, wall cap ${WALLCLOCK_DEADLINE_MS}ms)"
  # Catch a fatal from the seek/lead-in before billing frozen frames.
  fail_on_cs2_fatal
  PLAYED_MS=0
  UNBILLED_MS=0
  LAST_PHASE_ENDS=""
  LAST_LOG_TICKS=0
  FREEZE_STREAK=0
  FREEZE_RECOVERIES=0
  FREEZE_RECOVERY_MAX=4
  CUR_DONE_TICKS=0
  SEG_START_ROUND=""   # GSI round_number at capture start (bleed guard anchor)
  LAST_POV_KILLS=""    # POV target's round_kills, to log the actual kill moment
  LOG_EVERY_TICKS=$(awk -v r="${CLIP_TICK_RATE:-64}" 'BEGIN{printf "%d", r * 1.5}')
  LOOP_ITERS=0
  LAST_FATAL_CHECK_MS=0
  GSI_SIG_FIRST=""     # frozen-capture guard: did GSI ever change?
  GSI_SIG_CHANGED=0
  GSI_SIG_POLLS=0
  # Billing starts at the gate: recording began there, and the checks above (a cs2
  # fatal probe can take seconds) were recorded but went unbilled, so the clip ran
  # long and every "+Nt" below was measured from the wrong moment.
  WALLCLOCK_START_MS=$GATE_MS
  PREV_MS=$GATE_MS
  while : ; do
    if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
      die_failed "clip capture died mid-render (segment $SEG_IDX)"
    fi
    now_ms NOW_MS
    # ~1/s: catch a mid-capture fatal instead of billing frozen frames.
    if [ $((NOW_MS - LAST_FATAL_CHECK_MS)) -ge 1000 ]; then
      LAST_FATAL_CHECK_MS=$NOW_MS
      fail_on_cs2_fatal
    fi
    if [ $((NOW_MS - WALLCLOCK_START_MS)) -gt "$WALLCLOCK_DEADLINE_MS" ]; then
      say "WARN segment $SEG_IDX hit ${WALLCLOCK_DEADLINE_MS}ms wall cap (done=${CUR_DONE_TICKS}t) â€” stopping"
      spec_post /demo/pause '{"force": true}'
      break
    fi
    DELTA_MS=$((NOW_MS - PREV_MS))
    PREV_MS=$NOW_MS

    # Pipe-delimited capture fields. Fast path: one in-process GET on the
    # spec-server. Fallback (stale server): the old curl+node pipeline.
    # A failed fetch yields an empty line -> all fields empty, same as before.
    if [ "$CAPTURE_FIELDS_FAST" = "1" ]; then
      FS_LINE=$(curl --fail --silent --max-time 5 \
        "${SPEC_SERVER_URL}/demo/capture-fields?pov=${SEG_POV_STEAMID:-}" || true)
    else
      FS_LINE=$(spec_get_state | node "$CLIP_HELPERS" capture-fields "${SEG_POV_STEAMID:-}" || true)
    fi
    IFS='|' read -r PHASE PHASE_ENDS MOTION GSIAGE MPHASE ROUND_NUM POV_KILLS <<<"$FS_LINE"
    GSI_FRESH=0; { [ -n "$GSIAGE" ] && [ "$GSIAGE" -le 750 ]; } && GSI_FRESH=1

    # Frozen-capture guard: clock/motion shift during any real playback, so an
    # identical snapshot all segment means the demo is halted.
    GSI_SIG="${PHASE_ENDS}|${MOTION}|${POV_KILLS}|${ROUND_NUM}"
    if [ "$GSI_SIG" != "|||" ]; then
      GSI_SIG_POLLS=$((GSI_SIG_POLLS + 1))
      if [ -z "$GSI_SIG_FIRST" ]; then GSI_SIG_FIRST="$GSI_SIG"
      elif [ "$GSI_SIG" != "$GSI_SIG_FIRST" ]; then GSI_SIG_CHANGED=1; fi
    fi

    # Anchor the bleed guard to the round we opened in (first fresh reading).
    if [ -z "$SEG_START_ROUND" ] && [ "$GSI_FRESH" = "1" ] && [ -n "$ROUND_NUM" ]; then
      SEG_START_ROUND="$ROUND_NUM"
      say "seg$SEG_IDX: start round=${SEG_START_ROUND} povKills=${POV_KILLS:-?}"
    fi
    # Log the actual kill moment (POV target's round_kills incremented) so we can
    # verify the kill lands ~lead into the clip. (Detection only â€” no behavior.)
    if [ -n "$POV_KILLS" ]; then
      if [ -n "$LAST_POV_KILLS" ] && [ "$POV_KILLS" -gt "$LAST_POV_KILLS" ]; then
        # Demo time since the gate, off the phase countdown (0.1s resolution; "?" if it
        # reset in between, e.g. freezetime end or a bomb plant).
        KILL_LEAD=$(awk -v g="${GATE_PE:-}" -v k="${PHASE_ENDS:-}" -v ga="${GATE_AGE:-0}" \
          'BEGIN{ if (g == "" || k == "" || k > g) { print "?"; exit } printf "%d", (g - k) * 1000 - ga }')
        say "KILL seg$SEG_IDX: POV round_kills ${LAST_POV_KILLS}->${POV_KILLS} at ${KILL_LEAD}ms of demo time into the clip (expected ${SEG_LEAD_MS:-?}ms; ${PLAYED_MS}ms wall, clock=${PHASE_ENDS:-?})"
      fi
      LAST_POV_KILLS="$POV_KILLS"
    fi

    # Withhold a poll's time ONLY on a real freeze: a flat GSI phase clock means
    # demo playback stalled (not a player hold). Capped so a missing/odd phase
    # clock can't stretch the tail.
    # Any real phase, not just "live": a 3s pre-roll routinely sits in freezetime
    # or the previous round's "over" aftermath, and restricting the withholding
    # to "live" billed post-seek stalls there at full rate — straight out of the
    # lead. A non-empty PHASE still excludes stale GSI.
    if [ -n "$PHASE" ] && [ -n "$PHASE_ENDS" ] && [ "$PHASE_ENDS" = "$LAST_PHASE_ENDS" ] \
       && [ "$UNBILLED_MS" -lt "$CLIP_UNBILLED_CAP_MS" ]; then
      UNBILLED_MS=$((UNBILLED_MS + DELTA_MS))
      FREEZE_STREAK=$((FREEZE_STREAK + 1))
      if [ "$FREEZE_STREAK" -ge 2 ] && [ "$FREEZE_RECOVERIES" -lt "$FREEZE_RECOVERY_MAX" ]; then
        FREEZE_RECOVERIES=$((FREEZE_RECOVERIES + 1))
        say "WARN seg$SEG_IDX demo frozen (phase clock ${PHASE_ENDS}s, unbilled=${UNBILLED_MS}/${CLIP_UNBILLED_CAP_MS}ms) â€” recovery ${FREEZE_RECOVERIES}/${FREEZE_RECOVERY_MAX}: pauseâ†’toggle"
        spec_post /demo/pause '{"force": true}'; sleep 0.15; spec_post /demo/toggle '{}'
        FREEZE_STREAK=0
      fi
    else
      PLAYED_MS=$((PLAYED_MS + DELTA_MS))
      FREEZE_STREAK=0
    fi
    LAST_PHASE_ENDS="$PHASE_ENDS"
    if [ "$WALLCLOCK_MS" -gt 0 ]; then
      CUR_DONE_TICKS=$(( SEG_TICKS * PLAYED_MS / WALLCLOCK_MS ))
    else
      CUR_DONE_TICKS=$SEG_TICKS
    fi

    # Match-end guard: playing to the literal final tick triggers cs2's
    # gameover transition and auto-closes the demo, breaking later jobs.
    if [ "$SEG_MATCH_END_GUARDED" = "1" ] && [ -n "$MPHASE" ]; then
      if [ -n "$GSIAGE" ] && [ "$GSIAGE" -le 750 ] && [ "$MPHASE" = "gameover" ]; then
        say "MATCH_END_GUARD segment $SEG_IDX: gameover reached (done=${CUR_DONE_TICKS}t) â€” stopping early"
        spec_post /demo/pause '{"force": true}'
        break
      fi
    fi

    # Round-bleed guard: stop only once the NEXT round has actually begun, not
    # during the "over" aftermath. A round-ending kill (clutch/ace) flips
    # round_number forward immediately while phase=="over" â€” that aftermath IS
    # the post-roll we want, so we must NOT cut there. We stop only when a later
    # round reaches freezetime/live (a real bleed into the next round). Gated on
    # fresh GSI.
    if [ "$GSI_FRESH" = "1" ] && [ -n "$SEG_START_ROUND" ] && [ -n "$ROUND_NUM" ] \
       && [ "$ROUND_NUM" -gt "$SEG_START_ROUND" ] && [ "$PHASE" != "over" ]; then
      say "ROUND_BLEED seg$SEG_IDX: round ${SEG_START_ROUND}->${ROUND_NUM} phase=${PHASE} (done=${CUR_DONE_TICKS}t) â€” stopping"
      spec_post /demo/pause '{"force": true}'
      break
    fi

    if [ "$PLAYED_MS" -ge "$WALLCLOCK_MS" ]; then
      say "STEP 7: captured ${PLAYED_MS}ms of ${WALLCLOCK_MS}ms (wall-clock) â€” stopping (seg $SEG_IDX)"
      spec_post /demo/pause '{"force": true}'
      break
    fi

    if [ $((CUR_DONE_TICKS - LAST_LOG_TICKS)) -ge "$LOG_EVERY_TICKS" ]; then
      say "STATE [seg${SEG_IDX} +${CUR_DONE_TICKS}t]: phase=${PHASE:-?} clock=${PHASE_ENDS:-?} round=${ROUND_NUM:-?}/${SEG_START_ROUND:-?} povKills=${POV_KILLS:-?} motion=${MOTION:-?}"
      LAST_LOG_TICKS=$CUR_DONE_TICKS
    fi

    # Progress POST: throttled to >=1s, single-flight, backgrounded â€” the
    # remote API must never sit in the poll's critical path. Integer math
    # scaled x1000 mirrors base 0.05 + span 0.95 above.
    if [ $((NOW_MS - API_PROGRESS_LAST_MS)) -ge 1000 ] \
       && { [ -z "$API_PROGRESS_PID" ] || ! kill -0 "$API_PROGRESS_PID" 2>/dev/null; }; then
      P_TOTAL=$TOTAL_DURATION_TICKS
      [ "$P_TOTAL" -le 0 ] && P_TOTAL=1
      P_MILLI=$(( 50 + 950 * (ELAPSED_TICKS_TOTAL + CUR_DONE_TICKS) / P_TOTAL ))
      [ "$P_MILLI" -gt 1000 ] && P_MILLI=1000
      api_status_progress_async "$NOW_MS" \
        "$(printf '%d.%03d' $((P_MILLI / 1000)) $((P_MILLI % 1000)))"
    fi

    LOOP_ITERS=$((LOOP_ITERS + 1))
    sleep 0.15
  done
  api_progress_settle wait
  if [ "$LOOP_ITERS" -gt 0 ]; then
    say "STEP 7: loop iters=${LOOP_ITERS} avg_period=$(( (NOW_MS - WALLCLOCK_START_MS) / LOOP_ITERS ))ms"
  fi

  # GSI never changed all segment -> demo halted -> frozen clip; fail and mark
  # the session dead so the batch skips.
  if [ "$GSI_SIG_POLLS" -ge 12 ] && [ "$GSI_SIG_CHANGED" = "0" ]; then
    cs2_mark_fatal "demo never advanced (GSI flat over ${GSI_SIG_POLLS} polls): ${GSI_SIG_FIRST}"
    die_failed "cs2 cannot play this demo (GetClassBaseline replay bug)"
  fi

  stop_capture_diag
  say "STEP 8: stop capture (segment $SEG_IDX)"
  stop_clip_capture
  if [ "$FIXED_TIMESTEP_ON" = "1" ]; then
    set_fixed_timestep 0
    report_host_framerate
    has_audio_stream "$SEG_FILE" && retime_segment_audio "$SEG_FILE" "${CLIP_CAPTURE_TIMING_FILE:-}"
  fi
  [ -n "${CLIP_CAPTURE_TIMING_FILE:-}" ] && rm -f "$CLIP_CAPTURE_TIMING_FILE"

  # Sanity check the RAW capture before any polish: capture sometimes
  # produces an mp4 with no decodable frames (cs2 mid-load, audio attach
  # race, etc). Concat'ing an empty file silently drops everything after
  # it, which is exactly the "got 1 kill instead of 2" bug. Probing the
  # raw file (not the polished one) also keeps the vkcapture-empty
  # fallback below reachable on the chip path.
  SEG_BYTES=$(stat -c '%s' "$SEG_FILE" 2>/dev/null \
    || stat -f '%z' "$SEG_FILE" 2>/dev/null \
    || echo 0)
  SEG_REAL_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$SEG_FILE" 2>/dev/null \
    | awk '{printf "%.2f", $1}')
  [ -z "$SEG_REAL_DUR" ] && SEG_REAL_DUR=0
  IS_VALID=$(awk -v d="$SEG_REAL_DUR" -v b="$SEG_BYTES" \
    'BEGIN{print (d >= 0.5 && b > 1024) ? 1 : 0}')
  if [ "$IS_VALID" = "1" ]; then
    say "  segment $SEG_IDX OK (${SEG_BYTES}B, ${SEG_REAL_DUR}s)"
    # Per-segment polish pass â€” bakes the chip overlay when present.
    # Skipped when no chip applies so the no-chip path keeps GStreamer's
    # capture intact. Also skipped when WILL_FUSE_POLISH_OUTRO=1 â€” the
    # chip gets baked into the same filter_complex as the outro concat,
    # saving one full NVENC encode per clip.
    wait_for_chip_render
    # Chip = player intro card â€” overlay it ONCE, on the first segment only.
    # Segments >0 fall through to the no-chip path (raw segment, silence-padded).
    if [ "$WILL_FUSE_POLISH_OUTRO" != "1" ] && [ -n "$CHIP_MOV" ] && [ "$SEG_IDX" = "0" ]; then
      # Reap the PREVIOUS segment's polish first â€” single-flight.
      reap_polish_bg
      POLISH_BG_LOG="${SEG_FILE}.polish.log"
      (
        HAS_AUDIO=0
        if has_audio_stream "$SEG_FILE"; then HAS_AUDIO=1; fi
        POLISH_FILE="${SEG_FILE}.polish.mp4"

        # Keep the underlying segment's duration and blend the chip's
        # alpha properly. The chip mov is only ~3.5s â€” past its end the
        # [1:v] stream ends and overlay falls through with no chip drawn.
        FC_VIDEO="[0:v][1:v]overlay=0:0:eof_action=pass:format=auto[vout]"
        INPUT_ARGS=(-i "$SEG_FILE" -i "$CHIP_MOV")

        AUDIO_ARGS=()
        if [ "$HAS_AUDIO" = "1" ]; then
          AUDIO_ARGS=(-map 0:a -c:a aac -b:a 192k)
        else
          AUDIO_ARGS=(-an)
        fi

        if ! FFMPEG_NICE=10 ffmpeg_venc -y -hide_banner -loglevel warning \
             "${INPUT_ARGS[@]}" \
             -filter_complex "$FC_VIDEO" \
             -map "[vout]" \
             "${AUDIO_ARGS[@]}" \
             "${FFMPEG_VENC_ARGS[@]}" \
             -r "${CLIP_OUTPUT_FPS:-60}" \
             -movflags +faststart \
             "$POLISH_FILE"; then
          rm -f "$POLISH_FILE"
          exit 1
        fi
        mv -f "$POLISH_FILE" "$SEG_FILE"
        # A segment that captured through the gameover/menu transition can
        # land with no audio stream; one audio-less segment fails the whole
        # concat filter graph. Pad silent stereo (video stream-copied).
        if ! has_audio_stream "$SEG_FILE"; then
          echo "no audio stream â€” padding silence"
          AUD_FILE="${SEG_FILE}.aud.mp4"
          if ffmpeg -y -hide_banner -loglevel warning \
               -i "$SEG_FILE" \
               -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
               -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest \
               -movflags +faststart "$AUD_FILE"; then
            mv -f "$AUD_FILE" "$SEG_FILE"
          else
            rm -f "$AUD_FILE"
            echo "WARN failed to pad silent audio â€” leaving as-is"
          fi
        fi
      ) >"$POLISH_BG_LOG" 2>&1 &
      POLISH_BG_PID=$!
      POLISH_BG_IDX=$SEG_IDX
      say "  polish[$SEG_IDX] backgrounded (pid $POLISH_BG_PID) â€” overlaps next segment"
      if [ "$CLIP_POLISH_OVERLAP" != "1" ]; then
        reap_polish_bg
      fi
    else
      # No-chip path stays inline (no second encode happens here).
      COPY_ELIGIBLE=0
      if ! has_audio_stream "$SEG_FILE"; then
        say "  segment $SEG_IDX has no audio stream â€” padding silence"
        AUD_FILE="${SEG_FILE}.aud.mp4"
        if ffmpeg -y -hide_banner -loglevel warning \
             -i "$SEG_FILE" \
             -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
             -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest \
             -movflags +faststart "$AUD_FILE"; then
          mv -f "$AUD_FILE" "$SEG_FILE"
        else
          rm -f "$AUD_FILE"
          say "  WARN failed to pad silent audio for segment $SEG_IDX â€” leaving as-is"
        fi
      fi
    fi
    CONCAT_ENTRY[$SEG_IDX]="$SEG_FILE"
  elif [ "${CLIP_CAPTURE_METHOD:-vkcapture}" = "vkcapture" ] && [ "$VKCAP_FELL_BACK" = "0" ]; then
    # Empty under vkcapture. Never armed = the present-hook delivered no frames (e.g.
    # the GTX 980 can't host-map the layer's dmabuf: "mmap(fd0) failed: Invalid
    # argument") — a per-pod failure, so the rest of the render switches to ximagesrc.
    # Armed = frames were flowing and this capture failed on its own (a wedged
    # pipeline, a killed consumer): redo just this segment on ximagesrc and go back
    # to vkcapture for the next one — at most twice, then stay on ximagesrc.
    if [ "${CLIP_CAPTURE_ARMED:-0}" = "1" ] && [ "$VKCAP_ONE_OFF_FAILS" -lt 2 ]; then
      VKCAP_ONE_OFF_FAILS=$((VKCAP_ONE_OFF_FAILS + 1))
      VKCAP_RETRY_SEG=$SEG_IDX
      say "WARN segment $SEG_IDX empty under vkcapture (${SEG_BYTES}B) after arming — redoing it on ximagesrc, vkcapture again from the next segment"
    else
      say "WARN segment $SEG_IDX empty under vkcapture (${SEG_BYTES}B) — falling back to ximagesrc for the rest of the render"
    fi
    CLIP_CAPTURE_METHOD=ximagesrc; export CLIP_CAPTURE_METHOD
    VKCAP_FELL_BACK=1
    rm -f "$SEG_FILE"
    continue   # retry same SEG_IDX (index not advanced)
  else
    say "WARN segment $SEG_IDX is empty/short (${SEG_BYTES}B, ${SEG_REAL_DUR}s) â€” dropping from concat"
    rm -f "$SEG_FILE"
  fi
  if [ "$VKCAP_RETRY_SEG" = "$SEG_IDX" ]; then
    CLIP_CAPTURE_METHOD=vkcapture; export CLIP_CAPTURE_METHOD
    VKCAP_FELL_BACK=0
    VKCAP_RETRY_SEG=""
  fi
  ELAPSED_TICKS_TOTAL=$((ELAPSED_TICKS_TOTAL + SEG_TICKS))
  SEG_IDX=$((SEG_IDX + 1))
done

# Recording is DONE â€” render the player chip now (fused path), so the heavy
# Chromium render never competes with cs2 during capture (the seg0-tail jitter).
# No-op when already launched (non-fused path launched it before the loop) or when
# there's no chip. It overlaps the light concat.txt prep below; reaped before STEP 9.
start_chip_render after

# Wait for the last background polish, then write concat.txt in segment
# order. Entries were recorded per index during the loop; nothing reads
# concat.txt before this point.
reap_polish_bg
wait_for_chip_render   # ensure the chip .mov is finalized before any STEP 9 consumer
for i in $(seq 0 $((SEG_COUNT - 1))); do
  [ -n "${CONCAT_ENTRY[$i]:-}" ] \
    && printf "file '%s'\n" "${CONCAT_ENTRY[$i]}" >>"$SEG_DIR/concat.txt"
done

# Recompute SEG_COUNT from what actually ended up in concat.txt â€”
# downstream fade pass + concat decisions need the real count, not
# the originally-requested count.
# grep -c prints "0" AND exits 1 on zero matches; a `|| echo 0` would append a
# second line ("0\n0"), which breaks the -lt guard + the $((+1)) below. Reassign
# on failure instead so SEG_COUNT is always a single integer.
SEG_COUNT=$(grep -c "^file " "$SEG_DIR/concat.txt" 2>/dev/null) || SEG_COUNT=0
if [ "$SEG_COUNT" -lt 1 ]; then
  die_failed "all segments produced empty captures â€” cs2 may be stalled"
fi

# Outro append. We track whether one was added so the concat below
# knows to skip stream-copy (mismatched PTS between captured segments
# and the Remotion outro pushes the outro ~30s past in stream-copy).
OUTRO_APPENDED=0
if [ "$BRANDING_ENABLED" = "1" ] && [ "${CLIP_DISABLE_OUTRO:-0}" != "1" ]; then
  OUTRO_DIMS="${CLIP_OUTPUT_DIMS:-1920x1080}"
  OUTRO_FPS="${CLIP_OUTPUT_FPS:-60}"
  OUTRO_FILE="${OUTRO_DIR:-/opt/game-streamer/resources/video}/outro_${OUTRO_DIMS}_${OUTRO_FPS}.mp4"
  if [ -f "$OUTRO_FILE" ]; then
    say "OUTRO: appending $OUTRO_FILE"
    printf "file '%s'\n" "$OUTRO_FILE" >>"$SEG_DIR/concat.txt"
    SEG_COUNT=$((SEG_COUNT + 1))
    OUTRO_APPENDED=1
  else
    say "OUTRO: missing $OUTRO_FILE â€” shipping without outro"
  fi
fi

# Concat â€” direct cuts between segments. We tried 0.4s fade
# transitions earlier and the result was a longer-than-expected dip
# to black at every join (cs2's seek-loading frames at the head of
# each segment compound with the fade-in, producing 0.5-1s of dead
# air per cut). For a frag montage the harder pace of direct cuts
# reads better and the action stays continuous.
#
# Encoder strategy: try `-c copy` first â€” every segment is already
# in the configured codec/aac from gst capture or the chip polish pass,
# so a stream copy is bit-perfect
# and finishes near disk-IO speed instead of a second full 1080p60
# encode. Concat-demuxer copy only works when timebase + codec params
# line up across inputs, and the GPU vs sw encoder pair can produce
# mismatched params on some pods. Re-encode is the fallback for that
# case, using the same codec family as the segments to keep file
# sizes consistent.
# Stream-copy fast path for the outro concat: when every captured
# segment went through the per-segment polish (one uniform encoder
# invocation), transcode the short outro once with the same args and
# concat-demux `-c copy` the whole montage â€” skipping the second full
# re-encode. The trailing-PTS concern documented below applies to RAW
# gst captures; polished files are clean ffmpeg muxes. PTS pathologies
# survive -c copy silently, so the output duration is verified; any
# failure falls back to the filter-graph encode. CLIP_CONCAT_COPY=0
# disables the attempt.
try_concat_copy() {
  [ "${CLIP_CONCAT_COPY:-1}" = "1" ] || return 1
  [ "$WILL_FUSE_POLISH_OUTRO" != "1" ] || return 1
  [ "$COPY_ELIGIBLE" = "1" ] || return 1

  local outro_matched
  outro_matched=$(matched_outro_cache_path) || return 1
  if [ -s "$outro_matched" ]; then
    say "STEP 9: concat fast path — reusing cached matched outro"
  else
    local in_args=(-i "$OUTRO_FILE")
    local map_args=(-map 0:v -map 0:a)
    if ! has_audio_stream "$OUTRO_FILE"; then
      in_args+=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000)
      map_args=(-map 0:v -map 1:a -shortest)
    fi
    say "STEP 9: concat fast path — transcoding outro to match polished segments (cached for later clips)"
    # Transcode to a scratch file and rename in — a killed render must never
    # leave a truncated outro behind for the next clip to concat.
    local staging="${outro_matched}.$$.tmp"
    if ! ffmpeg_venc -y -hide_banner -loglevel warning \
         "${in_args[@]}" \
         "${map_args[@]}" \
         "${FFMPEG_VENC_ARGS[@]}" \
         -r "${CLIP_OUTPUT_FPS:-60}" \
         -c:a aac -b:a 192k -ar 48000 -ac 2 \
         -movflags +faststart \
         "$staging"; then
      say "  concat: outro transcode failed — falling back to re-encode"
      rm -f "$staging"
      return 1
    fi
    mv -f "$staging" "$outro_matched" || { rm -f "$staging"; return 1; }
  fi

  local copy_list="$SEG_DIR/concat-copy.txt"
  sed '$d' "$SEG_DIR/concat.txt" >"$copy_list"   # drop original outro line
  printf "file '%s'\n" "$outro_matched" >>"$copy_list"

  if ! ffmpeg -y -hide_banner -loglevel warning \
       -f concat -safe 0 -i "$copy_list" \
       -c copy -movflags +faststart \
       "$CLIP_OUT_FILE" 2>/dev/null; then
    say "  concat: stream-copy refused â€” falling back to re-encode"
    rm -f "$CLIP_OUT_FILE"
    return 1
  fi

  local expected_s actual_s
  expected_s=$(awk -F"'" '/^file/{print $2}' "$copy_list" \
    | while IFS= read -r f; do
        ffprobe -v error -show_entries format=duration \
          -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null
      done | awk '{s+=$1} END{printf "%.2f", s}')
  actual_s=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$CLIP_OUT_FILE" 2>/dev/null \
    | awk '{printf "%.2f", $1}')
  if ! awk -v a="${actual_s:-0}" -v e="${expected_s:-0}" \
       'BEGIN{ d=a-e; if (d<0) d=-d; exit !(e > 0 && d <= 2.0) }'; then
    say "  concat: stream-copy duration off (${actual_s:-?}s vs expected ${expected_s:-?}s) â€” falling back to re-encode"
    rm -f "$CLIP_OUT_FILE"
    return 1
  fi
  say "  concat: stream-copy OK (${actual_s}s, expected ${expected_s}s) â€” montage re-encode skipped"
  return 0
}

if [ "$SEG_COUNT" = "1" ]; then
  ONLY_SEG=$(awk -F"'" '/^file/{print $2}' "$SEG_DIR/concat.txt" | head -1)
  mv -f "$ONLY_SEG" "$CLIP_OUT_FILE"
elif [ "$OUTRO_APPENDED" = "1" ] && try_concat_copy; then
  : # stream-copy fast path already produced $CLIP_OUT_FILE
elif [ "$OUTRO_APPENDED" = "1" ]; then
  # concat filter (not demuxer) â€” regenerates PTS cleanly. The
  # captured segments carry trailing PTS that pushes the outro ~30s
  # past with -c copy. Filter-graph concat is the reliable splice
  # across heterogeneous sources.
  #
  # WILL_FUSE_POLISH_OUTRO=1: the per-segment polish pass was skipped,
  # so the chip overlay gets folded into this same encode â€” one NVENC
  # pass instead of two (polish-per-segment + concat).
  CAP_SEG_COUNT=$((SEG_COUNT - 1))  # last entry in concat.txt is outro
  CONCAT_INPUTS=()
  while IFS= read -r line; do
    f=$(printf '%s' "$line" | awk -F"'" '/^file/{print $2}')
    [ -n "$f" ] && CONCAT_INPUTS+=("-i" "$f")
  done <"$SEG_DIR/concat.txt"

  FC=""
  if [ "$WILL_FUSE_POLISH_OUTRO" != "1" ]; then
    # Segments were already polished per-segment; simple concat-only graph.
    say "STEP 9: ffmpeg concat ${SEG_COUNT} segments (with outro, filter-graph)"
    for i in $(seq 0 $((SEG_COUNT - 1))); do
      FC+="[${i}:v:0][${i}:a:0]"
    done
    FC+="concat=n=${SEG_COUNT}:v=1:a=1[v][a]"
  else
    # Fused path: bake chip overlay into the same encode as the outro
    # concat â€” one NVENC pass instead of two.
    say "STEP 9: ffmpeg fused polish+concat ${CAP_SEG_COUNT} seg(s) + outro"

    # Chip = the player intro card; show it ONCE, on the FIRST segment only â€” not
    # re-animated at every segment start. Appended as one extra input and overlaid
    # on segment 0; all other segments pass through untouched (no split needed).
    if [ -n "$CHIP_MOV" ]; then
      CHIP_IDX=$SEG_COUNT
      CONCAT_INPUTS+=("-i" "$CHIP_MOV")
    fi

    for i in $(seq 0 $((CAP_SEG_COUNT - 1))); do
      if [ -n "$CHIP_MOV" ] && [ "$i" = "0" ]; then
        FC+="[${i}:v][${CHIP_IDX}:v]overlay=0:0:eof_action=pass:format=auto"
      else
        FC+="[${i}:v]null"
      fi
      FC+="[v${i}];"
    done

    # Final concat: per-segment polished streams + raw outro streams.
    for i in $(seq 0 $((CAP_SEG_COUNT - 1))); do
      FC+="[v${i}][${i}:a]"
    done
    FC+="[${CAP_SEG_COUNT}:v][${CAP_SEG_COUNT}:a]"
    FC+="concat=n=${SEG_COUNT}:v=1:a=1[v][a]"
  fi

  if ! ffmpeg_venc -y -hide_banner -loglevel warning \
       "${CONCAT_INPUTS[@]}" \
       -filter_complex "$FC" \
       -map "[v]" -map "[a]" \
       "${FFMPEG_VENC_ARGS[@]}" \
       -r "${CLIP_OUTPUT_FPS:-60}" \
       -c:a aac -b:a 192k -ar 48000 -ac 2 \
       -movflags +faststart \
       "$CLIP_OUT_FILE"; then
    die_failed "ffmpeg concat (filter-graph) failed"
  fi
else
  say "STEP 9: ffmpeg concat ${SEG_COUNT} segments (direct cuts)"
  if ffmpeg -y -hide_banner -loglevel warning \
       -f concat -safe 0 -i "$SEG_DIR/concat.txt" \
       -c copy \
       -movflags +faststart \
       "$CLIP_OUT_FILE" 2>/dev/null; then
    say "  concat: stream-copy succeeded"
  else
    rm -f "$CLIP_OUT_FILE"
    say "  concat: stream-copy refused — re-encoding"
    if ! ffmpeg_venc -y -hide_banner -loglevel warning \
         -f concat -safe 0 -i "$SEG_DIR/concat.txt" \
         "${FFMPEG_VENC_ARGS[@]}" \
         -r "${CLIP_OUTPUT_FPS:-60}" \
         -c:a aac -b:a 192k \
         -movflags +faststart \
         "$CLIP_OUT_FILE"; then
      die_failed "ffmpeg concat failed"
    fi
  fi
fi
rm -rf "$SEG_DIR"

if [ "$LIVE_CAPTURE_STOPPED" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
  say "STEP 9a: restart live capture"
  restart_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=0
fi
api_status "status=rendering" "progress=1.0"

restore_user_playback
SAVED_TICK=""
trap - EXIT

# Batch mode: cs2/demo work is done â€” signal the batch loop so the next
# job can start capturing while this job's thumbnail+upload tail
# (network/disk only) finishes in the background.
if [ -n "${CLIP_CS2_RELEASE_MARKER:-}" ]; then
  : >"$CLIP_CS2_RELEASE_MARKER" 2>/dev/null || true
  say "cs2 released â€” next batch job may start"
fi

[ -s "$CLIP_OUT_FILE" ] || die_failed "clip output is empty"
CLIP_BYTES=$(stat -c '%s' "$CLIP_OUT_FILE" 2>/dev/null \
  || stat -f '%z' "$CLIP_OUT_FILE")
say "rendered $CLIP_OUT_FILE ($CLIP_BYTES bytes)"
REAL_DURATION_MS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$CLIP_OUT_FILE" 2>/dev/null \
  | awk '{printf "%d", $1 * 1000}')
if [ -z "$REAL_DURATION_MS" ]; then
  REAL_DURATION_MS=$(awk -v t="$TOTAL_DURATION_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
    'BEGIN{printf "%d", t / r * 1000}')
fi

THUMB_SEEK_SECS=3
THUMB_DURATION_SECS=$(awk -v ms="$REAL_DURATION_MS" 'BEGIN{printf "%.3f", ms/1000}')
if awk -v d="$THUMB_DURATION_SECS" -v t="$THUMB_SEEK_SECS" 'BEGIN{exit !(d <= t)}'; then
  THUMB_SEEK_SECS=$(awk -v d="$THUMB_DURATION_SECS" 'BEGIN{printf "%.3f", d/2}')
fi

# Thumbnail extract + POST runs in parallel with the clip upload â€”
# both read $CLIP_OUT_FILE independently. The thumb POST is
# best-effort (no die_failed), so failures only warn.
THUMB_URL="${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/thumbnail"
say "thumbnail extract + POST $THUMB_URL (background)"
(
  if ffmpeg -y -hide_banner -loglevel warning \
       -ss "$THUMB_SEEK_SECS" -i "$CLIP_OUT_FILE" -frames:v 1 -q:v 3 \
       "$CLIP_THUMB_FILE" 2>/dev/null \
     && [ -s "$CLIP_THUMB_FILE" ]; then
    if ! curl --fail --silent --show-error \
           --max-time 60 \
           --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
           --header "content-type: image/jpeg" \
           --data-binary "@${CLIP_THUMB_FILE}" \
           --output /dev/null \
           "$THUMB_URL"; then
      say "WARN thumbnail upload failed â€” continuing without thumbnail"
    fi
  else
    say "WARN ffmpeg thumbnail extraction failed â€” continuing without thumbnail"
  fi
  rm -f "$CLIP_THUMB_FILE"
) &
THUMB_BG_PID=$!

api_status "status=uploading" "progress=0.0"
UPLOAD_URL="${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/upload"
say "POST $UPLOAD_URL"
# --upload-file streams from disk; --data-binary @file slurps the whole
# clip into RAM (matters with CLIP_BATCH_MAX_TAILS concurrent uploads).
# Drop --silent so curl writes its progress meter to stderr; pipe that
# through tee (-> err log for diagnostics) into a parser that re-posts
# "uploading" progress (throttled 1/s, single-flight) so the bar actually
# moves instead of jumping 0->1. The shell awaits the whole pipeline before
# PIPESTATUS[0] (curl's real exit code) is set; the parser settles its last
# post at EOF. stdout is the --output file, so 2>&1 carries only the meter.
UPLOAD_ERR="/tmp/clip-upload-err-${CLIP_RENDER_JOB_ID}.log"
curl --fail --show-error \
       --max-time 1800 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/octet-stream" \
       --header "x-clip-duration-ms: ${REAL_DURATION_MS}" \
       --upload-file "$CLIP_OUT_FILE" \
       --request POST \
       --output "/tmp/clip-upload-response-${CLIP_RENDER_JOB_ID}.json" \
       "$UPLOAD_URL" 2>&1 | tee "$UPLOAD_ERR" | parse_upload_progress
UPLOAD_RC=${PIPESTATUS[0]}
if [ "$UPLOAD_RC" -ne 0 ]; then
  say "WARN upload curl stderr: $(tr '\r' '\n' < "$UPLOAD_ERR" | tail -3 | tr '\n' ' ')"
  rm -f "$UPLOAD_ERR"
  die_failed "clip upload failed (curl rc=${UPLOAD_RC})"
fi
rm -f "$UPLOAD_ERR"

# Thumbnail is best-effort but we still want it posted before the
# pod exits (batch mode reaps the job right after status=done).
wait "$THUMB_BG_PID" 2>/dev/null || true

api_status "status=done" "progress=1.0"
CLIP_REACHED_TERMINAL=1
rm -f "$CLIP_OUT_FILE"
say "done"
