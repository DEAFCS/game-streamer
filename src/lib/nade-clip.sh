#!/usr/bin/env bash
# Film ONE utility lineup off a live practice server and upload it.
#
# The practice plugin directs the shot (UTILITY_RENDER_MODE on the server): it
# stands this client on the lineup, cuts between the stance camera, the aim,
# the close-up, the chase and the bloom, and snaps the thrown grenade to the
# recorded seed. This script only stages the lineup, records, presses the
# throw when told to, and cuts the stills out of the finished clip.
#
# The plugin talks back as `[5stack-render] <event> key=value ...` lines in
# this client's console, which -condebug tees to console.log:
#   staged | shot | still kind=<k> | act | thrown | detonated | done | error reason=<r>
#
# Required env: NADE_RENDER_JOB_ID NADE_RENDER_TOKEN STATUS_API_BASE
#               SPEC_SERVER_URL NADE_LINEUP_ID NADE_NADE_TYPE
# Full job contract: see the header of batch-nades.sh.

set -uo pipefail
SCRIPT_TAG=nade-clip

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"

require_env NADE_RENDER_JOB_ID NADE_RENDER_TOKEN STATUS_API_BASE \
            SPEC_SERVER_URL NADE_LINEUP_ID NADE_NADE_TYPE

CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"
CS2_CONSOLE_LOG="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}"

LOG_PREFIX="[nade ${NADE_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

: "${NADE_LINEUP_NAME:=}"
: "${NADE_MAP_NAME:=}"
: "${NADE_SIDE:=}"
: "${NADE_HAS_SEED:=0}"
: "${NADE_PLUGIN_RUNTIME:=swiftlys2}"
: "${NADE_TECHNIQUE:=}"
: "${NADE_THROW_STRENGTH:=}"
: "${NADE_JUMP_THROW_BIND:=0}"
: "${NADE_APPROACH_FILE:=}"

case "$(printf '%s' "${NADE_SIDE:-}" | tr '[:upper:]' '[:lower:]')" in
  t|terrorist) NADE_JOIN_TEAM=2 ;;
  *)           NADE_JOIN_TEAM=3 ;;
esac
: "${NADE_CMD_JOIN=jointeam ${NADE_JOIN_TEAM}}"

: "${NADE_OUT_DIR:=/tmp/game-streamer/nades}"
: "${NADE_OUTPUT_DIMS:=1920x1080}"
: "${NADE_OUTPUT_FPS:=60}"
# The capture is only kept long enough to cut the stills from and re-encode;
# a static aim shot at this rate is near-lossless, which is what the stills need.
: "${NADE_VIDEO_KBPS:=50000}"
: "${NADE_CLIP_AUDIO:=1}"
: "${NADE_SKIP_STATUS:=skipped}"

# The plugin answers a stage within a tick or two of the library landing; the
# library is a panel round trip that can take a while. Re-sending is safe: the
# plugin re-announces a lineup it already staged instead of starting over.
: "${NADE_STAGE_TIMEOUT_MS:=15000}"
: "${NADE_STAGE_ATTEMPTS:=3}"
# A lineup handed over mid-session reaches this pod a moment before it
# reaches the plugin, which only re-reads its library when the api says so.
: "${NADE_UNKNOWN_LINEUP_RETRIES:=8}"
# go -> done is ~10s of fixed beats plus however long the grenade flies.
: "${NADE_MAX_CLIP_MS:=45000}"
# The pin has to be fully out before the release counts as a throw.
: "${NADE_PIN_PULL_MS:=600}"
: "${NADE_POLL_MS:=50}"
# From `say /render_go` leaving this pod to the plugin starting its clock: the
# exec-cfg keypress plus a server tick. Stills are placed on the plugin's
# clock (t=, ms since go) because console.log can reach us late.
: "${NADE_GO_LATENCY_MS:=100}"
# When to throw if the `act` line has not reached us: the plugin's throw beat
# starts ~8.0s after go, and it also accepts the throw during the close-up.
: "${NADE_ACT_AT_MS:=8500}"

CLIP_OUTPUT_DIMS="$NADE_OUTPUT_DIMS"
CLIP_OUTPUT_FPS="$NADE_OUTPUT_FPS"
CLIP_OUT_DIR="$NADE_OUT_DIR"
export CLIP_OUTPUT_DIMS CLIP_OUTPUT_FPS CLIP_OUT_DIR

NADE_CLIP_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.mp4"
NADE_DELIVERY_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.delivery.mp4"
NADE_THUMB_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.jpg"
NADE_EVENTS_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.events"
NADE_STILLS_DIR="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.stills"
NADE_REACHED_TERMINAL=0
RENDER_TAIL_PID=""
EVENTS_READ=0

if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; printf -v "$1" '%s' "${t:0:${#t}-3}"; }
else
  now_ms() { printf -v "$1" '%s' "$(date +%s%3N)"; }
fi

poll_sleep() { sleep "$(awk -v ms="$NADE_POLL_MS" 'BEGIN{printf "%.3f", ms/1000}')"; }
sleep_ms() { local s; printf -v s '%d.%03d' $(($1 / 1000)) $(($1 % 1000)); sleep "$s"; }

json_body() { node "$CLIP_HELPERS" status-body "$@"; }

api_status() {
  local body
  body=$(json_body "$@") || return 0
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/status" \
    || say "WARN status post failed: $*"
}

# cs2's own words for the moments before a failure: a refused command, a
# kick, an unknown command -- none of which reach the render lines.
dump_console_tail() {
  [ -f "$CS2_CONSOLE_LOG" ] || return 0
  say "cs2 console (last 40 lines):"
  tail -n 40 "$CS2_CONSOLE_LOG" 2>/dev/null | tr -d '\r' | sed 's/^/    | /' >&2
}

die_failed() {
  say "ERROR: $1"
  dump_console_tail
  stop_clip_capture
  api_status "status=error" "error=$1"
  NADE_REACHED_TERMINAL=1
  exit 1
}

# exit 0 so the rest of the batch still drains.
die_skipped() {
  say "SKIP: $1"
  stop_clip_capture
  api_status "status=${NADE_SKIP_STATUS}" "skip_reason=$1" "error=$1"
  NADE_REACHED_TERMINAL=1
  exit 0
}

spec_post() {
  local path="$1" body="${2:-{\}}" http_code
  http_code=$(printf '%s' "$body" \
    | spec_curl --silent --show-error --max-time 5 \
        --header "content-type: application/json" \
        --data-binary @- \
        --write-out "%{http_code}" \
        --output /dev/null \
        "${SPEC_SERVER_URL}${path}" \
    || echo "000")
  case "$http_code" in
    200|204) return 0 ;;
    *) say "WARN spec POST $path -> $http_code (body=$body)"; return 1 ;;
  esac
}

# Console commands reach cs2 through spec-server's exec-cfg path (a cfg file
# swap + one keypress). The plugin's verbs are chat commands: a client cannot
# call a Swiftly console command, but `say` always reaches the server, and `/`
# keeps the line out of chat.
cs2_exec() {
  local cmd="$1" body
  [ -n "$cmd" ] || return 0
  body=$(json_body "cmd=$cmd") || return 1
  say "  exec: $cmd"
  spec_post /demo/exec "$body"
}

# Every [5stack-render] line the plugin prints from here on, one per line,
# appended as it arrives. grep --line-buffered only ever writes whole lines, so
# a reader never sees half of one. Anchored: the plugin's line STARTS with the
# prefix (after cs2's optional timestamp), so the same text quoted in chat or
# anywhere else mid-line is never read as an event.
RENDER_LINE_RE='^[0-9/:. ]*(\[[A-Za-z ]+\] )*\[5stack-render\] [a-z_]+([[:space:]]|$)'
# Chat: "Name: text" puts a colon right before the prefix, and team/all chat
# leads with its channel tag.
RENDER_CHAT_RE=': \[5stack-render\]|^[0-9/:. ]*\[(ALL|T|CT|DEAD|SPEC|SPECTATOR|TEAM)\]'
start_render_tail() {
  : >"$NADE_EVENTS_FILE"
  (
    tail -n0 -F "$CS2_CONSOLE_LOG" 2>/dev/null \
      | grep -a --line-buffered -E "$RENDER_LINE_RE" \
      | grep -a --line-buffered -vE "$RENDER_CHAT_RE" >>"$NADE_EVENTS_FILE"
  ) &
  RENDER_TAIL_PID=$!
  EVENTS_READ=0
}

stop_render_tail() {
  [ -n "$RENDER_TAIL_PID" ] || return 0
  pkill -P "$RENDER_TAIL_PID" 2>/dev/null || true
  kill "$RENDER_TAIL_PID" 2>/dev/null || true
  RENDER_TAIL_PID=""
}

# Sets EVENT (the name) and EVENT_LINE for the next unread line about THIS
# lineup; false when there is none yet. The plugin names the lineup on every
# line, so one naming another lineup (a take this pod already gave up on) or
# none at all is skipped.
next_render_event() {
  local line lineup
  while :; do
    line=$(sed -n "$((EVENTS_READ + 1))p" "$NADE_EVENTS_FILE" 2>/dev/null \
      | tr -d '\r' | sed 's/^.*\(\[5stack-render\] \)/\1/')
    [ -n "$line" ] || return 1
    EVENTS_READ=$((EVENTS_READ + 1))
    EVENT_LINE="$line"
    EVENT=$(printf '%s' "$line" | awk '{print $2}')
    lineup=$(event_field lineup)
    if [ "$(printf '%s' "$lineup" | tr '[:upper:]' '[:lower:]')" \
         != "$(printf '%s' "$NADE_LINEUP_ID" | tr '[:upper:]' '[:lower:]')" ]; then
      say "  ignoring a line for lineup ${lineup:-?}: ${EVENT}"
      continue
    fi
    return 0
  done
}

# key=value off the current event line, "" when absent.
event_field() {
  printf '%s' "$EVENT_LINE" | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

on_exit() {
  local rc=$?
  stop_clip_capture
  stop_render_tail
  rm -rf "$NADE_THUMB_FILE" "$NADE_STILLS_DIR" "$NADE_EVENTS_FILE" "$NADE_DELIVERY_FILE"
  [ -n "$NADE_APPROACH_FILE" ] && rm -f "$NADE_APPROACH_FILE"
  if [ "$rc" -ne 0 ] && [ "$NADE_REACHED_TERMINAL" != "1" ]; then
    api_status "status=error" \
      "error=nade render exited rc=${rc} before reaching terminal status" || true
  fi
}
trap 'on_exit' EXIT

# ---------------------------------------------------------------------------

PRE_STATUS=$(curl --fail --silent --show-error --max-time 5 \
  --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
  "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/status" \
  | node "$CLIP_HELPERS" status-field)
if [ "$PRE_STATUS" = "cancelled" ]; then
  say "job already cancelled — skipping (no work, no error)"
  NADE_REACHED_TERMINAL=1
  exit 0
fi

say "============================================================"
say "lineup=${NADE_LINEUP_ID} '${NADE_LINEUP_NAME}'"
say "type=${NADE_NADE_TYPE} map=${NADE_MAP_NAME:-?} side=${NADE_SIDE:-?} technique=${NADE_TECHNIQUE:-?} strength=${NADE_THROW_STRENGTH:-?} jump_bind=${NADE_JUMP_THROW_BIND}"
say "============================================================"

# The id is typed into this client's chat, and exec-cfg splits on `;`: only a
# bare uuid is ever allowed near it.
if ! printf '%s' "$NADE_LINEUP_ID" \
     | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  die_failed "lineup id '${NADE_LINEUP_ID}' is not a uuid"
fi
case "$NADE_HAS_SEED" in
  1|true|yes) : ;;
  *) die_skipped "lineup has no recorded physics seed (initial position/velocity) — the throw cannot be reproduced exactly" ;;
esac
case "$(printf '%s' "$NADE_PLUGIN_RUNTIME" | tr '[:upper:]' '[:lower:]')" in
  swiftlys2|swiftly) : ;;
  *) die_skipped "practice server runs ${NADE_PLUGIN_RUNTIME}, which has no render director (SwiftlyS2 only)" ;;
esac
if [ -f "$CS2_FATAL_SENTINEL" ]; then
  die_failed "cs2 session already dead: $(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)"
fi

ACT_AT=() ACT_CMD=() ACT_PLAN=""
APPROACH_SRC=/dev/null
[ -s "$NADE_APPROACH_FILE" ] && APPROACH_SRC="$NADE_APPROACH_FILE"
while IFS=$'\t' read -r at cmd; do
  case "$at" in ''|*[!0-9]*) continue ;; esac
  [[ "$cmd" =~ ^[+-][a-z0-9]+$ ]] || continue
  ACT_AT+=("$at")
  ACT_CMD+=("$cmd")
  ACT_PLAN+="${ACT_PLAN:+, }${at} ${cmd}"
done < <(node "$CLIP_HELPERS" nade-timeline "$NADE_TECHNIQUE" "$NADE_THROW_STRENGTH" \
           "$NADE_JUMP_THROW_BIND" "$NADE_PIN_PULL_MS" <"$APPROACH_SRC")
[ "${#ACT_CMD[@]}" -gt 0 ] || die_failed "could not work out the throw keys"
say "throw keys (ms after the pin pull): ${ACT_PLAN}"

api_status "status=rendering" "progress=0.02"

mkdir -p "$NADE_OUT_DIR" "$NADE_STILLS_DIR"
rm -f "$NADE_CLIP_FILE" "$NADE_THUMB_FILE" "$NADE_STILLS_DIR"/*.jpg "$NADE_STILLS_DIR"/*.webp

start_render_tail

# --- STEP 1: stage -----------------------------------------------------------

say "STEP 1: stage the lineup"
cs2_exec "exec nade_view"
join_if_not_spawned() {
  [ -n "$NADE_CMD_JOIN" ] || return 0
  local self health
  self=$(spec_curl --fail --silent --max-time 5 "${SPEC_SERVER_URL}/nade/self" || true)
  [ -n "$self" ] || return 0
  IFS='|' read -r _age _sid _team health _rest <<<"$self"
  case "${health:-0}" in
    ''|0|*[!0-9]*) cs2_exec "$NADE_CMD_JOIN" ;;
  esac
}

STAGED=0
RENDER_VERSION=""
attempt=1
unknown=0
while [ "$attempt" -le "$NADE_STAGE_ATTEMPTS" ]; do
  join_if_not_spawned
  cs2_exec "say /render_stage ${NADE_LINEUP_ID}"
  now_ms STAGE_AT
  RESTAGE=0
  while :; do
    if next_render_event; then
      case "$EVENT" in
        staged)
          say "STEP 1: staged at $(event_field x),$(event_field y),$(event_field z) (dz=$(event_field dz) off the recorded stance) pitch=$(event_field pitch) yaw=$(event_field yaw) body lean=$(event_field lean)"
          # What the director says it films with. The api files the preview
          # under it, and a director that says nothing leaves it unversioned.
          RENDER_VERSION=$(event_field v)
          case "$RENDER_VERSION" in ''|*[!0-9]*) RENDER_VERSION="" ;; esac
          STAGED=1
          ;;
        error)
          case "$(event_field reason)" in
            no_seed) die_skipped "the practice plugin has no physics seed for this lineup" ;;
            unknown_lineup)
              unknown=$((unknown + 1))
              [ "$unknown" -gt "$NADE_UNKNOWN_LINEUP_RETRIES" ] \
                && die_failed "staging refused: ${EVENT_LINE#*error }"
              say "  the plugin does not know this lineup yet (${unknown}/${NADE_UNKNOWN_LINEUP_RETRIES})"
              RESTAGE=1
              ;;
            *) die_failed "staging refused: ${EVENT_LINE#*error }" ;;
          esac
          ;;
      esac
      [ "$STAGED" = "1" ] && break
      [ "$RESTAGE" = "1" ] && break
      continue
    fi
    now_ms NOW
    [ $((NOW - STAGE_AT)) -ge "$NADE_STAGE_TIMEOUT_MS" ] && break
    poll_sleep
  done
  [ "$STAGED" = "1" ] && break
  if [ "$RESTAGE" = "1" ]; then
    sleep 2
    continue
  fi
  say "  no answer to render_stage after ${NADE_STAGE_TIMEOUT_MS}ms (attempt ${attempt}/${NADE_STAGE_ATTEMPTS})"
  attempt=$((attempt + 1))
done
[ "$STAGED" = "1" ] || die_failed "the practice plugin never staged the lineup — is UTILITY_RENDER_MODE on and the lineup in this session's library?"
api_status "status=rendering" "progress=0.15"

# --- STEP 2: record while the plugin directs ---------------------------------

say "STEP 2: start capture -> $NADE_CLIP_FILE"
if ! start_clip_capture "$NADE_CLIP_FILE" "$NADE_OUTPUT_FPS" "$NADE_VIDEO_KBPS" "$NADE_CLIP_AUDIO"; then
  die_failed "capture failed to start"
fi
wait_clip_capture_ready || true
clip_capture_go
now_ms CAPTURE_START_MS
cs2_exec "say /render_go ${NADE_LINEUP_ID}"
now_ms GO_SENT_MS
api_status "status=rendering" "progress=0.3"

# One action per exec. cs2 refuses a single exec that combines actions the way
# a jumpthrow bind does (+jump with -attack): the pin came out on +attack and
# "+jump; -attack" never let go of it -- the grenade only fell when the pod
# disconnected.
# The clock starts once the offset-0 keys are down, so the pin pull is timed
# from +attack itself; every later step waits for its own offset on that one
# clock, so a slow exec delays only itself and never the rest of the run-up.
# The director pulls the pin early (`pin`), so cs2's throw crosshair is up for
# the pulled-pin and close-up shots: the offset-0 keys go down then, and `act`
# runs the rest with the pin pull already served.
PINNED=0
pin_grip() {
  [ "$PINNED" = "1" ] && return 0
  PINNED=1
  local i
  for i in "${!ACT_CMD[@]}"; do
    [ "${ACT_AT[$i]}" -eq 0 ] || continue
    say "  pin ${ACT_CMD[$i]}"
    spec_post /demo/exec "{\"cmd\":\"${ACT_CMD[$i]}\"}"
  done
}

ACTED=0
act_throw() {
  [ "$ACTED" = "1" ] && return 0
  ACTED=1
  local i at start="" now wait served=0
  if [ "$PINNED" = "1" ]; then
    served="$NADE_PIN_PULL_MS"
    now_ms start
  fi
  for i in "${!ACT_CMD[@]}"; do
    at="${ACT_AT[$i]}"
    if [ "$PINNED" = "1" ] && [ "$at" -eq 0 ]; then
      continue
    fi
    at=$((at - served))
    [ "$at" -lt 0 ] && at=0
    if [ "$at" -gt 0 ]; then
      [ -n "$start" ] || now_ms start
      now_ms now
      wait=$((start + at - now))
      [ "$wait" -gt 0 ] && sleep_ms "$wait"
    fi
    now_ms now
    say "  act ${ACT_CMD[$i]} at ${at}ms (sent at $((now - ${start:-$now}))ms)"
    spec_post /demo/exec "{\"cmd\":\"${ACT_CMD[$i]}\"}"
  done
}

declare -A STILL_AT_MS=()
DONE=0
while :; do
  if next_render_event; then
    now_ms NOW
    case "$EVENT" in
      shot)
        say "  shot $(event_field name) through the $(event_field view)"
        ;;
      still)
        kind=$(event_field kind)
        t=$(event_field t)
        case "$t" in ''|*[!0-9]*) t="" ;; esac
        case "$kind" in
          stance|stance_eyes|aim|aim_pin|aim_close|landing)
            if [ -n "$t" ]; then
              STILL_AT_MS[$kind]=$((GO_SENT_MS - CAPTURE_START_MS + NADE_GO_LATENCY_MS + t))
            else
              STILL_AT_MS[$kind]=$((NOW - CAPTURE_START_MS))
            fi
            aim_off=""
            [ -n "$(event_field dpitch)" ] && aim_off=", aim off by pitch=$(event_field dpitch) yaw=$(event_field dyaw), eye $(event_field eye_off)u off the stance"
            say "  still ${kind} at ${STILL_AT_MS[$kind]}ms into the clip (line read $((NOW - CAPTURE_START_MS))ms in${aim_off})"
            ;;
        esac
        ;;
      pin)
        pin_grip
        ;;
      act)
        act_throw
        ;;
      thrown)
        say "  thrown (the pod's own release was $(event_field release_drift)u off the seed)"
        api_status "status=rendering" "progress=0.6"
        ;;
      detonated)
        say "  detonated at $(event_field x),$(event_field y),$(event_field z)"
        api_status "status=rendering" "progress=0.75"
        ;;
      done)
        DONE=1
        ;;
      error)
        die_failed "the practice plugin abandoned the shot: ${EVENT_LINE#*error }"
        ;;
    esac
    [ "$DONE" = "1" ] && break
    continue
  fi
  now_ms NOW
  if [ "$ACTED" != "1" ] && [ $((NOW - GO_SENT_MS)) -ge "$NADE_ACT_AT_MS" ]; then
    say "  no act line ${NADE_ACT_AT_MS}ms after go — throwing on the clock"
    act_throw
    continue
  fi
  if [ $((NOW - CAPTURE_START_MS)) -ge "$NADE_MAX_CLIP_MS" ]; then
    cs2_exec "say /render_reset"
    die_failed "no done from the practice plugin within ${NADE_MAX_CLIP_MS}ms"
  fi
  poll_sleep
done

say "STEP 3: stop capture"
stop_clip_capture
stop_render_tail
api_status "status=rendering" "progress=0.9"

CLIP_BYTES=$(stat -c '%s' "$NADE_CLIP_FILE" 2>/dev/null \
  || stat -f '%z' "$NADE_CLIP_FILE" 2>/dev/null || echo 0)
CLIP_DURATION_S=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$NADE_CLIP_FILE" 2>/dev/null \
  | awk '{printf "%.2f", $1}')
[ -z "$CLIP_DURATION_S" ] && CLIP_DURATION_S=0
if [ "$(awk -v d="$CLIP_DURATION_S" -v b="$CLIP_BYTES" \
        'BEGIN{print (d >= 1.0 && b > 1024) ? 1 : 0}')" != "1" ]; then
  die_failed "encode produced an unusable clip (${CLIP_BYTES}B, ${CLIP_DURATION_S}s)"
fi
CLIP_DURATION_MS=$(awk -v d="$CLIP_DURATION_S" 'BEGIN{printf "%d", d * 1000}')
say "captured ${CLIP_BYTES}B / ${CLIP_DURATION_S}s"

# cs2 is free from here — the batch loop can stage the next lineup while this
# job's stills and upload (disk + network only) finish.
if [ -n "${NADE_CS2_RELEASE_MARKER:-}" ]; then
  : >"$NADE_CS2_RELEASE_MARKER" 2>/dev/null || true
  say "cs2 released — next lineup may start"
fi

# --- STEP 4: stills, cut from the clip itself ---------------------------------
# Grid pacing keeps the clip's frame count on wall time, so a still's offset
# from the capture gate is its timestamp in the mp4.

# The aim shots are what a player lines their crosshair up against, so they
# are kept lossless; the rest are high-quality lossy. jpeg only when this
# ffmpeg cannot write webp.

cut_frame() {
  local at_ms="$1" out="$2"
  shift 2
  ffmpeg -y -hide_banner -loglevel error \
    -ss "$(awk -v ms="$at_ms" 'BEGIN{printf "%.3f", ms/1000}')" \
    -i "$NADE_CLIP_FILE" -frames:v 1 "$@" "$out" 2>/dev/null \
    && [ -s "$out" ]
}

for kind in stance stance_eyes aim aim_pin aim_close landing; do
  at_ms="${STILL_AT_MS[$kind]:-}"
  if [ -z "$at_ms" ]; then
    say "WARN no ${kind} still was called for"
    continue
  fi
  [ "$at_ms" -lt 0 ] && at_ms=0
  if [ "$at_ms" -ge "$CLIP_DURATION_MS" ]; then
    at_ms=$((CLIP_DURATION_MS - 100))
  fi
  case "$kind" in
    aim|aim_pin|aim_close) webp_args=(-c:v libwebp -lossless 1 -compression_level 6) ;;
    *) webp_args=(-c:v libwebp -quality 90 -compression_level 6) ;;
  esac
  if cut_frame "$at_ms" "$NADE_STILLS_DIR/${kind}.webp" "${webp_args[@]}"; then
    :
  elif rm -f "$NADE_STILLS_DIR/${kind}.webp" \
       && cut_frame "$at_ms" "$NADE_STILLS_DIR/${kind}.jpg" -q:v 2; then
    say "WARN ${kind} still fell back to jpeg"
  else
    say "WARN ffmpeg could not cut the ${kind} still"
    rm -f "$NADE_STILLS_DIR/${kind}.jpg"
  fi
done

# The aim is what a viewer needs to copy, so it is the poster -- a jpeg, which
# every link preview can show.
if [ -n "${STILL_AT_MS[aim]:-}" ]; then
  cut_frame "${STILL_AT_MS[aim]}" "$NADE_THUMB_FILE" -q:v 2 \
    || rm -f "$NADE_THUMB_FILE"
fi

# --- STEP 5: the delivered encode ---------------------------------------------
# The capture runs at 24Mbps so the stills above are clean. What ships is
# re-encoded the way highlights are (~9Mbps): a raw capture is ~60MB for a
# 20s render, too big for Discord to play inline when the lineup is shared.

nade_delivery_encode() {
  rm -f "$NADE_DELIVERY_FILE"
  timeout 180 ffmpeg -y -hide_banner -loglevel error -i "$NADE_CLIP_FILE" "$@" \
    -c:a copy -movflags +faststart "$NADE_DELIVERY_FILE" 2>/dev/null \
    && [ -s "$NADE_DELIVERY_FILE" ]
}

NADE_NVENC_ARGS=(-c:v h264_nvenc -preset p6 -tune hq -multipass qres -rc vbr
  -b:v "${NADE_FINAL_BITRATE:-9M}" -maxrate "${NADE_FINAL_MAXRATE:-14M}" -bufsize "${NADE_FINAL_BUFSIZE:-18M}"
  -spatial-aq 1 -temporal-aq 1 -rc-lookahead 20 -bf 3
  -pix_fmt yuv420p -profile:v high -level 4.2)

# Pre-Turing GPUs reject B-frames as references, and a node without NVENC
# falls back to the CPU encode highlights used before NVENC.
if nade_delivery_encode "${NADE_NVENC_ARGS[@]}" -b_ref_mode middle \
   || nade_delivery_encode "${NADE_NVENC_ARGS[@]}" \
   || nade_delivery_encode -c:v libx264 -preset veryfast -crf 22 \
        -pix_fmt yuv420p -profile:v high -level 4.2; then
  mv -f "$NADE_DELIVERY_FILE" "$NADE_CLIP_FILE"
  say "delivery encode: $(stat -c '%s' "$NADE_CLIP_FILE" 2>/dev/null || stat -f '%z' "$NADE_CLIP_FILE")B"
else
  rm -f "$NADE_DELIVERY_FILE"
  say "WARN delivery encode failed — uploading the capture as recorded"
fi

api_status "status=uploading" "progress=0.0"

upload_image() {
  local path="$1" file="$2" type="image/jpeg"
  case "$file" in *.webp) type="image/webp" ;; esac
  curl --fail --silent --show-error --max-time 60 \
       --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
       --header "content-type: ${type}" \
       --data-binary "@${file}" \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/${path}"
}

# Everything the clip points at lands before the clip: the api records the
# stills and the thumbnail that already exist when the clip upload finalizes.
for kind in stance stance_eyes aim aim_pin aim_close landing; do
  for still in "$NADE_STILLS_DIR/${kind}.webp" "$NADE_STILLS_DIR/${kind}.jpg"; do
    [ -s "$still" ] || continue
    upload_image "still/${kind}" "$still" \
      || say "WARN ${kind} still upload failed — continuing without it"
    break
  done
done
if [ -s "$NADE_THUMB_FILE" ]; then
  upload_image thumbnail "$NADE_THUMB_FILE" \
    || say "WARN thumbnail upload failed — continuing without one"
fi

say "POST ${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/upload (render version ${RENDER_VERSION:-unreported})"
# --upload-file streams from disk; --data-binary @file would slurp the whole
# clip into RAM alongside every other pending upload tail.
if ! curl --fail --silent --show-error --max-time 900 \
       --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
       --header "content-type: application/octet-stream" \
       --header "x-clip-duration-ms: ${CLIP_DURATION_MS}" \
       --header "x-render-version: ${RENDER_VERSION}" \
       --upload-file "$NADE_CLIP_FILE" \
       --request POST \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/upload"; then
  die_failed "clip upload failed"
fi

api_status "status=done" "progress=1.0" "duration_ms=${CLIP_DURATION_MS}"
NADE_REACHED_TERMINAL=1
rm -f "$NADE_CLIP_FILE"
say "done"
