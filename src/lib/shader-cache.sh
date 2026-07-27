# shellcheck shell=bash
# Vulkan shader pre-cache: scope the GLCache env to cs2, and surface
# "Processing Vulkan shaders" progress parsed from Steam's shader_log.txt.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Export the NVIDIA shader disk-cache env for cs2 only (from do_applaunch).
# Applying it pod-wide regressed Steam bring-up (steamwebhelper/picom/hud
# stalled on GL init). Driver disables the cache for root and prunes to
# ~1 GiB, so we re-enable, point at the persistent dir, size to 10 GiB, and
# disable pruning. Override path with GL_SHADER_CACHE_DIR.
export_cs2_shader_cache_env() {
  : "${GL_SHADER_CACHE_DIR:=${STEAM_LIBRARY:-/mnt/game-streamer}/nvcache}"
  mkdir -p "$GL_SHADER_CACHE_DIR" 2>/dev/null || true
  export __GL_SHADER_DISK_CACHE="${__GL_SHADER_DISK_CACHE:-1}"
  export __GL_SHADER_DISK_CACHE_PATH="${__GL_SHADER_DISK_CACHE_PATH:-$GL_SHADER_CACHE_DIR}"
  export __GL_SHADER_DISK_CACHE_SIZE="${__GL_SHADER_DISK_CACHE_SIZE:-10737418240}"
  export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}"
  # Report current cache occupancy (bytes + file count). The driver disables the
  # GLCache for root, so the real question is whether it's actually persisting:
  # if this stays ~0 / doesn't grow run-over-run, the cache isn't working and
  # EVERY first segment renders cold-shader (the present-rate dip / stutter).
  local _cn _cb
  _cn=$(find "$__GL_SHADER_DISK_CACHE_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
  _cb=$(du -sh "$__GL_SHADER_DISK_CACHE_PATH" 2>/dev/null | awk '{print $1}')
  log "cs2 shader cache: path=$__GL_SHADER_DISK_CACHE_PATH size=$__GL_SHADER_DISK_CACHE_SIZE occupancy=${_cb:-?} files=${_cn:-?}"
}

shader_log_file() {
  printf '%s/logs/shader_log.txt' "${STEAM_HOME:-/root/.local/share/Steam}"
}

# Steam's Fossilize Vulkan shader cache for cs2 (steamapps/shadercache/730).
# This â€” NOT the NVIDIA GLCache (nvcache) â€” is where cs2's Vulkan pipelines come
# from, and it persists on the node's library volume. Path-only.
cs2_shadercache_dir() {
  printf '%s/steamapps/shadercache/730' "${STEAM_LIBRARY:-/mnt/game-streamer}"
}

# Current Fossilize cache occupancy in MiB (0 when missing) â€” for the warm-decision log.
cs2_shadercache_mib() {
  local d kib; d="$(cs2_shadercache_dir)"
  [ -d "$d" ] || { printf '0'; return; }
  kib=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  printf '%s' "$(( ${kib:-0} / 1024 ))"
}

# True when the node already has a populated Fossilize cache, so we can skip the
# one-time pre-warm. Heuristic: â‰¥50 MiB of compiled pipelines = warm; a cold/fresh
# node has the dir missing or near-empty. Override the floor with GS_SHADERCACHE_MIN_MIB.
cs2_shadercache_populated() {
  local d; d="$(cs2_shadercache_dir)"
  [ -d "$d" ] || return 1
  local kib; kib=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  [ -n "$kib" ] && [ "$kib" -ge "$(( ${GS_SHADERCACHE_MIN_MIB:-50} * 1024 ))" ]
}

# Whether to run the node shader pre-warm before a batch render. GS_WARM_SHADERS
# overrides: 1/on=always, 0/off=never. Default (auto): warm only when the
# Fossilize cache is cold â€” the first batch pod on a fresh node pays the one-time
# ~60-90s; warmed nodes skip it. Fixes the cold-shader first-segment fps dip.
should_warm_shaders() {
  case "${GS_WARM_SHADERS:-auto}" in
    1|on|true|yes)  return 0 ;;
    0|off|false|no) return 1 ;;
  esac
  ! cs2_shadercache_populated
}

# Echo "pct compiled total" from a "Still replaying 730 (NN%, d/t)." line.
_parse_shader_line() {
  local line="$1"
  if [[ "$line" =~ \(([0-9]+)%,\ ([0-9]+)/([0-9]+)\) ]]; then
    printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# In-process throttle (single-process loop â†’ a global suffices, no bg
# monitor that could die and freeze the UI).
_SHADER_LAST_REPORT=""
_SHADER_LOG_OFFSET=0

# Snapshot the shader log size so we only read THIS run's lines.
# shader_log.txt lives on the persistent volume and is appended across runs,
# so without this the first reading shows a stale % from the previous run
# (looks like "resumed then restarted"). Call once before wait_for_cs2_process.
shader_progress_reset() {
  local f
  f="$(shader_log_file)"
  _SHADER_LOG_OFFSET=$(stat -c %s "$f" 2>/dev/null || echo 0)
  _SHADER_LAST_REPORT=""
}

# Report compile progress; return 0 while actively compiling, else 1. Called
# inline once per wait_for_cs2_process iteration. Reports a precise
# compiled/total fraction so sub-1% movement shows (1% of CS2's ~723k
# pipelines is ~7k). Must be set -u safe. `compiled` not `done` (reserved).
shader_report_progress() {
  local f line parsed pct compiled total size
  f="$(shader_log_file)"
  [ -f "$f" ] || return 1
  # Only this run's lines. If the file shrank, Steam rotated it â€” read all.
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$size" -lt "${_SHADER_LOG_OFFSET:-0}" ] && _SHADER_LOG_OFFSET=0
  line=$(tail -c "+$(( ${_SHADER_LOG_OFFSET:-0} + 1 ))" "$f" 2>/dev/null \
    | grep -a 'Still replaying 730 ' | tail -1)
  parsed=$(_parse_shader_line "$line")
  [ -n "$parsed" ] || return 1
  read -r pct compiled total <<<"$parsed"

  local precise
  precise=$(awk -v d="${compiled:-0}" -v t="${total:-0}" \
    'BEGIN{ if (t+0<=0){ printf "0.0" } else { p=d*100.0/t; if(p<0)p=0; if(p>100)p=100; printf "%.1f", p } }')

  if [ "$precise" != "${_SHADER_LAST_REPORT:-}" ]; then
    _SHADER_LAST_REPORT="$precise"
    log "processing Vulkan shaders: ${precise}% (${compiled}/${total})"
    # progress_stage carries the raw count for the UI (rendered in parens,
    # stored in status_history â€” no web/api change needed).
    report_status status=processing_shaders progress="$precise" \
      progress_stage="${compiled} / ${total}" >/dev/null 2>&1 || true
  fi

  local now mtime age
  now=$(date +%s)
  mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  [ "${pct:-100}" -lt 100 ] && [ "$age" -le "${SHADER_ACTIVE_STALE:-45}" ]
}

# Operator "skip shaders": stop Steam's fossilize_replay precompile workers so
# the "Processing Vulkan shaders" step ends and cs2 launches. Deterministic and
# display-independent â€” unlike poking the CEF dialog, which needs a keystroke to
# land on the right focused button (Steam's dialog ignores keystrokes, and on
# coexist nodes the Steam UI is black/unrenderable, so the poke can't work).
# Returns 0 if it signalled at least one worker, else 1. Idempotent â€” called
# every loop while skip is requested; escalates TERM -> KILL across calls.
skip_shader_compile() {
  pgrep -f fossilize_replay >/dev/null 2>&1 || return 1
  if [ "${_SHADER_KILL_ESCALATED:-0}" = 1 ]; then
    pkill -KILL -f fossilize_replay 2>/dev/null || true
  else
    pkill -TERM -f fossilize_replay 2>/dev/null || true   # clean stop, flush cache
    _SHADER_KILL_ESCALATED=1
  fi
  return 0
}
