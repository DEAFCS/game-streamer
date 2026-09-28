#!/usr/bin/env bash
# Pivot a running game-streamer pod from one match to another without
# restarting cs2 / steam. Invoked by spectator/routes/switch-match.mjs
# AFTER the cs2 console has already received `disconnect; connect ...`.
#
# Required env (set by spec-server before spawn):
#   MATCH_ID         new match id (target)
#   MATCH_PASSWORD   raw match password for status-reporter auth
#   MODE             "live" | "tv"
#   OLD_MATCH_ID     previous match id (may be empty on first switch)
#   CONNECT_ADDR / CONNECT_PASSWORD   (for live mode)  OR
#   PLAYCAST_URL                      (for tv+playcast mode)
#
# All steps best-effort + idempotent. A failure mid-flow leaves the
# pod in a degraded-but-streaming state (cs2 already followed the
# console command) rather than dead.

set -uo pipefail
SCRIPT_TAG=switch-match

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/hud-manager.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"

: "${MATCH_ID:=}"
: "${MATCH_PASSWORD:=}"
: "${OLD_MATCH_ID:=}"
: "${MODE:=live}"

if [ -z "$MATCH_ID" ] || [ -z "$MATCH_PASSWORD" ]; then
  die "MATCH_ID and MATCH_PASSWORD are required"
fi

log "pivoting pod: ${OLD_MATCH_ID:-<none>} -> $MATCH_ID (mode=$MODE)"

if hud_running; then
  log "reseeding HUD for $MATCH_ID"
  seed_hud_db "$MATCH_ID" || warn "seed_hud_db returned non-zero"
  reload_hud_overlay
fi

log "rebinding status-reporter to $MATCH_ID"
stop_status_reporter || true
rm -f "${LOG_DIR}/status.boot.epoch" "${LOG_DIR}/status.last" \
      "${LOG_DIR}/status.state" "${LOG_DIR}/status.ack" 2>/dev/null || true
export MATCH_ID MATCH_PASSWORD
start_status_reporter
STREAM_ID="${OLD_MATCH_ID:-$MATCH_ID}"
report_status status=live "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${STREAM_ID}"

log "switch-match flow done"
