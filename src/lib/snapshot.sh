# shellcheck shell=bash

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${STATUS_API_BASE:=http://api:5585}"
: "${SNAPSHOT_INTERVAL_SECONDS:=30}"
: "${SNAPSHOT_BOOT_INTERVAL_SECONDS:=5}"
: "${SNAPSHOT_WIDTH:=1920}"
: "${SNAPSHOT_HEIGHT:=1080}"
: "${SNAPSHOT_QUALITY:=70}"
: "${SNAPSHOT_PID_FILE:=$LOG_DIR/snapshot.pid}"
: "${SNAPSHOT_FILE:=$LOG_DIR/snapshot.jpg}"
: "${SNAPSHOT_GSI_MARKER:=$LOG_DIR/gsi-flowing}"

# One-shot frame grab via gst-launch num-buffers=1 â€” independent of the
# live encode pipeline, so a hiccup here can't drop the broadcast.
_snapshot_capture_one() {
  local out="$1"
  local tmp="${out}.tmp.$$"
  if nice -n 19 gst-launch-1.0 -q \
       ximagesrc display-name="$DISPLAY" use-damage=0 num-buffers=1 show-pointer=false \
       ! videoconvert \
       ! videoscale method=bilinear \
       ! "video/x-raw,width=${SNAPSHOT_WIDTH},height=${SNAPSHOT_HEIGHT}" \
       ! jpegenc quality="${SNAPSHOT_QUALITY}" \
       ! filesink location="$tmp" \
       >/dev/null 2>&1
  then
    mv -f "$tmp" "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_snapshot_targets() {
  if [ "${CLIP_BATCH_MODE:-0}" = "1" ] && [ -n "${CLIP_BATCH_JOBS:-}" ]; then
    local helpers="${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/clip-helpers.mjs"
    [ -f "$helpers" ] || return 0
    command -v node >/dev/null 2>&1 || return 0
    local id token
    printf '%s' "$CLIP_BATCH_JOBS" \
      | node "$helpers" jobs-credentials 2>/dev/null \
      | while IFS=$'\t' read -r id token; do
          [ -n "$id" ] && [ -n "$token" ] || continue
          printf '%s/clip-renders/%s/snapshot\t%s:%s\n' \
            "$STATUS_API_BASE" "$id" "$id" "$token"
        done
    return 0
  fi
  if [ -n "${BAKE_NODE_ID:-}" ]; then
    printf '%s/game-server-nodes/%s/snapshot\t%s\n' \
      "$STATUS_API_BASE" "$BAKE_NODE_ID" "$BAKE_NODE_ID"
    return 0
  fi
  if [ -n "${DEMO_SESSION_ID:-}" ]; then
    printf '%s/demo-sessions/%s/snapshot\t%s\n' \
      "$STATUS_API_BASE" "$DEMO_SESSION_ID" "$DEMO_SESSION_ID"
    return 0
  fi
  if [ -n "${MATCH_ID:-}" ] && [ -n "${MATCH_PASSWORD:-}" ]; then
    printf '%s/game-streamer/%s/snapshot\t%s:%s\n' \
      "$STATUS_API_BASE" "$MATCH_ID" "$MATCH_ID" "$MATCH_PASSWORD"
    return 0
  fi
}

_snapshot_upload() {
  local file="$1"
  [ -s "$file" ] || return 1

  local targets
  targets=$(_snapshot_targets)
  [ -n "$targets" ] || return 1

  local url auth http_code rc=1
  while IFS=$'\t' read -r url auth; do
    [ -n "$url" ] || continue
    local hdr=()
    [ -n "$auth" ] && hdr=(-H "x-origin-auth: ${auth}")
    http_code=$(curl -sS -m 10 -X POST \
      "${hdr[@]}" \
      -F "file=@${file};type=image/jpeg" \
      -o /dev/null \
      -w '%{http_code}' \
      "$url" 2>/dev/null) || http_code=""
    case "$http_code" in
      2*) rc=0 ;;
      *) warn "snapshot upload failed: http=${http_code:-<none>} url=${url}" ;;
    esac
  done <<< "$targets"
  return "$rc"
}

# "Booted" = the demo is actually PLAYING (GSI flowing), not merely a cs2 window
# up on a load/shader-compile screen. spec-server drops the gsi-flowing marker
# on the first GSI event. Until then we stay on the fast boot cadence so the
# no-GSI load window is densely snapshotted.
_snapshot_booted() {
  [ -f "$SNAPSHOT_GSI_MARKER" ]
}

snapshot_once() {
  snapshot_running || return 0
  {
    _snapshot_capture_one "${SNAPSHOT_FILE}.step" \
      && _snapshot_upload "${SNAPSHOT_FILE}.step"
    rm -f "${SNAPSHOT_FILE}.step"
  } >/dev/null 2>&1 &
}

_snapshot_loop() {
  local start sleep_for interval
  while :; do
    start=$(date +%s)
    if _snapshot_capture_one "$SNAPSHOT_FILE"; then
      _snapshot_upload "$SNAPSHOT_FILE" || true
    else
      warn "snapshot capture failed"
    fi
    if _snapshot_booted; then
      interval="$SNAPSHOT_INTERVAL_SECONDS"
    else
      interval="$SNAPSHOT_BOOT_INTERVAL_SECONDS"
    fi
    local elapsed=$(( $(date +%s) - start ))
    sleep_for=$(( interval - elapsed ))
    [ "$sleep_for" -lt 1 ] && sleep_for=1
    sleep "$sleep_for"
  done
}

snapshot_running() {
  local pid
  [ -f "$SNAPSHOT_PID_FILE" ] || return 1
  pid=$(cat "$SNAPSHOT_PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_snapshot_loop() {
  if [ -z "$(_snapshot_targets)" ]; then
    log "snapshot: disabled (no snapshot target for this pod)"
    return 0
  fi
  if snapshot_running; then
    return 0
  fi
  # Clear any stale marker so a warm-reused pod starts on the fast cadence
  # until this run's demo actually begins playing.
  rm -f "$SNAPSHOT_GSI_MARKER" 2>/dev/null || true
  _snapshot_loop &
  echo $! >"$SNAPSHOT_PID_FILE"
  log "snapshot: started (interval=${SNAPSHOT_BOOT_INTERVAL_SECONDS}s pre-GSI/${SNAPSHOT_INTERVAL_SECONDS}s playing ${SNAPSHOT_WIDTH}x${SNAPSHOT_HEIGHT} q=${SNAPSHOT_QUALITY})"
}

stop_snapshot_loop() {
  local pid
  if [ -f "$SNAPSHOT_PID_FILE" ]; then
    pid=$(cat "$SNAPSHOT_PID_FILE" 2>/dev/null) || true
    rm -f "$SNAPSHOT_PID_FILE"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
}
