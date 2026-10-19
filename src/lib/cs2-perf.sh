# shellcheck shell=bash
# CS2 in-game perf helpers — autoexec convar block.
# Sourced by src/flows/run-live.sh and src/flows/run-demo.sh; depends
# on log/die/CS2_DIR/SRC_DIR from common.sh.
#
# Note: video.cfg generation lives in cs2-options.sh (write_cs2_video_cfg),
# driven by per-node CS2_VIDEO_SETTINGS. fps_max comes from the
# +fps_max launch arg in run-live.sh / run-demo.sh, which defaults to
# CS2_FPS_MAX (= capture FPS) to keep render and capture rates aligned.

# Lines to append to the generated autoexec.cfg. Caller stitches this
# into the heredoc next to HIDE_UI_CMDS / SPEC_BINDS_BLOCK.
cs2_perf_autoexec_block() {
  cat <<'EOF'
// ===== VIDEO / PERFORMANCE =====

// Resolution intentionally NOT set here — launch args force
// -windowed -noborder -width 1920 -height 1080 (required for the
// HUD overlay to composite on top). mat_setvideomode would fight
// the launch args and break the overlay.
// mat_setvideomode 1280 960 1

// fps_max is driven by the +fps_max launch flag (see cs2-options.sh).
fps_max_ui 60

// Disable VSync / latency stuff
r_vsync 0

// Multicore
mat_queue_mode -1

// Reduce input lag
engine_low_latency_sleep_after_client_tick 0

// Spectator/UI niceties (non-visual)
cl_autohelp 0
cl_showhelp 0
cl_disablefreezecam 1
cl_trueview_show_status 0

// Boot trim
sys_minidumpspewlines 0
cl_disablehtmlmotd 1

echo "PERF SETTINGS LOADED"
EOF
}
