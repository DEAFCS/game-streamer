# shellcheck shell=bash
# Posts streamer-pod status to the 5stack api. A background daemon owns
# the latest-desired-state file; report_status updates it atomically;
# the daemon's next loop POSTs whatever's newest. There is no queue â€”
# intermediate states are dropped silently.
#
# POST ${STATUS_API_BASE}/game-streamer/${MATCH_ID}/status
# auth: x-origin-auth: ${MATCH_ID}:${MATCH_PASSWORD}
# body: flat JSON, e.g. {"status":"live","stream_url":"..."}
#
# Demo flow uses STATUS_REPORT_URL override (POSTs to
# /demo-sessions/:id/status instead). That endpoint is cluster-internal
# and unauthenticated, so no per-session token is sent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Default cluster DNS short-name resolves on the pod's search domain.
# Exported so node children (spec-server) see it.
: "${STATUS_API_BASE:=http://api:5585}"
export STATUS_API_BASE

: "${STATUS_REPORT_URL:=}"
: "${STATUS_AUTH_TOKEN:=}"
: "${MATCH_ID:=}"
: "${MATCH_PASSWORD:=}"

# Fall back to the connect-password env vars the api already injects.
#   CONNECT_TV_PASSWORD = raw password (TV port mode)
#   CONNECT_PASSWORD    = "tv:<role>:<password>" (strip the prefix)
if [ -z "$MATCH_PASSWORD" ]; then
  if [ -n "${CONNECT_TV_PASSWORD:-}" ]; then
    MATCH_PASSWORD="$CONNECT_TV_PASSWORD"
  elif [ -n "${CONNECT_PASSWORD:-}" ]; then
    MATCH_PASSWORD="${CONNECT_PASSWORD#tv:*:}"
  fi
fi
: "${STATUS_STATE_FILE:=$LOG_DIR/status.state}"
: "${STATUS_ACK_FILE:=$LOG_DIR/status.ack}"
: "${STATUS_DAEMON_PID_FILE:=$LOG_DIR/status.daemon.pid}"
: "${STATUS_POLL_SECONDS:=2}"
: "${STATUS_BOOT_FILE:=$LOG_DIR/status.boot.epoch}"
: "${STATUS_LAST_FILE:=$LOG_DIR/status.last}"

# Auto-promote demo-session env to the override channel â€” whichever
# script starts the reporter first picks up the right wiring.
_promote_demo_session_env() {
  if [ -z "$STATUS_REPORT_URL" ] && [ -n "${DEMO_SESSION_ID:-}" ]; then
    export STATUS_REPORT_URL="${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/status"
    # Endpoint is unauthenticated; send the session id as the auth value
    # only so the daemon's config gate (needs a non-empty token) passes.
    export STATUS_AUTH_TOKEN="${DEMO_SESSION_ID}"
  fi
}

# warm-shaders has no MATCH_PASSWORD; route its progress to the node endpoint.
_promote_bake_env() {
  if [ -z "$STATUS_REPORT_URL" ] && [ -n "${BAKE_NODE_ID:-}" ]; then
    export STATUS_REPORT_URL="${STATUS_API_BASE}/game-server-nodes/${BAKE_NODE_ID}/bake-status"
    export STATUS_AUTH_TOKEN="${BAKE_NODE_ID}"
  fi
}

_status_reporter_configured() {
  _promote_demo_session_env
  _promote_bake_env
  if [ -n "$STATUS_REPORT_URL" ] && [ -n "$STATUS_AUTH_TOKEN" ]; then
    return 0
  fi
  [ -n "$MATCH_ID" ] && [ -n "$MATCH_PASSWORD" ]
}

# True when this pod is processing a batch of highlight render jobs.
_in_batch_broadcast_mode() {
  [ "${CLIP_BATCH_MODE:-0}" = "1" ] && [ -n "${CLIP_BATCH_JOBS:-}" ]
}

# POSTs $body to /clip-renders/:id/status for every job in
# CLIP_BATCH_JOBS. Curls fan out in parallel â€” N jobs cost max(curl)
# (~3s timeout) not N*3s â€” and we wait so callers don't leak zombies.
_broadcast_to_batch_jobs() {
  local body="$1"
  [ -n "$body" ] || return 0

  local helpers="${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/clip-helpers.mjs"
  [ -f "$helpers" ] || return 0
  command -v node >/dev/null 2>&1 || return 0

  local creds id token
  creds=$(printf '%s' "$CLIP_BATCH_JOBS" \
    | node "$helpers" jobs-credentials 2>/dev/null) || return 0
  [ -n "$creds" ] || return 0

  local pids=() pid
  while IFS=$'\t' read -r id token; do
    [ -n "$id" ] && [ -n "$token" ] || continue
    curl -sS -m 3 -X POST \
      -H "x-origin-auth: ${id}:${token}" \
      -H "Content-Type: application/json" \
      --data-binary "$body" \
      -o /dev/null \
      "${STATUS_API_BASE}/clip-renders/${id}/status" \
      2>/dev/null &
    pids+=( "$!" )
  done <<< "$creds"
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# Encodes args to JSON via clip-helpers and broadcasts. Returns empty
# on encode failure so callers can early-return.
_encode_status_body() {
  local helpers="${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/clip-helpers.mjs"
  [ -f "$helpers" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  node "$helpers" status-body "$@" 2>/dev/null
}

# Fan errors out to every job in CLIP_BATCH_JOBS â€” batch pods have no
# single status channel, so die() relies on this instead.
broadcast_batch_error() {
  _in_batch_broadcast_mode || return 0
  [ "$#" -gt 0 ]           || return 0

  # clip_render_jobs use status="error" (not "errored" like match_streams).
  local mapped=() arg
  for arg in "$@"; do
    case "$arg" in
      status=errored) mapped+=("status=error") ;;
      *)              mapped+=("$arg")         ;;
    esac
  done

  local body
  body=$(_encode_status_body "${mapped[@]}") || return 0
  _broadcast_to_batch_jobs "$body"
}

# Fan boot-stage ticks out as {status: "booting", boot_stage,
# boot_progress} â€” the api keeps row.status untouched.
broadcast_batch_status() {
  _in_batch_broadcast_mode || return 0
  [ "$#" -gt 0 ]           || return 0

  local arg stage="" progress=""
  for arg in "$@"; do
    case "$arg" in
      status=*) stage="${arg#status=}" ;;
      progress=*) progress="${arg#progress=}" ;;
      progress_stage=*)
        # Fold sub-stage into boot_stage as "downloading_cs2:Validating".
        local sub="${arg#progress_stage=}"
        [ -n "$sub" ] && [ -n "$stage" ] && stage="${stage}:${sub}"
        ;;
    esac
  done

  case "$stage" in
    ""|errored|live|error) return 0 ;;
  esac

  # Translate the 0..100 setup-steam progress into 0..1 the api expects.
  local boot_progress=""
  if [ -n "$progress" ]; then
    boot_progress=$(awk -v p="$progress" 'BEGIN{
      n = p + 0
      if (n < 0) n = 0
      if (n > 100) n = 100
      printf "%.4f", n / 100
    }')
  fi

  local body_args=( "status=booting" "boot_stage=$stage" )
  [ -n "$boot_progress" ] && body_args+=( "boot_progress=$boot_progress" )

  local body
  body=$(_encode_status_body "${body_args[@]}") || return 0
  _broadcast_to_batch_jobs "$body"
}

_status_report_url() {
  if [ -n "$STATUS_REPORT_URL" ]; then
    printf '%s' "$STATUS_REPORT_URL"
  else
    printf '%s/game-streamer/%s/status' "$STATUS_API_BASE" "$MATCH_ID"
  fi
}

_status_auth_header() {
  if [ -n "$STATUS_AUTH_TOKEN" ]; then
    printf '%s' "$STATUS_AUTH_TOKEN"
  else
    printf '%s:%s' "$MATCH_ID" "$MATCH_PASSWORD"
  fi
}

# Atomic write of {key:value, ...} JSON. Args are key=value pairs;
# values may contain spaces. Logs status transitions with timing.
# Callers may run in different subshells, so state lives in files
# under $LOG_DIR.
report_status() {
  [ "$#" -eq 0 ] && return 0

  # Cheap bail-out: if neither the reporter daemon nor a batch broadcast
  # has a destination for this call, don't bother tracking state.
  _status_reporter_configured || _in_batch_broadcast_mode || return 0

  local arg new_status=""
  for arg in "$@"; do
    case "$arg" in status=*) new_status="${arg#status=}";; esac
  done
  if [ -n "$new_status" ]; then
    local now prev_status="" prev_at="" boot_at=""
    now=$(date +%s)
    [ -f "$STATUS_BOOT_FILE" ] || echo "$now" >"$STATUS_BOOT_FILE"
    boot_at=$(cat "$STATUS_BOOT_FILE" 2>/dev/null)
    if [ -f "$STATUS_LAST_FILE" ]; then
      IFS='|' read -r prev_status prev_at <"$STATUS_LAST_FILE" || true
    fi
    if [ -n "$prev_status" ] && [ "$prev_status" != "$new_status" ]; then
      local delta=$(( now - prev_at ))
      local total=$(( now - boot_at ))
      log "status=$new_status (prev=$prev_status took ${delta}s, +${total}s since boot)"
    elif [ -z "$prev_status" ]; then
      log "status=$new_status (first status report)"
    fi
    printf '%s|%s\n' "$new_status" "$now" >"$STATUS_LAST_FILE"
    if [ "$prev_status" != "$new_status" ]; then
      command -v snapshot_once >/dev/null 2>&1 && snapshot_once
    fi
  fi

  broadcast_batch_status "$@" || true

  _status_reporter_configured || return 0

  local tmp="$STATUS_STATE_FILE.tmp.$$"
  if ! python3 - "$@" >"$tmp" <<'PY'
import json, sys
out = {}
for arg in sys.argv[1:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    out[k] = v
print(json.dumps(out))
PY
  then
    rm -f "$tmp"
    warn "report_status: failed to encode JSON for: $*"
    return 1
  fi
  mv -f "$tmp" "$STATUS_STATE_FILE"
}

_status_daemon_running() {
  local pid
  [ -f "$STATUS_DAEMON_PID_FILE" ] || return 1
  pid=$(cat "$STATUS_DAEMON_PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_status_daemon_loop() {
  local last_hash="" current_hash url auth body http_code curl_stderr
  url=$(_status_report_url)
  auth=$(_status_auth_header)
  while :; do
    if [ -f "$STATUS_STATE_FILE" ]; then
      current_hash=$(sha256sum <"$STATUS_STATE_FILE" 2>/dev/null | awk '{print $1}')
      if [ -n "$current_hash" ] && [ "$current_hash" != "$last_hash" ]; then
        body=$(cat "$STATUS_STATE_FILE")
        # The HTTP code is the LAST line of curl's combined output â€”
        # curl writes stderr first, then -w on stdout.
        curl_stderr=$(curl -sS -m 5 -X POST \
            -H "x-origin-auth: ${auth}" \
            -H "Content-Type: application/json" \
            --data-binary @"$STATUS_STATE_FILE" \
            -o /dev/null \
            -w '%{http_code}' \
            "$url" 2>&1) || true
        http_code="${curl_stderr##*$'\n'}"
        case "$http_code" in
          2*)
            last_hash="$current_hash"
            printf '[status-reporter] %s -> %s\n' "$body" "$http_code" >&2
            ;;
          *)
            local diag="${curl_stderr%$'\n'*}"
            [ "$diag" = "$curl_stderr" ] && diag=""
            printf '[status-reporter] FAILED %s -> http=%s%s\n' \
              "$body" "${http_code:-<none>}" \
              "$( [ -n "$diag" ] && printf ' (%s)' "$(tr '\n' ' ' <<<"$diag")" )" \
              >&2
            ;;
        esac
      fi
    fi
    sleep "$STATUS_POLL_SECONDS"
  done
}

start_status_reporter() {
  if ! _status_reporter_configured; then
    if [ "${CLIP_BATCH_MODE:-0}" = "1" ] && [ -n "${CLIP_BATCH_JOBS:-}" ]; then
      log "status-reporter: batch-highlights mode â€” broadcasting per-job"
    else
      log "status-reporter: disabled (MATCH_ID/MATCH_PASSWORD unset)"
    fi
    return 0
  fi
  if _status_daemon_running; then
    return 0
  fi
  rm -f "$STATUS_ACK_FILE"
  _status_daemon_loop &
  echo $! >"$STATUS_DAEMON_PID_FILE"
}

stop_status_reporter() {
  local pid
  if [ -f "$STATUS_DAEMON_PID_FILE" ]; then
    pid=$(cat "$STATUS_DAEMON_PID_FILE" 2>/dev/null) || true
    rm -f "$STATUS_DAEMON_PID_FILE"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
}
