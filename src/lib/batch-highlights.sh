# shellcheck shell=bash
# Drain CLIP_BATCH_JOBS against the running cs2 demo session. Sourced
# by run-demo.sh when CLIP_BATCH_MODE=1. Per-job failures don't halt
# the batch — the render script POSTs status=error itself. A cs2 engine
# fatal relaunches cs2 (launch_cs2_window in run-demo.sh) and retries the job once.

# JSON parsing flows through node so values can't break the shell.
CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

# Patch the api job title with the GSI-reported player name. The api
# only had steam_id at enqueue, so titles default to "Player NNNN".
patch_title_from_gsi() {
  local job_id="$1" token="$2" target_sid="$3" current_title="$4"
  [ -z "$target_sid" ] && return 0
  [ -z "$current_title" ] && return 0

  local state
  state=$(spec_curl --fail --silent --show-error --max-time 5 \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
    || true)
  [ -z "$state" ] && return 0

  local resolved
  resolved=$(printf '%s' "$state" \
    | node "$CLIP_HELPERS" name-for-steamid "$target_sid")
  [ -z "$resolved" ] && return 0

  local new_title
  new_title=$(printf '%s' "$current_title" \
    | node "$CLIP_HELPERS" patch-player-name "$resolved")
  [ -z "$new_title" ] && return 0
  [ "$new_title" = "$current_title" ] && return 0

  local body
  body=$(node "$CLIP_HELPERS" status-body "title=${new_title}" 2>/dev/null) \
    || return 0
  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${job_id}/title" \
    || say "  WARN title patch failed for $job_id"
}

# Mark one batch job status=error (per-job creds â€” no shared status channel).
batch_fail_job() {
  local job_id="$1" token="$2" reason="$3" body
  body=$(node "$CLIP_HELPERS" status-body "status=error" "error=${reason}" 2>/dev/null) \
    || return 0
  curl --fail --silent --show-error --max-time 10 \
       --retry 3 --retry-connrefused --retry-delay 1 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${job_id}/status" \
    || say "  WARN fail-status post failed for $job_id"
}

# Block until cs2 is render-ready, or return 1 with DEMO_READY_ERROR set:
#   GSI fired at least once → demo is actually loaded (else seek
#     lands on tick 0 of an unloaded demo, captures black)
#   demoui_hidden=true → spec-server delivered the demoui-toggle
#     post-GSI (else first render captures the panorama panel)
# A demo cs2 cannot play (e.g. recorded on an older build) logs
# NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE in console.log and never becomes
# ready. DEMO_READY_TIMEOUT is a backstop for any other never-ready cause
# (the k8s Job has no activeDeadlineSeconds).
wait_demo_ready() {
  DEMO_READY_ERROR=""
  say "waiting for demo-ready (GSI + demoui_hidden)"
  local console_log="$CS2_DIR/game/csgo/console.log"
  local demo_ready_timeout="${DEMO_READY_TIMEOUT:-300}"
  local waited=0 s ready
  while :; do
    s=$(spec_curl --fail --silent --show-error --max-time 5 \
            "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
        || true)
    if [ -n "$s" ]; then
      ready=$(printf '%s' "$s" | node "$CLIP_HELPERS" demoui-hidden)
      [ "$ready" = "1" ] && break
    fi
    if grep -q 'NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE' "$console_log" 2>/dev/null; then
      DEMO_READY_ERROR="demo is incompatible with the current CS2 version and can no longer be rendered"
      return 1
    fi
    if [ "$waited" -ge "$demo_ready_timeout" ]; then
      DEMO_READY_ERROR="cs2 did not load the demo within ${demo_ready_timeout}s; aborting render"
      return 1
    fi
    waited=$((waited + 1))
    [ $((waited % 15)) -eq 0 ] && say "  still waiting (${waited}s)"
    sleep 1
  done
  say "demo ready after ${waited}s"
}

CS2_RELAUNCHES=0

# Replace a cs2 that hit an engine fatal (the sentinel) with a fresh one on the same
# demo, at most CLIP_CS2_RELAUNCH_MAX times per pod. On failure the sentinel stays and
# CS2_RECOVER_ERROR says why, so the remaining jobs fail fast.
recover_cs2_session() {
  local reason max="${CLIP_CS2_RELAUNCH_MAX:-2}"
  reason=$(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)
  CS2_RECOVER_ERROR=""
  if [ "$CS2_RELAUNCHES" -ge "$max" ]; then
    CS2_RECOVER_ERROR="cs2 relaunch limit (${max}) reached"
    say "cs2 engine fatal (${reason:-?}) — ${CS2_RECOVER_ERROR}"
    return 1
  fi
  CS2_RELAUNCHES=$((CS2_RELAUNCHES + 1))
  say "cs2 engine fatal (${reason:-?}) — relaunching cs2 (${CS2_RELAUNCHES}/${max})"
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1 || break
    sleep 0.5
  done
  rm -f /tmp/source_engine_*.lock
  # Without this the old cs2's demoui_hidden passes the demo-ready wait at once and
  # the new cs2's demo bar is never hidden.
  spec_curl --fail --silent --show-error --max-time 5 \
       --header "content-type: application/json" --data '{}' --output /dev/null \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/reset-session" \
    || say "  WARN spec-server session reset failed"
  if ! launch_cs2_window relaunch; then
    CS2_RECOVER_ERROR="cs2 relaunch failed: ${CS2_LAUNCH_ERROR}"
  elif ! wait_demo_ready; then
    CS2_RECOVER_ERROR="cs2 relaunch failed: ${DEMO_READY_ERROR}"
  fi
  if [ -n "$CS2_RECOVER_ERROR" ]; then
    say "  ${CS2_RECOVER_ERROR}"
    return 1
  fi
  rm -f "$CS2_FATAL_SENTINEL" \
        "${CLIP_WARMUP_MARKER:-/tmp/game-streamer/.pipelines-warmed}" \
        "${CLIP_DEMOUI_MARKER:-/tmp/game-streamer/.demoui-verified}"
  say "cs2 relaunched (pid ${CS2_PID:-?})"
}

batch_render_one_job() {
  local job_json="$1"

  # One node spawn for every job field (NUL-separated â€” free-text fields
  # like title can contain anything except NUL, which job-fields strips).
  local -a F=()
  readarray -d '' -t F < <(printf '%s' "$job_json" | node "$CLIP_HELPERS" job-fields)
  local job_id="${F[0]:-}" token="${F[1]:-}" segments="${F[2]:-}" \
        output_dims="${F[3]:-}" output_fps="${F[4]:-}" target_sid="${F[5]:-}" \
        current_title="${F[6]:-}" target_name="${F[7]:-}" target_avatar="${F[8]:-}" \
        kills_count="${F[9]:-}" map_name="${F[10]:-}" round="${F[11]:-}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed job blob"
    return 0
  fi

  if [ -f "$CS2_FATAL_SENTINEL" ] && ! recover_cs2_session; then
    local reason; reason=$(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)
    say "  $job_id: cs2 session dead from earlier fatal — skipping (${reason:-GetClassBaseline})"
    batch_fail_job "$job_id" "$token" "cs2 engine fatal earlier in batch: ${reason:-GetClassBaseline failed}; ${CS2_RECOVER_ERROR}"
    return 0
  fi

  say "batch render: $job_id"
  patch_title_from_gsi "$job_id" "$token" "$target_sid" "$current_title"

  local marker="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/${job_id}.cs2done"
  local attempt=1 retry pid rc
  while :; do
    rm -f "$marker"
    # A render leaves its status to us after a fatal only while a relaunch is still possible.
    retry=0
    if [ "$attempt" = 1 ] && [ "$CS2_RELAUNCHES" -lt "${CLIP_CS2_RELAUNCH_MAX:-2}" ]; then
      retry=1
    fi
    # Subshell so the render trap + env don't leak. MATCH_ID is unset
    # because batch pods don't publish a live match capture.
    (
      export CLIP_RENDER_JOB_ID="$job_id"
      export CLIP_RENDER_TOKEN="$token"
      export CLIP_SEGMENTS="$segments"
      export CLIP_OUTPUT_DIMS="$output_dims"
      export CLIP_OUTPUT_FPS="$output_fps"
      export CLIP_TICK_RATE="${DEMO_TICK_RATE:-64}"
      export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
      export CLIP_DISPLAY_NAME="$target_name"
      export CLIP_DISPLAY_AVATAR="$target_avatar"
      export CLIP_DISPLAY_TARGET_STEAMID="$target_sid"
      export CLIP_DISPLAY_KILLS="$kills_count"
      export CLIP_DISPLAY_MAP="$map_name"
      export CLIP_DISPLAY_ROUND="$round"
      export CLIP_CS2_RELEASE_MARKER="$marker"
      export CLIP_CS2_FATAL_RETRY="$retry"
      unset MATCH_ID
      bash "$LIB_DIR/inline-clip-render.sh"
    ) &
    pid=$!

    # cs2 is only needed until the final concat; the render touches the
    # marker right after, so the next job can seek+capture while this
    # one's thumbnail+upload tail (network/disk only) runs in background.
    if [ "${CLIP_BATCH_TAIL_OVERLAP:-1}" = "1" ]; then
      while kill -0 "$pid" 2>/dev/null && [ ! -f "$marker" ]; do
        sleep 0.5
      done
      if kill -0 "$pid" 2>/dev/null; then
        say "  job $job_id: cs2 released — upload tail continues in background"
        TAIL_PIDS+=("$pid")
        TAIL_JOBS+=("$job_id")
        TAIL_MARKERS+=("$marker")
        return 0
      fi
    fi

    rc=0
    wait "$pid" || rc=$?
    rm -f "$marker"
    if [ "$rc" = "$CS2_FATAL_RETRY_RC" ]; then
      if recover_cs2_session; then
        attempt=2
        say "  job $job_id: retrying on the relaunched cs2"
        continue
      fi
      batch_fail_job "$job_id" "$token" \
        "cs2 engine fatal ($(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)); ${CS2_RECOVER_ERROR}"
    fi
    [ "$rc" = 0 ] || say "  job $job_id failed (others in batch unaffected)"
    return 0
  done
}

# Reap the oldest backgrounded upload tail (FIFO). Failures log the same
# line the serial path used â€” the render POSTs status=error itself.
reap_oldest_tail() {
  [ "${#TAIL_PIDS[@]}" -eq 0 ] && return 0
  local pid="${TAIL_PIDS[0]}" job="${TAIL_JOBS[0]}" marker="${TAIL_MARKERS[0]}"
  wait "$pid" || say "  job $job failed (others in batch unaffected)"
  rm -f "$marker"
  TAIL_PIDS=("${TAIL_PIDS[@]:1}")
  TAIL_JOBS=("${TAIL_JOBS[@]:1}")
  TAIL_MARKERS=("${TAIL_MARKERS[@]:1}")
}

process_batch_jobs() {
  if [ -z "${CLIP_BATCH_JOBS:-}" ]; then
    say "no CLIP_BATCH_JOBS â€” nothing to render"
    return 0
  fi

  rm -f "$CS2_FATAL_SENTINEL"   # fresh session â€” drop any stale fatal marker
  # Fresh cs2 process for this batch â†’ its Vulkan pipelines are cold again. Drop
  # the warm marker so inline-clip-render re-warms on the first segment (see
  # warm_pipelines_if_cold). Keep the path in sync with CLIP_WARMUP_MARKER there.
  rm -f "${CLIP_WARMUP_MARKER:-/tmp/game-streamer/.pipelines-warmed}" \
        "${CLIP_DEMOUI_MARKER:-/tmp/game-streamer/.demoui-verified}"

  local count
  count=$(printf '%s' "$CLIP_BATCH_JOBS" | node "$CLIP_HELPERS" jobs-count)
  say "batch-highlights: ${count} job(s) queued"

  # Resolve the encoder/scaler probes while the demo loads (they land in the per-pod
  # probe cache), so the first segment doesn't spend ~11s starting CUDA after the demo
  # is ready. Backgrounded: any miss just means the segment probes itself.
  ( _ensure_nvenc_pick h264
    case "${CLIP_VIDEO_CODEC:-h264}" in h265|hevc) _ensure_nvenc_pick h265 ;; esac
    _cuda_scale_available ) >/dev/null &
  disown $! 2>/dev/null || true
  # die() broadcasts status=error to every batch job (so the UI shows the reason) and
  # exits so the Job is reaped and the GPU node frees.
  wait_demo_ready || die "$DEMO_READY_ERROR"

  # Backgrounded upload tails (job N uploads while job N+1 captures).
  # Bounded so a slow API can't stack every clip on local disk at once.
  local -a TAIL_PIDS=() TAIL_JOBS=() TAIL_MARKERS=()
  local max_tails="${CLIP_BATCH_MAX_TAILS:-2}"

  local idx
  for idx in $(seq 0 $((count - 1))); do
    local job_json
    if ! job_json=$(printf '%s' "$CLIP_BATCH_JOBS" \
                      | node "$CLIP_HELPERS" jobs-at "$idx"); then
      say "  WARN failed to extract job at index $idx"
      continue
    fi
    while [ "${#TAIL_PIDS[@]}" -ge "$max_tails" ]; do
      say "  ${#TAIL_PIDS[@]} upload tail(s) pending â€” reaping oldest before next job"
      reap_oldest_tail
    done
    batch_render_one_job "$job_json"
  done

  while [ "${#TAIL_PIDS[@]}" -gt 0 ]; do
    say "waiting on ${#TAIL_PIDS[@]} upload tail(s)"
    reap_oldest_tail
  done

  say "batch-highlights: drained ${count} job(s) â€” exiting"
}
