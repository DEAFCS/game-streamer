# shellcheck shell=bash
# Per-node cs2_video.txt overrides.
# Inputs (env, set by API job spec):
#   CS2_VIDEO_SETTINGS — JSON object with verbatim `setting.*` keys
# Sourced by src/flows/run-live.sh and src/flows/run-demo.sh; depends
# on log/warn/die/CS2_DIR/SRC_DIR from common.sh and requires `jq` on PATH.
#
# CS2 launch flags are hardcoded in run-live.sh / run-demo.sh — they
# are HUD-overlay-load-bearing and not user-configurable.

# Writes $CS2_DIR/game/csgo/cfg/cs2_video.txt by merging $CS2_VIDEO_SETTINGS
# over the vendored default (resources/video/default.txt). The default
# carries engine/hardware-managed keys (Version/VendorID/DeviceID/
# knowndevice/Autoconfig) so a partial override still produces a complete
# video.cfg.
#
# Arg 1 ($1) is the flow mode: "live" or "demo" (default "demo"). It
# drives r_low_latency — only live wants NVIDIA Reflex on; demo / clip /
# highlight renders pin it to 0 so frame pacing doesn't fight the
# fixed-FPS capture sink.
write_cs2_video_cfg() {
  local mode="${1:-demo}"
  local template="$SRC_DIR/../resources/video/default.txt"
  local dst="$CS2_DIR/game/csgo/cfg/cs2_video.txt"
  [ -f "$template" ] || die "cs2_video.txt template missing at $template"
  mkdir -p "$(dirname "$dst")"

  local low_latency=0
  [ "$mode" = "live" ] && low_latency=2

  local overrides="${CS2_VIDEO_SETTINGS:-{\}}"
  if ! echo "$overrides" | jq -e . >/dev/null 2>&1; then
    warn "CS2_VIDEO_SETTINGS is not valid JSON; treating as auto"
    overrides='{}'
  fi

  # Auto mode: no per-node overrides — let cs2's first-launch auto-detect
  # generate cs2_video.txt against the actual GPU. Remove any leftover
  # file from a previous override run (it would be 0444 and block cs2's
  # writeback).
  if [ "$(echo "$overrides" | jq -r 'length')" = "0" ]; then
    rm -f "$dst"
    log "  cs2_video.txt: auto mode (no overrides; cs2 will generate)"
    return 0
  fi

  # Locked keys — the streamer requires these exact values for HUD overlay
  # compositing and headless capture to work. Stripped from user input so
  # the form (and direct DB edits) can't break the pod.
  # r_low_latency is force-set per-flow below (live=2, demo=0).
  overrides=$(echo "$overrides" | jq --argjson ll "$low_latency" '
    del(
      .["setting.fullscreen"],
      .["setting.nowindowborder"],
      .["setting.coop_fullscreen"],
      .["setting.fullscreen_min_on_focus_loss"],
      .["setting.high_dpi"],
      .["setting.mat_vsync"],
      .["setting.aspectratiomode"],
      .["setting.refreshrate_numerator"],
      .["setting.refreshrate_denominator"],
      .["setting.monitor_index"],
      .["setting.cpu_level"],
      .["setting.gpu_level"],
      .["setting.gpu_mem_level"],
      .["setting.videocfg_hdr_detail"],
      .["setting.videocfg_fsr_detail"]
    )
    | .["setting.r_low_latency"] = $ll
  ')

  # Copy template, then rewrite each overridden `"key" "value"` line
  # in place via sed. The template's body lines look like
  # `\t"setting.foo"\t\t"123"`; sed preserves the surrounding whitespace.
  # `rm -f` first so a prior-run 0444 file doesn't block the rewrite.
  rm -f "$dst"
  cp -f "$template" "$dst"
  local override_count=0
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    # Escape regex metacharacters in the key, and `/` + `&` in the value.
    local k_re v_esc
    k_re=$(printf '%s' "$k" | sed -e 's/[][\\/.^$*]/\\&/g')
    v_esc=$(printf '%s' "$v" | sed -e 's/[\\/&]/\\&/g')
    sed -i.bak -E "s/^([[:space:]]*\"${k_re}\"[[:space:]]+\")[^\"]*(\".*)$/\1${v_esc}\2/" "$dst"
    override_count=$((override_count + 1))
  done < <(echo "$overrides" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
  rm -f "${dst}.bak"

  # CS2's auto-config pass rewrites cs2_video.txt on launch if the file
  # doesn't match its detected hardware (Version/VendorID/DeviceID etc).
  # Mark the file read-only so any rewrite attempt EACCES's and our
  # values survive. CS2 logs a warning but continues normally.
  chmod 0444 "$dst"

  log "  wrote cs2_video.txt (mode=$mode, r_low_latency=$low_latency, overrides=$override_count, read-only) -> $dst"
}
