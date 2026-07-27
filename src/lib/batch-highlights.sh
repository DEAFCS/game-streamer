# shellcheck shell=bash
# Drain CLIP_BATCH_JOBS against the running cs2 demo session. Sourced
# by run-demo.sh when CLIP_BATCH_MODE=1. Per-job failures don't halt
# the batch â€” the render script POSTs status=error itself.

# JSON parsing flows through node so values can't break the shell.
CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

# Patch the api job title with the GSI-reported player name. The api
# only had steam_id at enqueue, so titles default to "Player NNNN".
patch_title_from_gsi() {
  local job_id="$1" token="$2" target_sid="$3" current_title="$4"
  [ -z "$target_sid" ] && return 0
  [ -z "$current_title" ] && return 0

  local state
  state=$(curl --fail --silent --show-error --max-time 5 \
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

  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$(printf '{"title": "%s"}' "${new_title//\"/\\\"}")" \
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
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${job_id}/status" \
    || say "  WARN fail-status post failed for $job_id"
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

  # Session already dead from an earlier fatal â€” fail fast, don't capture frozen.
  if [ -f "$CS2_FATAL_SENTINEL" ]; then
    local reason; reason=$(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)
    say "  $job_id: cs2 session dead from earlier fatal â€” skipping (${reason:-GetClassBaseline})"
    batch_fail_job "$job_id" "$token" "cs2 engine fatal earlier in batch: ${reason:-GetClassBaseline failed}"
    return 0
  fi

  say "batch render: $job_id"
  patch_title_from_gsi "$job_id" "$token" "$target_sid" "$current_title"

  # Subshell so the render trap + env don't leak. MATCH_ID is unset
  # because batch pods don't publish a live match capture.
  local marker="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/${job_id}.cs2done"
  rm -f "$marker"
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
    unset MATCH_ID
    bash "$LIB_DIR/inline-clip-render.sh"
  ) &
  local pid=$!

  if [ "${CLIP_BATCH_TAIL_OVERLAP:-1}" != "1" ]; then
    wait "$pid" || say "  job $job_id failed (others in batch unaffected)"
    rm -f "$marker"
    return 0
  fi

  # cs2 is only needed until the final concat; the render touches the
  # marker right after, so the next job can seek+capture while this
  # one's thumbnail+upload tail (network/disk only) runs in background.
  while kill -0 "$pid" 2>/dev/null && [ ! -f "$marker" ]; do
    sleep 0.5
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || say "  job $job_id failed (others in batch unaffected)"
    rm -f "$marker"
    return 0
  fi
  say "  job $job_id: cs2 released â€” upload tail continues in background"
  TAIL_PIDS+=("$pid")
  TAIL_JOBS+=("$job_id")
  TAIL_MARKERS+=("$marker")
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
  rm -f "${CLIP_WARMUP_MARKER:-/tmp/game-streamer/.pipelines-warmed}"

  local count
  count=$(printf '%s' "$CLIP_BATCH_JOBS" | node "$CLIP_HELPERS" jobs-count)
  say "batch-highlights: ${count} job(s) queued"

  # Wait for cs2 to be render-ready:
  #   GSI fired at least once â†’ demo is actually loaded (else seek
  #     lands on tick 0 of an unloaded demo, captures black)
  #   demoui_hidden=true â†’ spec-server delivered the demoui-toggle
  #     post-GSI (else first render captures the panorama panel)
  # Fail fast instead of hanging here forever: this loop otherwise has
  # no ceiling (the k8s Job has no activeDeadlineSeconds). A demo cs2
  # cannot play (e.g. recorded on an older build) logs
  # NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE in console.log and never
  # becomes ready; die() broadcasts status=error to every batch job (so
  # the UI shows the reason) and exits so the Job is reaped and the GPU
  # node frees. DEMO_READY_TIMEOUT is a backstop for any other
  # never-ready cause.
  say "waiting for demo-ready (GSI + demoui_hidden)"
  local console_log="$CS2_DIR/game/csgo/console.log"
  local demo_ready_timeout="${DEMO_READY_TIMEOUT:-300}"
  local waited=0
  while :; do
    local s ready
    s=$(curl --fail --silent --show-error --max-time 5 \
            "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
        || true)
    if [ -n "$s" ]; then
      ready=$(printf '%s' "$s" | node "$CLIP_HELPERS" demoui-hidden)
      [ "$ready" = "1" ] && break
    fi
    if grep -q 'NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE' "$console_log" 2>/dev/null; then
      die "demo is incompatible with the current CS2 version and can no longer be rendered"
    fi
    if [ "$waited" -ge "$demo_ready_timeout" ]; then
      die "cs2 did not load the demo within ${demo_ready_timeout}s; aborting render"
    fi
    waited=$((waited + 1))
    [ $((waited % 15)) -eq 0 ] && say "  still waiting (${waited}s)"
    sleep 1
  done
  say "demo ready after ${waited}s"

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
