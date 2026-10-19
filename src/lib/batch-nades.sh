# shellcheck shell=bash
# Drain NADE_BATCH_JOBS against one running cs2 connected to one nade practice
# server, then keep asking the api for more until it says stop: the rest of
# the map's queue, and the other maps' once the server has changed level.
# Sourced by run-nades.sh. Per-job failures never halt the batch —
# nade-clip.sh posts its own terminal status.
#
# NADE_BATCH_JOBS is a JSON array; each entry is
#   { "job_id": "<uuid>", "token": "<session token>", "spec": { ... } }
# and spec carries the utility_lineups row the pod needs (column names verbatim):
#   lineup_id, lineup_name, map_name, nade_type ("Smoke"|"Flash"|
#   "HighExplosive"|"Molotov"|"Decoy"), side, origin_x/y/z, eye_z, view_yaw,
#   view_pitch, flight_time_ms, confidence, plugin_runtime, technique,
#   throw_strength, jump_throw_bind, and either has_seed:true|false or the six
#   initial_pos_*/initial_vel_* values, approach (the run-up's 64Hz samples,
#   null for a throw made standing still), plus
#   output: { resolution: "720p"|"1080p", fps: <int> }.
#
# The practice plugin stages a lineup by lineup_id (`/render_stage <id>`).

CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

: "${NADE_SESSION_READY_TIMEOUT:=300}"
: "${NADE_BATCH_MAX_TAILS:=2}"
: "${NADE_BATCH_TAIL_OVERLAP:=1}"
# An api being redeployed refuses connections for the better part of a
# minute. Giving up sooner ends the pod over a restart, and the queue then
# pays for a server and a cs2 boot to carry on.
: "${NADE_NEXT_RETRIES:=15}"
: "${NADE_NEXT_RETRY_SECONDS:=5}"
# This many lineups failing in a row is the client, not the lineups: cs2 has
# crashed or been dropped, and every lineup after would wait out its staging
# timeout to fail the same way while the GPU and the server sit held.
: "${NADE_MAX_CONSECUTIVE_FAILURES:=3}"
# A workshop map is downloaded on the way in, so this is not a load-screen
# figure; the api gives up on the level at about the same point.
: "${NADE_MAP_CHANGE_TIMEOUT:=240}"

nade_post_job_status() {
  local job_id="$1" token="$2"; shift 2
  local body
  body=$(node "$CLIP_HELPERS" status-body "$@" 2>/dev/null) || return 0
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${job_id}/status" \
    || say "  WARN status post failed for $job_id"
}

nade_fail_job() {
  nade_post_job_status "$1" "$2" "status=error" "error=$3"
}

nade_skip_job() {
  nade_post_job_status "$1" "$2" "status=${NADE_SKIP_STATUS:-skipped}" \
    "skip_reason=$3" "error=$3"
}

# NADE_LAST_JOB_OK says whether cs2 got the lineup filmed: 1 once the render
# has let cs2 go (or skipped the lineup on purpose), 0 when it failed first.
# The upload that follows is not this client's doing either way.
NADE_LAST_JOB_OK=1
nade_render_one_job() {
  local job_json="$1"
  NADE_LAST_JOB_OK=0

  local -a F=()
  readarray -d '' -t F < <(printf '%s' "$job_json" | node "$CLIP_HELPERS" nade-fields)
  local job_id="${F[0]:-}" token="${F[1]:-}" lineup_id="${F[2]:-}" \
        lineup_name="${F[3]:-}" map_name="${F[4]:-}" nade_type="${F[5]:-}" \
        side="${F[6]:-}" origin="${F[7]:-}" eye_z="${F[8]:-}" \
        view_yaw="${F[9]:-}" view_pitch="${F[10]:-}" flight_ms="${F[11]:-0}" \
        has_seed="${F[12]:-0}" confidence="${F[13]:-}" runtime="${F[14]:-}" \
        output_dims="${F[15]:-}" output_fps="${F[16]:-}" \
        technique="${F[17]:-}" throw_strength="${F[18]:-}" jump_bind="${F[19]:-0}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed nade job blob"
    return 0
  fi
  if [ -z "$lineup_id" ]; then
    say "  $job_id: job has no lineup id"
    nade_fail_job "$job_id" "$token" "render job has no lineup id"
    return 0
  fi
  # A lineup for a map the server is not on can't be filmed. The api only ever
  # hands over the map the server is on, and nade_drain_queue follows a level
  # change before it gets here, so this is a list that was wrong at booking.
  if [ -n "$map_name" ] && [ -n "$NADE_SESSION_MAP" ] && ! nade_same_map "$map_name" "$NADE_SESSION_MAP"; then
    say "  $job_id: lineup is on ${map_name}, this session is on ${NADE_SESSION_MAP} — skipping"
    nade_skip_job "$job_id" "$token" "practice server is on ${NADE_SESSION_MAP}, lineup needs ${map_name}"
    return 0
  fi
  if [ -f "$CS2_FATAL_SENTINEL" ]; then
    local reason; reason=$(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)
    say "  $job_id: cs2 session dead from an earlier fatal — skipping (${reason:-unknown})"
    nade_fail_job "$job_id" "$token" "cs2 fatal earlier in batch: ${reason:-unknown}"
    return 0
  fi

  say "nade render: $job_id (${lineup_id} ${lineup_name})"

  local marker="${NADE_OUT_DIR:-/tmp/game-streamer/nades}/${job_id}.cs2done"
  rm -f "$marker"
  local approach_file="${NADE_OUT_DIR:-/tmp/game-streamer/nades}/${job_id}.approach.json"
  printf '%s' "$job_json" | node "$CLIP_HELPERS" nade-approach >"$approach_file" \
    || : >"$approach_file"
  (
    export NADE_RENDER_JOB_ID="$job_id"
    export NADE_RENDER_TOKEN="$token"
    export NADE_LINEUP_ID="$lineup_id"
    export NADE_LINEUP_NAME="$lineup_name"
    export NADE_MAP_NAME="$map_name"
    export NADE_NADE_TYPE="$nade_type"
    export NADE_SIDE="$side"
    export NADE_ORIGIN="$origin"
    export NADE_EYE_Z="$eye_z"
    export NADE_VIEW_YAW="$view_yaw"
    export NADE_VIEW_PITCH="$view_pitch"
    export NADE_FLIGHT_TIME_MS="$flight_ms"
    export NADE_HAS_SEED="$has_seed"
    export NADE_CONFIDENCE="$confidence"
    export NADE_PLUGIN_RUNTIME="${runtime:-${NADE_PLUGIN_RUNTIME:-swiftlys2}}"
    export NADE_OUTPUT_DIMS="$output_dims"
    export NADE_OUTPUT_FPS="$output_fps"
    export NADE_TECHNIQUE="$technique"
    export NADE_THROW_STRENGTH="$throw_strength"
    export NADE_JUMP_THROW_BIND="$jump_bind"
    export NADE_APPROACH_FILE="$approach_file"
    export NADE_CS2_RELEASE_MARKER="$marker"
    export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
    bash "$LIB_DIR/nade-clip.sh"
  ) &
  local pid=$!

  if [ "$NADE_BATCH_TAIL_OVERLAP" != "1" ]; then
    if wait "$pid"; then
      NADE_LAST_JOB_OK=1
    else
      say "  job $job_id failed (others in batch unaffected)"
    fi
    rm -f "$marker"
    return 0
  fi

  # cs2 is only needed up to the encode; the render touches the marker right
  # after, so the next lineup can be loaded while this one uploads.
  while kill -0 "$pid" 2>/dev/null && [ ! -f "$marker" ]; do
    sleep 0.5
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    if wait "$pid"; then
      NADE_LAST_JOB_OK=1
    else
      say "  job $job_id failed (others in batch unaffected)"
    fi
    rm -f "$marker"
    return 0
  fi
  NADE_LAST_JOB_OK=1
  say "  job $job_id: cs2 released — upload tail continues in background"
  TAIL_PIDS+=("$pid")
  TAIL_JOBS+=("$job_id")
  TAIL_MARKERS+=("$marker")
}

reap_oldest_nade_tail() {
  [ "${#TAIL_PIDS[@]}" -eq 0 ] && return 0
  local pid="${TAIL_PIDS[0]}" job="${TAIL_JOBS[0]}" marker="${TAIL_MARKERS[0]}"
  wait "$pid" || say "  job $job failed (others in batch unaffected)"
  rm -f "$marker"
  TAIL_PIDS=("${TAIL_PIDS[@]:1}")
  TAIL_JOBS=("${TAIL_JOBS[@]:1}")
  TAIL_MARKERS=("${TAIL_MARKERS[@]:1}")
}

# A connecting client lands in team select and stays there: the practice plugin
# only reacts to OnPlayerJoinTeam, it never assigns one, and the pod is on
# nobody's roster. Somebody has to press a team.
#
# That somebody used to be nade-clip.sh's join_if_not_spawned -- but that runs
# inside a job, and no job starts until the gate below reports a spawned player.
# The gate waited for a spawn that only a job could cause, so it always ran out
# the clock and died "never spawned ... stuck in team select". Joining here is
# what breaks the cycle; the per-job join still covers a mid-batch death.
# NEVER press this while already alive: jointeam on a live pawn respawns it, so
# a re-press loop that ignores health kills the player on a loop. The gate can
# sit here with health>0 whenever some OTHER condition is holding it up (a stale
# GSI reading, say), which is exactly when an unguarded re-press does damage.
nade_join_team() {
  local self health
  self=$(spec_curl --fail --silent --max-time 5 \
    "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || true)
  if [ -n "$self" ]; then
    IFS='|' read -r _age _sid _team health _rest <<<"$self"
    case "${health:-0}" in
      ''|*[!0-9]*) ;;
      *) [ "$health" -gt 0 ] && return 0 ;;
    esac
  fi
  spec_curl --fail --silent --max-time 5 \
       --header "content-type: application/json" \
       --data "{\"cmd\": \"jointeam ${NADE_BATCH_JOIN_TEAM:-3}\"}" \
       --output /dev/null \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/exec" || true
}

# The gate's black-box breaker. Zero GSI can mean "in the menu", "kicked", or
# "in team select with the exec keystrokes landing nowhere" -- three different
# bugs. CS2's own console (-condebug) tells them apart, and `status` printing
# there at all proves the exec-cfg keystroke path works: the command travels
# spec-server -> cfg file -> BACKSPACE keybind -> console, so its output is a
# health check of the whole chain, not just a connection report.
NADE_GATE_LOG_OFFSET=0
nade_gate_probe() {
  spec_curl --fail --silent --max-time 5 \
       --header "content-type: application/json" \
       --data '{"cmd": "status"}' \
       --output /dev/null \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/exec" || true
  sleep 2
  local log="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}"
  if [ ! -f "$log" ]; then
    say "  console.log missing — -condebug is not writing, cs2 may not be up"
    return 0
  fi
  local size
  size=$(stat -c %s "$log" 2>/dev/null || echo 0)
  if [ "$size" -le "$NADE_GATE_LOG_OFFSET" ]; then
    say "  console silent since last probe — the status keystroke is not reaching cs2 (window focus?)"
    return 0
  fi
  say "  console tail:"
  tail -c +$((NADE_GATE_LOG_OFFSET + 1)) "$log" | tail -n 8 | sed 's/^/    | /' 1>&2
  NADE_GATE_LOG_OFFSET=$size
  # And the other half of the gate's condition, so a log reads "in the map
  # per console, no GSI per spec-server" without anyone having to correlate.
  local self
  self=$(spec_curl --fail --silent --max-time 5 "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || echo "unreachable")
  say "  gsi self  (age|steam|team|health|activity|pos|fwd): ${self}"
}

# The boot-time connect (+connect launch arg and the autoexec both) fires
# exactly once, before the client is fully up -- if it misses, the client sits
# in the main menu and nothing else retries. While GSI has NEVER fired (age -1)
# the gate may re-issue it.
#
# STRICTLY CAPPED: a client that DID connect but whose GSI is misconfigured also
# reads age -1, and re-issuing connect there reconnects a joined client over and
# over -- cs2 counts each rejoin as a suicide and kicks it "for suiciding too
# many times". A couple of nudges for a genuinely-missed connect is worth it; an
# unbounded loop is what turned a bad GSI cfg into a suicide kick. A late clip
# beats a kicked one, so after the cap we just wait out the gate.
NADE_RECONNECT_ATTEMPTS=0
nade_reconnect() {
  [ -n "${CS2_CONNECT_ADDR:-}" ] || return 0
  [ "$NADE_RECONNECT_ATTEMPTS" -ge "${NADE_RECONNECT_MAX:-2}" ] && return 0
  local line age
  line=$(spec_curl --fail --silent --max-time 5 \
    "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || true)
  IFS='|' read -r age _rest <<<"$line"
  [ "${age:-'-1'}" = "-1" ] || return 0
  NADE_RECONNECT_ATTEMPTS=$((NADE_RECONNECT_ATTEMPTS + 1))
  say "  no GSI yet — re-issuing connect to ${CS2_CONNECT_ADDR} (attempt ${NADE_RECONNECT_ATTEMPTS}/${NADE_RECONNECT_MAX:-2})"
  spec_curl --fail --silent --max-time 5 \
       --header "content-type: application/json" \
       --data "{\"cmd\": \"password \\\"${CS2_CONNECT_PASSWORD:-}\\\"; connect ${CS2_CONNECT_ADDR}\"}" \
       --output /dev/null \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/exec" || true
}

# A client the server DROPPED sits at the main menu behind a dialog. GSI has
# already fired by then, so nade_reconnect leaves it alone and the gate would
# wait out its whole timeout: seen when the client stalled entering the map
# and the server closed its netchan for overflow. The drop is in the client's
# own console, and a dropped client has nothing to lose from a reconnect --
# capped all the same.
NADE_DROP_RECONNECTS=0
NADE_DROP_MARK=0
nade_reconnect_if_dropped() {
  local log="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}" total reason
  [ -n "${CS2_CONNECT_ADDR:-}" ] || return 0
  [ -f "$log" ] || return 0
  total=$(wc -l <"$log" 2>/dev/null || echo 0)
  [ "$total" -gt "$NADE_DROP_MARK" ] || return 0
  reason=$(tail -n +"$((NADE_DROP_MARK + 1))" "$log" | tr -d '\r' \
    | grep -aoE "NETWORK_DISCONNECT_[A-Z_]+|Overflow error|Disconnected from server" | tail -n 1)
  NADE_DROP_MARK="$total"
  [ -n "$reason" ] || return 0
  if [ "$NADE_DROP_RECONNECTS" -ge "${NADE_DROP_RECONNECT_MAX:-2}" ]; then
    say "  dropped by the server again (${reason}) — out of reconnects"
    return 0
  fi
  NADE_DROP_RECONNECTS=$((NADE_DROP_RECONNECTS + 1))
  say "  dropped by the server (${reason}) — reconnecting (${NADE_DROP_RECONNECTS}/${NADE_DROP_RECONNECT_MAX:-2})"
  spec_curl --fail --silent --max-time 5 \
       --header "content-type: application/json" \
       --data "{\"cmd\": \"password \\\"${CS2_CONNECT_PASSWORD:-}\\\"; connect ${CS2_CONNECT_ADDR}\"}" \
       --output /dev/null \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/exec" || true
}

# Same side mapping nade-clip.sh uses, read off the batch's first lineup so the
# opening spawn is already on the right side.
nade_batch_join_team() {
  printf '%s' "${NADE_BATCH_JOBS:-}" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let team = "3";
      try {
        const side = String(JSON.parse(s)?.[0]?.spec?.side ?? "");
        if (/^t/i.test(side)) team = "2";
      } catch {}
      process.stdout.write(team);
    });
  ' 2>/dev/null || printf '3'
}

nade_gsi_map() {
  spec_curl --fail --silent --max-time 5 \
      "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s)?.gsi?.map_name??"")}catch{}})' \
    || true
}

# GSI names a workshop level by its path and the api by its name, so two maps
# are the same when they end the same.
nade_same_map() {
  local a="${1##*/}" b="${2##*/}"
  [ -n "$a" ] && [ "${a,,}" = "${b,,}" ]
}

# The practice server is changing level under this client. cs2 follows a
# changelevel by itself; the pod's part is to notice it has arrived, get
# spawned again, and not film a load screen. "Arrived" is GSI naming a map
# other than the one it was on -- never a match against the target's name,
# which the two sides spell differently for a workshop map.
nade_follow_map() {
  local target="$1" from="$NADE_SESSION_MAP" waited=0 line age health map_name
  if nade_same_map "$target" "$from"; then
    return 0
  fi
  say "practice server is moving to ${target} (from ${from:-?})"
  # Whatever the console printed up to now is not about this change, and a
  # level change says "disconnect" about itself: only a client still not there
  # after a load screen's worth of waiting is one the server dropped.
  local log="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}"
  NADE_DROP_RECONNECTS=0
  NADE_DROP_MARK=$(wc -l <"$log" 2>/dev/null || echo 0)
  while :; do
    line=$(spec_curl --fail --silent --max-time 5 "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || true)
    if [ -n "$line" ]; then
      IFS='|' read -r age _sid _team health _rest <<<"$line"
      case "$age" in
        ''|-1|*[!0-9]*) ;;
        *)
          if [ "$age" -le "${NADE_GSI_MAX_AGE_MS:-2000}" ]; then
            map_name=$(nade_gsi_map)
            if [ -n "$map_name" ] && [ "$map_name" != "$from" ]; then
              if [ "${health:-0}" -gt 0 ] 2>/dev/null; then
                NADE_SESSION_MAP="$map_name"
                say "on ${NADE_SESSION_MAP} after ${waited}s"
                return 0
              fi
              # On the new level and back in team select. Only pressed here:
              # on the old level a live pawn would be respawned by it.
              [ $((waited % "${NADE_JOIN_RETRY_SECONDS:-5}")) -eq 0 ] && nade_join_team
            fi
          fi
          ;;
      esac
    fi
    if [ "$waited" -ge "$NADE_MAP_CHANGE_TIMEOUT" ]; then
      say "never arrived on ${target} within ${NADE_MAP_CHANGE_TIMEOUT}s"
      return 1
    fi
    waited=$((waited + 1))
    if [ $((waited % 15)) -eq 0 ]; then
      say "  still changing level (${waited}s)"
      nade_gate_probe
    fi
    if [ "$waited" -ge "${NADE_MAP_CHANGE_RECONNECT_AFTER:-90}" ] && [ $((waited % 15)) -eq 0 ]; then
      nade_reconnect_if_dropped
    fi
    sleep 1
  done
}

# What to film after the list this pod was booked with. The api answers per
# request, so a lineup approved while this pod was filming is its next one and
# a queue on another map is a level change rather than a second boot.
#
# The practice match's own id and password are the credential: the pod has no
# render token for a lineup it has not been given yet.
#
# Anything but a 200 is a stop. An api that has never heard of the route
# expects the pod to exit after its list, which is what it used to do.
NEXT_ACTION="done" NEXT_MAP="" NEXT_SECONDS=0 NEXT_JOBS="[]"
nade_next() {
  NEXT_ACTION="done" NEXT_MAP="" NEXT_SECONDS=0 NEXT_JOBS="[]"
  if [ -z "${MATCH_ID:-}" ] || [ -z "${STATUS_API_BASE:-}" ]; then
    return 0
  fi
  local body="${NADE_OUT_DIR:-/tmp/game-streamer/nades}/next.json" code attempt
  local -a N=()
  for attempt in $(seq 1 "$NADE_NEXT_RETRIES"); do
    code=$(curl --silent --max-time 30 --request POST \
        --header "x-origin-auth: ${MATCH_ID}:${CS2_CONNECT_PASSWORD:-}" \
        --output "$body" --write-out '%{http_code}' \
        "${STATUS_API_BASE}/nade-render-queue/${MATCH_ID}/next" 2>/dev/null) || code=000
    case "$code" in
      200)
        readarray -d '' -t N < <(node "$CLIP_HELPERS" nade-next <"$body")
        NEXT_ACTION="${N[0]:-done}" NEXT_MAP="${N[1]:-}"
        NEXT_SECONDS="${N[2]:-0}" NEXT_JOBS="${N[3]:-[]}"
        return 0
        ;;
      000|5??)
        say "  could not ask the api what is next (http ${code}, attempt ${attempt}/${NADE_NEXT_RETRIES})"
        sleep "$NADE_NEXT_RETRY_SECONDS"
        ;;
      *)
        say "  the api has nothing more for this pod (http ${code})"
        return 0
        ;;
    esac
  done
  return 0
}

# Film whatever the api hands over until it says stop. TAIL_* belong to
# process_nade_jobs, which calls this.
nade_drain_queue() {
  local count idx job_json job_id token map_name failures=0
  local -a F=()
  while :; do
    # Nothing in this flow writes the fatal sentinel, so the process itself is
    # what says cs2 is gone.
    if [ -f "$CS2_FATAL_SENTINEL" ] \
       || { [ -n "${CS2_PID:-}" ] && ! kill -0 "$CS2_PID" 2>/dev/null; }; then
      say "cs2 is gone — not asking for more"
      return 0
    fi
    if [ "$failures" -ge "$NADE_MAX_CONSECUTIVE_FAILURES" ]; then
      say "${failures} lineups failed in a row — stopping so the queue gets a fresh client"
      return 0
    fi
    nade_next
    case "$NEXT_ACTION" in
      render)
        count=$(printf '%s' "$NEXT_JOBS" | node "$CLIP_HELPERS" jobs-count)
        for idx in $(seq 0 $((count - 1))); do
          job_json=$(printf '%s' "$NEXT_JOBS" | node "$CLIP_HELPERS" jobs-at "$idx") || continue
          F=()
          readarray -d '' -t F < <(printf '%s' "$job_json" | node "$CLIP_HELPERS" nade-fields)
          job_id="${F[0]:-}" token="${F[1]:-}" map_name="${F[4]:-}"
          # The answer that announced a level change can be lost on the way
          # back; the lineup it was for arrives all the same.
          if [ -n "$map_name" ] && ! nade_same_map "$map_name" "$NADE_SESSION_MAP"; then
            if ! nade_follow_map "$map_name"; then
              [ -n "$job_id" ] && [ -n "$token" ] \
                && nade_fail_job "$job_id" "$token" "the render client never arrived on ${map_name}"
              return 0
            fi
          fi
          while [ "${#TAIL_PIDS[@]}" -ge "$NADE_BATCH_MAX_TAILS" ]; do
            say "  ${#TAIL_PIDS[@]} upload tail(s) pending — reaping oldest before the next lineup"
            reap_oldest_nade_tail
          done
          nade_render_one_job "$job_json"
          NADE_DRAINED=$((NADE_DRAINED + 1))
          if [ "$NADE_LAST_JOB_OK" = "1" ]; then
            failures=0
          else
            failures=$((failures + 1))
          fi
        done
        ;;
      map)
        nade_follow_map "$NEXT_MAP" || return 0
        ;;
      wait)
        sleep "$NEXT_SECONDS"
        ;;
      *)
        return 0
        ;;
    esac
  done
}

# Connected, in-game and alive is the only state in which a lineup can be
# staged, so the batch waits for GSI to say so before the first lineup.
# die() fans the failure out to every job, so a server that never comes up is
# reported per-lineup instead of leaving rows stuck in-flight.
wait_for_nade_session() {
  local waited=0 line age health map_name
  NADE_SESSION_MAP=""
  NADE_BATCH_JOIN_TEAM=$(nade_batch_join_team)
  say "waiting for the practice server (GSI + spawned player)"
  say "  joining team ${NADE_BATCH_JOIN_TEAM} (nothing else does)"
  while :; do
    line=$(spec_curl --fail --silent --max-time 5 "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || true)
    if [ -n "$line" ]; then
      IFS='|' read -r age _sid _team health _rest <<<"$line"
      case "$age" in
        ''|-1|*[!0-9]*) ;;
        *)
          if [ "$age" -le "${NADE_GSI_MAX_AGE_MS:-2000}" ] \
             && [ "${health:-0}" -gt 0 ] 2>/dev/null; then
            map_name=$(nade_gsi_map)
            NADE_SESSION_MAP="$map_name"
            say "practice server ready after ${waited}s (map=${NADE_SESSION_MAP:-?})"
            return 0
          fi
          ;;
      esac
    fi
    if [ "$waited" -ge "$NADE_SESSION_READY_TIMEOUT" ]; then
      # The console tail is the diagnosis; the guesses are only for a log that
      # never got written.
      local postmortem="" gate_log="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}"
      if [ -f "$gate_log" ]; then
        postmortem=$(tail -n 5 "$gate_log" | tr '\n' ';' | cut -c1-260)
      fi
      if [ -n "$postmortem" ]; then
        die "never spawned on the practice server within ${NADE_SESSION_READY_TIMEOUT}s — console: ${postmortem}"
      fi
      die "never spawned on the practice server within ${NADE_SESSION_READY_TIMEOUT}s (wrong password, server down, or the client is stuck in team select)"
    fi
    waited=$((waited + 1))
    # Re-press rather than fire once: the first attempt can land before the
    # client is far enough through connecting for the command to take.
    [ $((waited % "${NADE_JOIN_RETRY_SECONDS:-5}")) -eq 0 ] && nade_join_team
    if [ $((waited % 15)) -eq 0 ]; then
      say "  still waiting (${waited}s)"
      nade_gate_probe
    fi
    [ $((waited % 45)) -eq 0 ] && nade_reconnect
    [ $((waited % 5)) -eq 0 ] && nade_reconnect_if_dropped
    sleep 1
  done
}

process_nade_jobs() {
  if [ -z "${NADE_BATCH_JOBS:-}" ]; then
    say "no NADE_BATCH_JOBS — nothing to render"
    return 0
  fi

  rm -f "$CS2_FATAL_SENTINEL"
  mkdir -p "${NADE_OUT_DIR:-/tmp/game-streamer/nades}"

  local count
  count=$(printf '%s' "$NADE_BATCH_JOBS" | node "$CLIP_HELPERS" jobs-count)
  say "batch-nades: ${count} lineup(s) queued"

  wait_for_nade_session

  # An X grab every few seconds stalls cs2's present, and that hitch would be
  # filmed. NADE_KEEP_SNAPSHOTS=1 keeps it for debugging a batch.
  if [ "${NADE_KEEP_SNAPSHOTS:-0}" != "1" ]; then
    stop_snapshot_loop
  fi

  local -a TAIL_PIDS=() TAIL_JOBS=() TAIL_MARKERS=()
  local idx job_json
  for idx in $(seq 0 $((count - 1))); do
    if ! job_json=$(printf '%s' "$NADE_BATCH_JOBS" \
                      | node "$CLIP_HELPERS" jobs-at "$idx"); then
      say "  WARN failed to extract nade job at index $idx"
      continue
    fi
    while [ "${#TAIL_PIDS[@]}" -ge "$NADE_BATCH_MAX_TAILS" ]; do
      say "  ${#TAIL_PIDS[@]} upload tail(s) pending — reaping oldest before the next lineup"
      reap_oldest_nade_tail
    done
    nade_render_one_job "$job_json"
  done

  NADE_DRAINED=$count
  nade_drain_queue

  while [ "${#TAIL_PIDS[@]}" -gt 0 ]; do
    say "waiting on ${#TAIL_PIDS[@]} upload tail(s)"
    reap_oldest_nade_tail
  done

  say "batch-nades: drained ${NADE_DRAINED} lineup(s) — exiting"
}
