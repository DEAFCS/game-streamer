#!/usr/bin/env bash
# game-streamer entrypoint. Three paths: live, demo, batch-highlights.

set -uo pipefail
SCRIPT_TAG=game-streamer

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/shader-cache.sh"   # should_warm_shaders for the batch pre-warm

load_env

usage() {
  cat <<EOF
usage: $(basename "$0") <command>

  live              setup Steam + launch CS2 + start match capture
  demo              setup Steam + download \$DEMO_URL + play it back + capture
  batch-highlights  demo flow with CLIP_BATCH_MODE=1 â€” renders \$CLIP_BATCH_JOBS
                    sequentially against the same cs2 instance, then exits
  warm-shaders      boot CS2, run the Vulkan shader precache to completion,
                    then exit â€” pre-warms this node's cache (no match needed)
EOF
}

run_demo_flow() {
  mkdir -p /tmp/game-streamer
  if [ -n "${DEMO_URL:-}" ]; then
    DEMO_FILE_BG="${DEMO_FILE:-/tmp/game-streamer/demo.dem}"
    if [ -s "$DEMO_FILE_BG" ]; then
      # Already on disk (e.g. a dev re-run in the same pod) â€” skip the
      # re-download. run-demo.sh sees the file and skips its own fetch too.
      log "demo already present at $DEMO_FILE_BG ($(stat -c%s "$DEMO_FILE_BG") bytes) â€” skipping download"
    else
    rm -f "$DEMO_FILE_BG" "$DEMO_FILE_BG.failed" "$DEMO_FILE_BG.partial"
    (
      # shellcheck disable=SC1091
      . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
      # shellcheck disable=SC1091
      . "$LIB_DIR/status-reporter.sh"
      SCRIPT_TAG=demo-download
      # Report HERE â€” without this the only `downloading_demo` event
      # comes from run-demo.sh after the file's already on disk, gets
      # coalesced by the 2s daemon poll, and the web stepper marks the
      # stage SKIPPED.
      report_status status=downloading_demo
      DEMO_URL_LC=$(printf '%s' "$DEMO_URL" | tr '[:upper:]' '[:lower:]')
      case "${DEMO_URL_LC%%[?#]*}" in
        *.bz2) DEMO_DECOMPRESS_CMD="bunzip2" ;;
        *.gz)  DEMO_DECOMPRESS_CMD="gunzip" ;;
        *)     DEMO_DECOMPRESS_CMD="" ;;
      esac
      echo "GET $DEMO_URL (decompress=${DEMO_DECOMPRESS_CMD:-none})"

      # Heartbeat: emit bytes written every 5s while curl runs so a stuck
      # download is obvious instead of silent. Killed the moment curl
      # returns (below) so it never bleeds into the bunzip2 phase and
      # prints misleading "still downloading" with a frozen byte count.
      (
        while [ ! -f "$DEMO_FILE_BG.failed" ]; do
          sleep 5
          size=$(stat -c%s "$DEMO_FILE_BG.partial" 2>/dev/null || echo 0)
          echo "still downloading: ${size} bytes"
        done
      ) &
      HEARTBEAT_PID=$!

      # --speed-limit/--speed-time abort a stalled-but-open socket (Valve
      # replay mirrors trickle then freeze) so --retry can reconnect;
      # --max-time alone would sit idle on a dead socket for the full cap.
      curl_rc=0
      curl --fail --silent --show-error --location \
           --retry 5 --retry-delay 2 --retry-all-errors \
           --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
           --max-time "${DEMO_DOWNLOAD_TIMEOUT:-300}" \
           --output "$DEMO_FILE_BG.partial" \
           "$DEMO_URL" || curl_rc=$?
      kill "$HEARTBEAT_PID" 2>/dev/null || true
      if [ "$curl_rc" = 0 ]; then
        bytes=$(stat -c%s "$DEMO_FILE_BG.partial" 2>/dev/null || echo 0)
        echo "downloaded ${bytes} bytes"
        if [ -n "$DEMO_DECOMPRESS_CMD" ]; then
          echo "decompressing ${bytes} bytes (${DEMO_DECOMPRESS_CMD})"
          if "$DEMO_DECOMPRESS_CMD" -q -c "$DEMO_FILE_BG.partial" > "$DEMO_FILE_BG.tmp"; then
            out_bytes=$(stat -c%s "$DEMO_FILE_BG.tmp" 2>/dev/null || echo 0)
            echo "${DEMO_DECOMPRESS_CMD} done: ${out_bytes} bytes"
            mv -f "$DEMO_FILE_BG.tmp" "$DEMO_FILE_BG"
            rm -f "$DEMO_FILE_BG.partial"
          else
            echo "${DEMO_DECOMPRESS_CMD} FAILED â€” marking download as failed"
            rm -f "$DEMO_FILE_BG.tmp" "$DEMO_FILE_BG.partial"
            touch "$DEMO_FILE_BG.failed"
          fi
        else
          mv -f "$DEMO_FILE_BG.partial" "$DEMO_FILE_BG"
        fi
      else
        echo "curl FAILED (exit $curl_rc) â€” marking download as failed"
        touch "$DEMO_FILE_BG.failed"
      fi
    ) > >(awk '{print "[demo-download] " $0; fflush()}' >&2) 2>&1 &
    echo $! > /tmp/game-streamer/demo-download.pid
    fi
  fi
  if [ -n "${WORKSHOP_ID:-}" ]; then
    WORKSHOP_TARGET="${STEAM_LIBRARY:-/mnt/game-streamer}/steamapps/workshop/content/730/${WORKSHOP_ID}"
    WORKSHOP_FAILED="/tmp/game-streamer/workshop-${WORKSHOP_ID}.failed"
    CS2_MANIFEST="${STEAM_LIBRARY:-/mnt/game-streamer}/steamapps/appmanifest_730.acf"
    rm -f "$WORKSHOP_FAILED"
    (
      # shellcheck disable=SC1091
      . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
      # shellcheck disable=SC1091
      . "$LIB_DIR/steam.sh"
      # shellcheck disable=SC1091
      . "$LIB_DIR/status-reporter.sh"
      SCRIPT_TAG=workshop-bg
      # Two concurrent steamcmd processes fight over ~/.steam state, so
      # wait for the cs2 install to finish before starting our own.
      for _ in $(seq 1 600); do
        [ -f "$CS2_MANIFEST" ] && break
        sleep 2
      done
      if [ ! -f "$CS2_MANIFEST" ]; then
        warn "cs2 manifest never appeared â€” skipping workshop download"
        touch "$WORKSHOP_FAILED"
        exit 0
      fi
      report_status status=downloading_workshop_map "workshop_id=${WORKSHOP_ID}"
      if ! download_workshop_map "$WORKSHOP_ID"; then
        touch "$WORKSHOP_FAILED"
      fi
    ) > >(awk '{print "[workshop-download] " $0; fflush()}' >&2) 2>&1 &
    echo $! > /tmp/game-streamer/workshop-download.pid
  fi
  "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
  # Cold-shader first-segment fix: the FIRST cs2 process renders cold â€” Vulkan
  # pipelines compile on first encounter, stalling the render thread, so the first
  # segment's fps dips (GPU+CPU idle during the dip; later segments run warm). Run
  # Steam's Fossilize precache once per node (persists on the library volume) so the
  # render cs2 starts warm. Gated on a cold cache (warmed nodes skip the ~60-90s);
  # batch only. setup-steam left Steam+Xorg up, which warm-shaders needs.
  if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
    if should_warm_shaders; then
      log "shader pre-warm: cold ($(cs2_shadercache_dir)=$(cs2_shadercache_mib)MiB, GS_WARM_SHADERS=${GS_WARM_SHADERS:-auto}) â€” warming once before render"
      "$FLOWS_DIR/warm-shaders.sh" "$@" || warn "shader pre-warm failed â€” continuing (first segment may stutter)"
    else
      log "shader pre-warm: SKIPPED ($(cs2_shadercache_dir)=$(cs2_shadercache_mib)MiB â‰¥ ${GS_SHADERCACHE_MIN_MIB:-50}MiB, GS_WARM_SHADERS=${GS_WARM_SHADERS:-auto})"
    fi
  fi
  exec "$FLOWS_DIR/run-demo.sh" "$@"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  live)
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/run-live.sh" "$@"
    ;;
  demo)
    run_demo_flow "$@"
    ;;
  batch-highlights)
    export CLIP_BATCH_MODE=1
    run_demo_flow "$@"
    ;;
  warm-shaders)
    # Pre-warm this node's shader cache (no match). Run as a per-node Job.
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/warm-shaders.sh" "$@"
    ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
