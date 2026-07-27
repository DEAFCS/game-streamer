#!/usr/bin/env bash
# Bring Steam up to a state where CS2 can be launched/updated. Idempotent.
# Required env: STEAM_USER, STEAM_PASSWORD.

set -uo pipefail
SCRIPT_TAG=setup-steam

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/hud-manager.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/spec-server.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/snapshot.sh"

load_env
require_env STEAM_USER STEAM_PASSWORD

: "${STEAM_PIPE_TIMEOUT:=300}"

start_status_reporter

start_xorg
start_snapshot_loop || warn "start_snapshot_loop failed â€” continuing without thumbnails"
start_pulseaudio
start_spec_server

# DEBUG_STREAM=1: capture as soon as X+pulse are up (before Steam) so a boot
# hang is watchable. Publishes to the match id; run-live's start_capture
# adopts it. grep logs for "WATCH" for the URL.
if [ "${DEBUG_STREAM:-0}" = "1" ]; then
  debug_sid="${DEBUG_STREAM_ID:-${MATCH_ID:-debug}}"
  case "$CS2_DISPLAY_RES" in
    2560x1440) debug_kbps="${VIDEO_KBPS:-20000}" ;;
    *)         debug_kbps="${VIDEO_KBPS:-12000}" ;;
  esac
  log "DEBUG_STREAM=1 â€” starting early capture '${debug_sid}' (pod watchable during boot)"
  start_capture "$debug_sid" "${FPS:-60}" "$debug_kbps" false 1 \
    || warn "DEBUG_STREAM: start_capture failed â€” continuing boot"
fi

# HUD bringup is split: spawn now, defer the wait + position step
# until after Steam launch so the ~5s hud-manager bootstrap overlaps
# the Steam boot. Batch-highlights skips the HUD entirely â€” recorded
# clips shouldn't carry the scoreboard widgets.
HUD_DEFERRED=0
if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
  log "CLIP_BATCH_MODE=1 â€” skipping hud-manager"
elif [ -n "${BAKE_NODE_ID:-}" ]; then
  log "shader bake â€” skipping hud-manager"
elif [ -x "$HUD_BIN" ]; then
  start_picom || warn "continuing without picom (HUD background won't be transparent)"
  start_hud
  HUD_DEFERRED=1
else
  log "hud-manager not installed at $HUD_BIN"
fi

kill_steam

# Symlink $STEAM_HOME into the persisted cache mount BEFORE touching
# Steam state â€” avoids the dual-bind-mount EXDEV bug where Steam's
# self-update rename across the two would fail with error 18.
ensure_steam_home_persist
fix_steam_perms
write_steam_dev_cfg   # pin fossilize fork count to the pod's cores

mkdir -p "$STEAM_LIBRARY/steamapps/common"
register_library "$STEAM_LIBRARY"

# Steam OFF so steamcmd and Steam don't fight over appmanifest. A fresh install
# re-registers the library at the end â€” see install_cs2_via_steamcmd.
install_cs2_via_steamcmd

# Warm boot = userdata + loginusers.vdf cached â†’ Steam reuses the
# refresh token instead of re-auth'ing on -login.
HAD_USERDATA=0
HAS_LOGIN_TOKEN=0
[ -d "$STEAM_HOME/userdata" ]              && HAD_USERDATA=1
[ -s "$STEAM_HOME/config/loginusers.vdf" ] && HAS_LOGIN_TOKEN=1
if [ "$HAD_USERDATA" = 1 ] && [ "$HAS_LOGIN_TOKEN" = 1 ]; then
  log "boot mode: WARM"
elif [ "$HAD_USERDATA" = 1 ]; then
  log "boot mode: PARTIAL (no loginusers.vdf â†’ password re-auth)"
else
  log "boot mode: COLD (first-time login + cloud-disable cycle)"
fi

# Must run while Steam is OFF â€” Steam clobbers localconfig.vdf on
# shutdown. Without this CS2 pops a "Cloud Out of Date" CEF dialog.
disable_cloud_globally
disable_cloud_in_config_vdf
disable_cs2_cloud
print_cloud_state

# Wipe Steam logs we detect from â€” never rotated, so stale lines get re-detected
# every run (cloud conflict, shader + validate progress).
for _lg in cloud_log shader_log content_log; do
  rm -f "$STEAM_HOME/logs/${_lg}.txt" 2>/dev/null
done
log "wiped stale Steam detection logs (cloud/shader/content)"

disable_overlay_globally
disable_cs2_overlay
print_overlay_state

# Force __GL_SHADER_DISK_CACHE=1 onto cs2 via launch options so the NVIDIA
# Vulkan shader disk cache works as root (else runtime pipelines recompile
# every render â€” see set_cs2_launch_options). Same Steam-off timing as cloud/
# overlay.
set_cs2_launch_options

report_status status=launching_steam
start_steam

wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" || die "pipe never came up"

if [ "$HUD_DEFERRED" = "1" ]; then
  if ! wait_for_hud_server 60; then
    # Wedged or never bound â€” restart once before giving up (boot continues
    # either way; the overlay also self-heals via position_hud_overlay later).
    warn "restarting hud-manager and waiting once more"
    stop_hud; sleep 1; start_hud
    wait_for_hud_server 30 || true
  fi
  if hud_server_up; then
    hide_hud_admin_window
    position_hud_overlay || warn "early overlay positioning failed â€” will retry after cs2"
  else
    warn "hud-manager server didn't come up â€” continuing (overlay retried after cs2)"
  fi
fi

# Background match-cfg prep overlaps the Steam UI wait. Marker files
# signal run-live which branch ran: -prepared / -failed / -skipped.
rm -f "$LOG_DIR/match-cfgs-prepared" \
      "$LOG_DIR/match-cfgs-failed" \
      "$LOG_DIR/match-cfgs-skipped"
if [ -n "${MATCH_ID:-}" ] && [ -n "${API_BASE:-}" ]; then
  (
    set -euo pipefail
    SCRIPT_TAG=cfg-prep
    if write_gsi_cfg && seed_hud_db "$MATCH_ID"; then
      : > "$LOG_DIR/match-cfgs-prepared"
      # Kick the HUD overlay against the freshly-seeded data NOW â€” the
      # POST loads /huds/default/index.html, which fetches /api/teams &
      # /api/players we just populated. Doing it here (Steam still
      # booting) overlaps the ~3-5s HUD bootstrap with the rest of the
      # pipeline so the overlay is already painted by the time cs2's
      # window appears in run-live.sh. A second /api/overlay/start
      # there is harmless â€” hud-manager's closeActiveOverlay() â†’
      # openOverlayForHud() is idempotent.
      # Batch-highlights doesn't run hud-manager at all, so the kick
      # would just spam Connection refused.
      if [ "${CLIP_BATCH_MODE:-0}" != "1" ]; then
        # Forward the api-resolved HUD_MODE as the variant â€” without it
        # this call rebuilds the overlay with an empty `?variant=` and
        # silently resets the boot-time variant the auto-overlay set.
        curl -fsS -m 5 -X POST -o /dev/null \
             -H 'content-type: application/json' \
             --data "{\"variant\":\"${HUD_MODE:-horizontal}\"}" \
             "http://${HUD_HOST:-127.0.0.1}:${HUD_PORT:-1349}/api/overlay/start" \
          || warn "early /api/overlay/start failed (will retry after cs2)"
      fi
    else
      : > "$LOG_DIR/match-cfgs-failed"
    fi
  ) &
else
  : > "$LOG_DIR/match-cfgs-skipped"
fi

# Wait for BOTH the IPC pipe AND the rendered main window â€” +applaunch
# silently drops if Web Helper isn't fully bootstrapped, and direct-exec
# against a half-initialised Steam silently fails to load demos.
report_status status=logging_in
wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
  || die "main Steam window not visible â€” Steam may still be downloading runtimes"

# Post-login: re-disable cloud for the login account (boot-time pass misses an
# account Steam only creates at login), then restart so Steam reads it. Runs on
# COLD boot or when cloud's still dirty for the account. SIGKILL avoids a
# graceful-shutdown rewrite of our edits.
if [ "$HAD_USERDATA" = 0 ] || cs2_cloud_dirty_for_active; then
  log "post-login cloud cycle: disabling CS2 cloud for the logged-in account + restarting"
  for _ in $(seq 1 20); do
    [ -d "$STEAM_HOME/userdata" ] && break
    sleep 0.5
  done
  kill_steam
  disable_cloud_globally
  disable_cloud_in_config_vdf
  disable_cs2_cloud
  print_cloud_state
  disable_overlay_globally
  disable_cs2_overlay
  print_overlay_state
  set_cs2_launch_options
  start_steam
  wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" \
    || die "pipe never came up after cycle"
  wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
    || die "main Steam window not visible after cycle"
fi
