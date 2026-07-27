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
restore_user_playback() {
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

# "spectated_steam_id|pov_slot|slots_count|tick" from the fast endpoint.
spec_pov_state() {
  curl --fail --silent --max-time 5 \
    "${SPEC_SERVER_URL}/demo/pov-state?pov=${1:-}" || true
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
  say "WARN POV still not locked to ${target_sid} (got '${current}') â€” proceeding anyway"
  return 1
}

# Confirm cs2 actually resumed playback by watching for tick advance.
# The wallclock loop counts real time from the moment we think play
# started â€” if the resume cfg never landed (focus race, demoui repaint,
# cs2 mid-seek), the gst capture writes the frozen frame for the entire
# segment duration. Caller is expected to retry resume on failure.
verify_play_resumed() {
  local baseline_tick="$1"
  # ~2s deadline matches the old 6-iter loop's effective span (node
  # spawn per poll).
  local s tick line start=$SECONDS
  while [ $((SECONDS - start)) -lt 2 ]; do
    sleep 0.1
    if [ "$POV_STATE_FAST" = "1" ]; then
      line=$(spec_pov_state)
      tick="${line##*|}"
    else
      s=$(spec_get_state || true)
      [ -z "$s" ] && continue
      tick=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-tick)
    fi
    if [ -n "$tick" ] && [ "$tick" != "?" ] && [ "$tick" -gt "$baseline_tick" ] 2>/dev/null; then
      return 0
    fi
  done
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
H264_VENC_ARGS=(-c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -profile:v high -level 4.2)
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
spec_post /demo/exec '{"cmd": "spec_autodirector 0"}'

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
# Idempotent â€” launches at most once per job (CHIP_LAUNCHED guard).
start_chip_render() {
  [ "${CHIP_READY_TO_RENDER:-0}" = "1" ] || return 0
  [ "${CHIP_LAUNCHED:-0}" = "1" ] && return 0
  CHIP_LAUNCHED=1
  compute_cpu_split
  local pin=()
  if [ -n "${GS_CAPTURE_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
    pin=(taskset -c "$GS_CAPTURE_CPUS")
  fi
  say "CHIP: rendering for '${CHIP_NAME}' (pinned ${GS_CAPTURE_CPUS:-none} + nice 19)"
  (
    cd "$MOTION_DIR" && \
    "${pin[@]}" nice -n 19 \
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
# Parse the segment table once (one node spawn) instead of 3x per
# segment iteration. POV accountid = steamid64 - 76561197960265728;
# the lock is applied AFTER seeking + lead-in so the freshly-seeked
# target gets overridden â€” otherwise the clip opens on whoever cs2 was
# last spectating, producing the wrong POV.
declare -a SEG_STARTS=() SEG_ENDS=() SEG_POVS=()
while IFS='|' read -r _s _e _a; do
  SEG_STARTS+=("$_s"); SEG_ENDS+=("$_e"); SEG_POVS+=("$_a")
done < <(printf '%s' "$CLIP_SEGMENTS" | node "$CLIP_HELPERS" segs-table)

# Snapshot console.log size before any seek so we only match a fatal from this render.
CS2_LOG_OFFSET=$(wc -c < "${CS2_DIR}/game/csgo/console.log" 2>/dev/null || echo 0)
CS2_LOG_OFFSET="${CS2_LOG_OFFSET//[!0-9]/}"; CS2_LOG_OFFSET="${CS2_LOG_OFFSET:-0}"

# Pre-compile cs2's Vulkan pipelines before the first real capture. The FIRST
# segment of a cs2 process renders cold â€” pipelines compile on first encounter,
# stalling the render thread so presents/s collapses (GPU+CPU idle during the dip);
# once compiled they stay warm for the whole process. Steam's Fossilize precache
# (10GiB on disk) does NOT cover these demo-POV pipelines, so the only cure is to
# draw the footage once. We replay this segment's range ONCE â€” fast and uncaptured â€”
# then seek back to SEG_START. Runs BEFORE STEP 2 deliberately: the warm's seek-back
# is a backward seek, and cs2 stalls ~2s after a backward seek ([[seek stall]]); the
# full STEP 2/3/4 lead-in that runs afterward absorbs that stall before capture.
# (Running it after the POV lock instead put the backward seek immediately before
# capture and wrecked the whole segment â€” do not move it.) Gated once per cs2 by a
# marker (one cs2 serves the whole batch â†’ every later job/segment is then warm).
# CLIP_WARMUP=0 disables; CLIP_WARMUP_RATE sets the speed (lower = more thorough).
WARM_MARKER="${CLIP_WARMUP_MARKER:-/tmp/game-streamer/.pipelines-warmed}"
warm_pipelines_if_cold() {
  local start="$1" dur_ms="$2"
  [ "${CLIP_WARMUP:-1}" = "1" ] || return 0
  [ -f "$WARM_MARKER" ] && return 0
  local rate="${CLIP_WARMUP_RATE:-4}"
  [ "$rate" -lt 1 ] 2>/dev/null && rate=1
  local wait_ms=$(( dur_ms / rate + 2000 ))   # cover the range at $rate + compile-spike margin
  # In-world warm only: fast-forward the range so the in-world pipelines (map,
  # effects) compile before the real capture clears the cold opening. We do NOT
  # POV-lock for the first-person viewmodel: deferring the chip render off the
  # capture window (start_chip_render) removed the seg0 stutter, so the viewmodel
  # was never the bottleneck â€” and locking here races the round-transition roster
  # (verify_spec_lock then burns ~8s retrying a stale slot for no gain).
  say "WARM-UP: pre-compiling pipelines â€” replaying ${dur_ms}ms at ${rate}x (~${wait_ms}ms, uncaptured) [once per cs2]"
  spec_post /demo/pause  '{"force": true}'
  spec_post /demo/seek   "{\"tick\": ${start}}"
  spec_post /demo/speed  "{\"rate\": ${rate}}"
  spec_post /demo/toggle '{}'                  # play through the range fast
  sleep "$(awk -v ms="$wait_ms" 'BEGIN{printf "%.2f", ms/1000}')"
  spec_post /demo/pause  '{"force": true}'
  spec_post /demo/speed  '{"rate": 1}'
  spec_post /demo/seek   "{\"tick\": ${start}}"
  mkdir -p "$(dirname "$WARM_MARKER")" 2>/dev/null || true
  : > "$WARM_MARKER"
  say "WARM-UP: done â€” pipelines warmed for this cs2 process"
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

  # Warm the Vulkan pipelines once, BEFORE the seek/lead-in, so the warm's
  # backward seek is absorbed by STEP 2/3/4 before capture (see the function note).
  warm_pipelines_if_cold "$SEG_START" "$SEG_DURATION_MS"

  say "STEP 2: force-pause"
  spec_post /demo/pause '{"force": true}'
  say "STEP 3: seek to $SEG_START"
  spec_post /demo/seek "{\"tick\": ${SEG_START}}"

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

  # Re-pause + re-seek for a deterministic SEG_START (lead-in drifted
  # forward). The re-seek resets cs2's POV, so we re-press the slot below.
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SEG_START}}"
  # Never record at an inherited timescale â€” stale 2x/4x = double-speed clips.
  spec_post /demo/speed '{"rate": 1}'
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

  # Start capture while the demo is still PAUSED at SEG_START, THEN press play.
  # Recording therefore opens exactly at the pre-roll â€” previously we played
  # first and only started capturing after wait-advancing + POV re-press + the
  # ~0.3s gst spawn, during which the demo drifted ~1-2s past SEG_START and ate
  # most of the 3s lead (the kill landed almost immediately). The only frames
  # recorded before playback are the brief held SEG_START frame (gst spawn + the
  # documented post-seek stall); they sit at the very top of the lead-in and
  # STEP 7's phase-clock freeze-withholding keeps them from being billed, so the
  # full pre-roll still plays before the kill.
  say "STEP 6: start capture (paused at $SEG_START) -> $SEG_FILE"
  if ! start_clip_capture "$SEG_FILE" "${CLIP_OUTPUT_FPS:-60}" "${CLIP_VIDEO_KBPS:-24000}" 1; then
    die_failed "clip capture failed to start (segment $SEG_IDX)"
  fi
  say "STEP 6: pid=${CLIP_CAPTURE_PID:-?}"
  start_capture_diag "${CLIP_CAPTURE_PID:-}"

  # Force-pause then toggle â†’ deterministic PLAYING (a bare relative toggle
  # could pause a demo the re-seek left playing).
  say "STEP 5: PRESS PLAY (force-pause then toggle)"
  spec_post /demo/pause '{"force": true}'
  sleep 0.15
  spec_post /demo/toggle '{}'

  # Re-press POV after play; the re-seek reset it and the pre-play re-press
  # no-ops while paused. observer_slot may also have shifted.
  if [ -n "${SEG_POV_STEAMID:-}" ]; then
    POV_SLOT_AFTER_PLAY=$(gsi_slot_for_steamid "$SEG_POV_STEAMID")
    say "STEP 5: re-press slot=${POV_SLOT_AFTER_PLAY:-NONE}; GSI spectated=$(gsi_spectated_steamid)"
    [ -n "$POV_SLOT_AFTER_PLAY" ] && spec_post /spec/slot "{\"slot\": ${POV_SLOT_AFTER_PLAY}}"
  fi
  log_spec_slots "after-play"

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
  now_ms WALLCLOCK_START_MS
  PREV_MS=$WALLCLOCK_START_MS
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
        say "KILL seg$SEG_IDX: POV round_kills ${LAST_POV_KILLS}->${POV_KILLS} at +${CUR_DONE_TICKS}t (${PLAYED_MS}ms played, clock=${PHASE_ENDS:-?})"
      fi
      LAST_POV_KILLS="$POV_KILLS"
    fi

    # Withhold a poll's time ONLY on a real freeze: the GSI phase clock flat in
    # a live round means demo playback stalled (not a player hold). Capped so a
    # missing/odd phase clock can't stretch the tail.
    if [ "$PHASE" = "live" ] && [ -n "$PHASE_ENDS" ] && [ "$PHASE_ENDS" = "$LAST_PHASE_ENDS" ] \
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

        if ! nice -n 10 ffmpeg -y -hide_banner -loglevel warning \
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
    # Empty under vkcapture = the present-hook delivered no frames (e.g. the GTX
    # 980 can't host-map the layer's dmabuf: "mmap(fd0) failed: Invalid argument").
    # ximagesrc needs no dmabuf, so switch the whole render to it and redo this
    # segment. One-shot (VKCAP_FELL_BACK): the failure is per-pod, never thrashes.
    say "WARN segment $SEG_IDX empty under vkcapture (${SEG_BYTES}B) â€” falling back to ximagesrc and retrying"
    CLIP_CAPTURE_METHOD=ximagesrc; export CLIP_CAPTURE_METHOD
    VKCAP_FELL_BACK=1
    rm -f "$SEG_FILE"
    continue   # retry same SEG_IDX (index not advanced)
  else
    say "WARN segment $SEG_IDX is empty/short (${SEG_BYTES}B, ${SEG_REAL_DUR}s) â€” dropping from concat"
    rm -f "$SEG_FILE"
  fi
  ELAPSED_TICKS_TOTAL=$((ELAPSED_TICKS_TOTAL + SEG_TICKS))
  SEG_IDX=$((SEG_IDX + 1))
done

# Recording is DONE â€” render the player chip now (fused path), so the heavy
# Chromium render never competes with cs2 during capture (the seg0-tail jitter).
# No-op when already launched (non-fused path launched it before the loop) or when
# there's no chip. It overlaps the light concat.txt prep below; reaped before STEP 9.
start_chip_render

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

  local outro_matched="$SEG_DIR/outro-matched.mp4"
  local in_args=(-i "$OUTRO_FILE")
  local map_args=(-map 0:v -map 0:a)
  if ! has_audio_stream "$OUTRO_FILE"; then
    in_args+=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000)
    map_args=(-map 0:v -map 1:a -shortest)
  fi
  say "STEP 9: concat fast path â€” transcoding outro to match polished segments"
  if ! ffmpeg -y -hide_banner -loglevel warning \
       "${in_args[@]}" \
       "${map_args[@]}" \
       "${FFMPEG_VENC_ARGS[@]}" \
       -r "${CLIP_OUTPUT_FPS:-60}" \
       -c:a aac -b:a 192k -ar 48000 -ac 2 \
       -movflags +faststart \
       "$outro_matched"; then
    say "  concat: outro transcode failed â€” falling back to re-encode"
    rm -f "$outro_matched"
    return 1
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

  if ! ffmpeg -y -hide_banner -loglevel warning \
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
    say "  concat: stream-copy refused â€” re-encoding"
    if ! ffmpeg -y -hide_banner -loglevel warning \
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
