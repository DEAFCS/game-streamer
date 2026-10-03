# shellcheck shell=bash
# Shared helpers. Source from anywhere under src/.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SRC_DIR/lib"
FLOWS_DIR="$SRC_DIR/flows"
export SRC_DIR LIB_DIR FLOWS_DIR

: "${LOG_DIR:=/tmp/game-streamer}"
# start_xorg may have to fall back off :0 when the host already runs a
# desktop there. It records the resolved display in $LOG_DIR/display so
# fresh flows inherit the right value. The file wins over inherited env
# because game-streamer.sh sources common.sh first (exporting DISPLAY=:0)
# and then forks setup-steam / execs run-demo with that stale :0 still
# in their env â€” the file is the only source of truth across the
# fork/exec boundary.
if [ -r "$LOG_DIR/display" ]; then
  DISPLAY=$(cat "$LOG_DIR/display" 2>/dev/null)
fi
: "${DISPLAY:=:0}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-root}"
: "${STEAM_HOME:=/root/.local/share/Steam}"
: "${STEAM_LIBRARY:=/mnt/game-streamer}"
: "${CS2_DIR:=$STEAM_LIBRARY/steamapps/common/Counter-Strike Global Offensive}"
# Persistent NVIDIA GLCache dir (holds cs2's compiled Vulkan shaders). The
# __GL_SHADER_DISK_CACHE* env that enables it is exported per-cs2 only (see
# shader-cache.sh) â€” pod-wide regressed Steam bring-up.
: "${GL_SHADER_CACHE_DIR:=$STEAM_LIBRARY/nvcache}"
# Steam runs fossilize_replay rate-limited (background "don't hog the box"
# mode). This pod is dedicated, so let it run full-tilt. Only fossilize
# reads this, so it's safe to export globally.
: "${FOSSILIZE_DISABLE_RATE_LIMITER:=1}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
# mediamtx HTTP control API — start_capture times connects to it to size the
# SRT latency (see srt_latency_for_rtt in stream.sh).
: "${MEDIAMTX_API_BASE:=http://mediamtx.5stack.svc.cluster.local:9997}"
: "${GAME_STREAM_DOMAIN:=hls.5stack.gg}"
# LOG_DIR (defaulted above) is a misnomer â€” k8s captures stdout/stderr;
# this holds non-log state (status files, JSON caches, marker files,
# pid files, and the resolved-display pointer for cross-flow state).
# Xorg's setuid wrapper accepts only a BARE filename for -config (not
# an absolute path); the Dockerfile drops the file into /etc/X11/.
: "${CS2_DISPLAY_RES:=1920x1080}"
CS2_WIDTH="${CS2_DISPLAY_RES%x*}"
CS2_HEIGHT="${CS2_DISPLAY_RES#*x}"
# Pick the matching Xorg dummy config. Unknown resolutions fall back
# to 1080p â€” only the configs we ship work, anything else would die
# at Xorg startup. The available set is intentionally narrow: 1080p
# and 1440p match the UI's resolution selector.
case "$CS2_DISPLAY_RES" in
  2560x1440) : "${XORG_CONFIG:=xorg-dummy-1440p.conf}" ;;
  *)         : "${XORG_CONFIG:=xorg-dummy-1080p.conf}" ;;
esac
# Escaped closing brace: `${VAR:={}}` mis-parses to a bare `{` (invalid
# JSON); escaping yields the literal `{}` default.
: "${CS2_VIDEO_SETTINGS:={\}}"
mkdir -p "$LOG_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
# Driver won't create the GLCache dir itself.
mkdir -p "$GL_SHADER_CACHE_DIR" 2>/dev/null || true

export DISPLAY XDG_RUNTIME_DIR STEAM_HOME STEAM_LIBRARY CS2_DIR \
       MEDIAMTX_SRT_BASE MEDIAMTX_API_BASE GAME_STREAM_DOMAIN \
       LOG_DIR XORG_CONFIG CS2_VIDEO_SETTINGS \
       CS2_DISPLAY_RES CS2_WIDTH CS2_HEIGHT \
       GL_SHADER_CACHE_DIR FOSSILIZE_DISABLE_RATE_LIMITER

say()  { printf '\n=== %s ===\n' "$*"; }
log()  { printf '[%s] %s\n' "${SCRIPT_TAG:-game-streamer}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2; }
die()  {
  printf '[%s] ERROR: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2
  if declare -F report_status >/dev/null 2>&1; then
    report_status status=errored "error=$*" >/dev/null 2>&1 || true
  fi
  if declare -F broadcast_batch_error >/dev/null 2>&1; then
    broadcast_batch_error status=errored "error=$*" >/dev/null 2>&1 || true
  fi
  # Brief flush so the daemon's poll cycle PUTs before the Job is reaped.
  # batch_error is synchronous curl + wait, so it needs no flush; the
  # sleep is purely for the daemon path.
  if declare -F report_status >/dev/null 2>&1; then
    sleep "${STATUS_DIE_FLUSH_SECONDS:-3}" 2>/dev/null || true
  fi
  exit 1
}

# Detect cs2's GetClassBaseline replay crash (issue #3429): cs2 halts the demo
# but stays alive, so a render would capture frozen frames. The sentinel lets
# the rest of a batch skip once the session is dead.
CS2_FATAL_SENTINEL="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/.cs2-fatal"

# Echo the GetClassBaseline line if cs2 logged one since byte offset $1 (caller
# snapshots before playback so a stale line can't fail an unrelated job).
cs2_fatal_reason() {
  local log="${CS2_DIR}/game/csgo/console.log" since="${1:-0}" hit
  if [ -f "$log" ]; then
    hit=$(tail -c "+$((since + 1))" "$log" 2>/dev/null \
      | grep -aoE 'GetClassBaseline[^[:cntrl:]]*failed' | tail -1) || true
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  fi
  # console.log buffers; the Error dialog is a real-time X window.
  if command -v xdotool >/dev/null 2>&1 \
     && [ -n "$(timeout 3 xdotool search --name '^Error$' 2>/dev/null | head -1)" ]; then
    printf 'cs2 fatal Error dialog'
    return 0
  fi
  return 1
}

cs2_mark_fatal() {
  mkdir -p "$(dirname "$CS2_FATAL_SENTINEL")" 2>/dev/null || true
  printf '%s\n' "${1:-cs2 GetClassBaseline fatal}" > "$CS2_FATAL_SENTINEL" 2>/dev/null || true
}

# mawk (Ubuntu's awk) block-buffers its input from a pipe, so a daemon's lines only
# surfaced in bursts (often all at exit, every line carrying the same timestamp).
# -W interactive makes it read line by line; gawk doesn't need or know it.
if awk -W version 2>&1 | grep -q mawk; then GS_AWK_LINES=(-W interactive); else GS_AWK_LINES=(); fi

# Stdout+stderr of the daemon stream to this process's stderr with a
# "[<tag>] " prefix per line â€” k8s container logs become self-describing.
# nohup detaches so HUP doesn't kill it when launcher scripts exit;
# the awk subprocess reparents to PID 1 and keeps tagging.
spawn_logged() {
  local tag="$1"; shift
  nohup "$@" \
    > >(awk "${GS_AWK_LINES[@]}" -v t="$tag" '{print "["t"] " $0; fflush()}' >&2) \
    2>&1 &
  SPAWNED_PID=$!
}

# GStreamer element probes are slow — each gst-inspect / test pipeline loads the
# nvcodec plugin and initialises CUDA (~1-2s) — and most callers run inside $(...)
# subshells, where an exported "per-process" cache dies with the subshell: clip
# capture re-probed the encoder and scaler on every segment (~15s). The answers
# can't change for the life of the pod, so they're cached in a file.
GS_PROBE_CACHE="${GS_PROBE_CACHE:-/tmp/game-streamer/gst-probes.env}"

# Load <var> from the probe cache unless it's already set. 0 if it's set now.
_probe_cache_load() {
  local var="$1" line
  [ -n "${!var:-}" ] && return 0
  line=$(grep -m1 "^${var}=" "$GS_PROBE_CACHE" 2>/dev/null) || return 1
  printf -v "$var" '%s' "${line#*=}"
  export "${var?}"
  [ -n "${!var}" ]
}

# Append <var>'s value to the probe cache (the first entry wins on load).
_probe_cache_store() {
  local var="$1"
  [ -n "${!var:-}" ] || return 0
  mkdir -p "$(dirname "$GS_PROBE_CACHE")" 2>/dev/null || return 0
  printf '%s=%s\n' "$var" "${!var}" >> "$GS_PROBE_CACHE" 2>/dev/null || true
}

# Adaptive-quantization props for a CUDA NVENC element, when it has them: spatial AQ
# moves bits into flat/dark areas and fast detail (smoke, flashes, sky) that plain CBR
# leaves blocky; clips also get temporal AQ. Probed with gst-inspect once per pod (a
# property the element lacks would kill the pipeline at parse time).
# Usage: _nvenc_aq_props <element> <live|clip>
_nvenc_aq_props() {
  local el="$1" mode="$2" var="GS_AQ_${1//[!A-Za-z0-9]/_}" props=""
  if ! _probe_cache_load "$var"; then
    local spec
    spec=$(gst-inspect-1.0 "$el" 2>/dev/null)
    local found=""
    grep -q '^ *spatial-aq ' <<<"$spec" && found+="s"
    grep -q '^ *temporal-aq ' <<<"$spec" && found+="t"
    printf -v "$var" '%s' "${found:-none}"
    export "${var?}"
    [ -n "$spec" ] && _probe_cache_store "$var"
  fi
  case "${!var}" in *s*) props+=" spatial-aq=true" ;; esac
  [ "$mode" = clip ] && case "${!var}" in *t*) props+=" temporal-aq=true" ;; esac
  printf '%s' "$props"
}

# Pick an H.264 encoder fragment. Tries nvcudah264enc, then nvh264enc
# with a probed preset (driver 550+ dropped legacy preset GUIDs so
# strict validation rejects them), then x264enc. Cached in GS_NVENC_PICK
# and the probe cache; override with GS_NVENC_ELEMENT.
# Usage: pick_h264_pipeline <gop> <kbps> [live|clip]
pick_h264_pipeline() {
  local gop="${1:?gop required}"
  local kbps="${2:?kbps required}"
  local mode="${3:-live}"

  _ensure_nvenc_pick h264

  case "$GS_NVENC_PICK" in
    nvcudah264enc)
      # The modern CUDA encoder uses `rate-control` (not `rc-mode` like
      # the legacy nvh264enc) â€” wrong name dies at pipeline-parse.
      local preset tune
      case "$mode" in
        clip) preset="p5"; tune="high-quality" ;;
        *)    preset="p4"; tune="low-latency"  ;;
      esac
      # No leading `cudaupload` â€” pick_scale_convert owns the system->CUDA
      # upload (and does the scale/convert on the GPU when possible).
      printf 'nvcudah264enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s%s' \
        "$preset" "$tune" "$gop" "$kbps" "$(_nvenc_aq_props nvcudah264enc "$mode")"
      ;;
    nvh264enc:*)
      local preset="${GS_NVENC_PICK#nvh264enc:}"
      printf 'nvh264enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$kbps"
      ;;
    x264enc)
      printf 'x264enc tune=zerolatency speed-preset=veryfast bitrate=%s key-int-max=%s' \
        "$kbps" "$gop"
      ;;
    *)
      # Nothing resolved: fail here rather than hand back an empty encoder, which
      # turns the pipeline into "! !" and dies at parse time with a vaguer error.
      return 1
      ;;
  esac
}

_resolve_h264_method() {
  # Called via $(...) so stdout is captured into GS_NVENC_PICK. Any
  # informational logging MUST go to stderr â€” otherwise it gets glued
  # onto the encoder name and the gst-launch pipeline collapses to
  # "... ! ! ..." (syntax error).
  local force="${GS_NVENC_ELEMENT:-auto}"

  if [ "$force" = "auto" ] || [ "$force" = "nvcudah264enc" ]; then
    if gst-inspect-1.0 nvcudah264enc >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && _probe_nvcudah264enc; then
      log "  encoder: nvcudah264enc (GPU, modern API)" >&2
      printf 'nvcudah264enc'
      return 0
    fi
    [ "$force" = "nvcudah264enc" ] && \
      warn "GS_NVENC_ELEMENT=nvcudah264enc forced but unavailable"
  fi

  if [ "$force" = "auto" ] || [ "$force" = "nvh264enc" ]; then
    if gst-inspect-1.0 nvh264enc >/dev/null 2>&1; then
      local preset
      if preset=$(_probe_nvh264enc_preset); then
        log "  encoder: nvh264enc preset=$preset (GPU, legacy API)" >&2
        printf 'nvh264enc:%s' "$preset"
        return 0
      fi
    fi
    [ "$force" = "nvh264enc" ] && \
      warn "GS_NVENC_ELEMENT=nvh264enc forced but unavailable"
  fi

  log "  encoder: x264enc (software fallback)" >&2
  printf 'x264enc'
}

# Probe with the SAME property surface used in production â€” a future
# GStreamer rev that renames/drops a property fails here instead of
# silently passing and crashing at real-pipeline parse mid-match.
_probe_nvcudah264enc() {
  gst-launch-1.0 -q \
    videotestsrc num-buffers=1 \
    ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
    ! cudaupload \
    ! nvcudah264enc preset=p4 tune=low-latency rate-control=cbr gop-size=60 bitrate=2000 \
    ! fakesink sync=false \
    >/dev/null 2>&1
}

_probe_nvh264enc_preset() {
  local p
  for p in ${NVH264_PRESET_CANDIDATES:-low-latency-hq low-latency hq default}; do
    if gst-launch-1.0 -q \
         videotestsrc num-buffers=1 \
         ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
         ! nvh264enc preset="$p" \
         ! fakesink sync=false \
         >/dev/null 2>&1
    then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Pick an H.265/HEVC encoder fragment. Returns nonzero if no NVENC HEVC
# encoder is available; caller must fall back to h264 (no software fallback â€”
# libx265 is too slow for the live and clip ffmpeg passes).
# kbps is the h264-equivalent target; scaled to 70% internally for HEVC.
# Cached in GS_NVENC_PICK_H265; override with GS_NVENC_H265_ELEMENT.
# Usage: pick_h265_pipeline <gop> <kbps-h264-equiv> [live|clip]
pick_h265_pipeline() {
  local gop="${1:?gop required}"
  local kbps="${2:?kbps required}"
  local mode="${3:-live}"

  _ensure_nvenc_pick h265

  local h265_kbps=$((kbps * 7 / 10))

  case "${GS_NVENC_PICK_H265:-none}" in
    nvcudah265enc)
      local preset tune
      case "$mode" in
        clip) preset="p5"; tune="high-quality" ;;
        *)    preset="p4"; tune="low-latency"  ;;
      esac
      # No leading `cudaupload` â€” pick_scale_convert owns the system->CUDA
      # upload (and does the scale/convert on the GPU when possible).
      printf 'nvcudah265enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s%s' \
        "$preset" "$tune" "$gop" "$h265_kbps" "$(_nvenc_aq_props nvcudah265enc "$mode")"
      ;;
    nvh265enc:*)
      local preset="${GS_NVENC_PICK_H265#nvh265enc:}"
      printf 'nvh265enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$h265_kbps"
      ;;
    none|"")
      return 1
      ;;
    *)
      warn "GS_NVENC_PICK_H265='${GS_NVENC_PICK_H265}' unrecognized â€” treating as no NVENC HEVC"
      return 1
      ;;
  esac
}

# 0 if NVENC HEVC is available on this pod. Caches into GS_NVENC_PICK_H265.
h265_available() {
  _ensure_nvenc_pick h265
  case "${GS_NVENC_PICK_H265:-none}" in
    none|"") return 1 ;;
    *)       return 0 ;;
  esac
}

_resolve_h265_method() {
  # Log to stderr only â€” stdout is captured into GS_NVENC_PICK_H265.
  local force="${GS_NVENC_H265_ELEMENT:-auto}"

  if [ "$force" = "auto" ] || [ "$force" = "nvcudah265enc" ]; then
    if gst-inspect-1.0 nvcudah265enc >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && _probe_nvcudah265enc; then
      log "  encoder: nvcudah265enc (GPU, modern API)" >&2
      printf 'nvcudah265enc'
      return 0
    fi
    [ "$force" = "nvcudah265enc" ] && \
      warn "GS_NVENC_H265_ELEMENT=nvcudah265enc forced but unavailable â€” falling through"
  fi

  if [ "$force" = "auto" ] || [ "$force" = "nvh265enc" ]; then
    if gst-inspect-1.0 nvh265enc >/dev/null 2>&1; then
      local preset
      if preset=$(_probe_nvh265enc_preset); then
        log "  encoder: nvh265enc preset=$preset (GPU, legacy API)" >&2
        printf 'nvh265enc:%s' "$preset"
        return 0
      fi
    fi
    [ "$force" = "nvh265enc" ] && \
      warn "GS_NVENC_H265_ELEMENT=nvh265enc forced but unavailable â€” falling through"
  fi

  log "  encoder: no NVENC HEVC encoder available â€” caller will fall back to h264" >&2
  printf 'none'
  return 1
}

_probe_nvcudah265enc() {
  gst-launch-1.0 -q \
    videotestsrc num-buffers=1 \
    ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
    ! cudaupload \
    ! nvcudah265enc preset=p4 tune=low-latency rate-control=cbr gop-size=60 bitrate=2000 \
    ! fakesink sync=false \
    >/dev/null 2>&1
}

_probe_nvh265enc_preset() {
  local p
  for p in ${NVH265_PRESET_CANDIDATES:-low-latency-hq low-latency hq default}; do
    if gst-launch-1.0 -q \
         videotestsrc num-buffers=1 \
         ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
         ! nvh265enc preset="$p" \
         ! fakesink sync=false \
         >/dev/null 2>&1
    then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Populate the NVENC pick cache for $codec if cold. pick_h26{4,5}_pipeline runs
# in a `$(...)` subshell so its cached export never reaches the parent;
# re-resolve here (same probe, stderr muted) so the scaler's CUDA-vs-CPU choice
# matches the chosen encoder — else the scaler picks CPU for a CUDA encoder.
# Resolve once per pod: the env, then the probe cache, then a real probe. Only GPU
# picks are cached — x264enc / none can be a transient NVENC failure worth retrying.
# Usage: _ensure_nvenc_pick <h264|h265> [quiet]  (quiet mutes the probe's log line)
_ensure_nvenc_pick() {
  local var=GS_NVENC_PICK resolve=_resolve_h264_method pick
  case "${1:-h264}" in
    h265|hevc) var=GS_NVENC_PICK_H265 resolve=_resolve_h265_method ;;
  esac
  _probe_cache_load "$var" && return 0
  if [ "${2:-}" = quiet ]; then
    pick=$("$resolve" 2>/dev/null) || true
  else
    pick=$("$resolve") || true
  fi
  printf -v "$var" '%s' "$pick"
  export "${var?}"
  case "$pick" in nv*) _probe_cache_store "$var" ;; esac
  return 0
}

# True when the resolved NVENC element for $codec is the modern CUDA
# encoder (nvcuda*), which consumes CUDA memory and so must be fed an upload.
# Self-heals a cold cache via _ensure_nvenc_pick so it's correct even when
# called from a different subshell than the one that picked the encoder.
_active_encoder_is_cuda() {
  _ensure_nvenc_pick "${1:-h264}" quiet
  case "${1:-h264}" in
    h265|hevc) [ "${GS_NVENC_PICK_H265:-}" = "nvcudah265enc" ] ;;
    *)         [ "${GS_NVENC_PICK:-}" = "nvcudah264enc" ] ;;
  esac
}

# True when GPU scale+convert is usable: not disabled via GS_GPU_SCALE, and
# both cudaupload + cudaconvertscale exist on this pod. Cached per pod.
_cuda_scale_available() {
  case "${GS_GPU_SCALE:-auto}" in
    0|off|false|no) return 1 ;;
  esac
  if ! _probe_cache_load GS_CUDASCALE_OK; then
    if gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaconvertscale >/dev/null 2>&1; then
      GS_CUDASCALE_OK=1
    else
      GS_CUDASCALE_OK=0
    fi
    export GS_CUDASCALE_OK
    # Only cache a success: one transient gst-inspect/CUDA failure must not pin the
    # pod to CPU scaling for its whole life.
    [ "$GS_CUDASCALE_OK" = 1 ] && _probe_cache_store GS_CUDASCALE_OK
  fi
  [ "$GS_CUDASCALE_OK" = 1 ]
}

# Emit the scale + colorspace-convert fragment that feeds the encoder.
# When the active encoder is a CUDA NVENC element and cudaconvertscale is
# present, the scale (e.g. 1440p->1080p) and RGBx->NV12 convert run on the
# GPU (cudaupload ! cudaconvertscale), removing the CPU videoscale +
# videoconvert that otherwise competes with cs2 for cores. The CUDA encoder
# fragments deliberately drop their own cudaupload â€” this fragment owns it.
# Falls back to the all-CPU path for legacy nvenc / x264, and to a
# CPU-convert-then-upload path if a CUDA encoder is paired with a pod that
# lacks cudaconvertscale (so the encoder still receives CUDA memory).
# Usage: pick_scale_convert <out_w> <out_h> <fps> <codec>
pick_scale_convert() {
  local w="${1:?width required}" h="${2:?height required}"
  local fps="${3:?fps required}" codec="${4:-h264}"
  local cpu="videoscale ! video/x-raw,width=${w},height=${h},framerate=${fps}/1 ! videoconvert ! video/x-raw,format=NV12"
  if _active_encoder_is_cuda "$codec"; then
    if _cuda_scale_available; then
      log "  scaler: cudaconvertscale (GPU scale+convert)" >&2
      printf 'cudaupload ! cudaconvertscale ! video/x-raw(memory:CUDAMemory),format=NV12,width=%s,height=%s,framerate=%s/1' \
        "$w" "$h" "$fps"
      return 0
    fi
    # CUDA encoder but no GPU scaler: convert on CPU, then upload so the
    # encoder still gets the CUDA memory it requires.
    log "  scaler: CPU videoscale+videoconvert then cudaupload (cudaconvertscale unavailable)" >&2
    printf '%s ! cudaupload' "$cpu"
    return 0
  fi
  log "  scaler: CPU videoscale+videoconvert" >&2
  printf '%s' "$cpu"
}

# Contract guard for the pick_scale_convert -> encoder pairing: a CUDA NVENC
# element (nvcudah26{4,5}enc) consumes CUDA memory, which pick_scale_convert
# supplies (cudaupload / cudaconvertscale). Warns loudly if a caller paired a CUDA
# encoder with a convert fragment that doesn't produce CUDA memory â€” i.e. built a
# pipeline without pick_scale_convert in front of the encoder. Usage:
# _assert_cuda_chain "<convert fragment>" "<encoder fragment>".
_assert_cuda_chain() {
  case "$2" in
    *nvcudah264enc*|*nvcudah265enc*)
      case "$1" in
        *cudaupload*|*CUDAMemory*) ;;
        *) warn "BUG: CUDA encoder fed non-CUDA memory â€” pick_scale_convert must precede the encoder (convert='$1')" ;;
      esac ;;
  esac
}

# obs-vkcapture present-hook needs nvidia-drm modeset on (its dmabuf sharing).
# True unless we have POSITIVE evidence it's off â€” the host kernel param is visible
# via the shared /sys; unreadable/absent -> assume on (don't block the default path
# on a missing sysfs).
_drm_modeset_on() {
  local f=/sys/module/nvidia_drm/parameters/modeset v
  [ -r "$f" ] || return 0
  v=$(cat "$f" 2>/dev/null)
  [ "$v" != "N" ] && [ "$v" != "0" ]
}

# CPU split between cs2 and the capture pipeline. Pinning the capture consumer to
# the top cores only ISOLATES it if cs2 is confined to the complementary cores â€”
# otherwise cs2's threads still schedule onto the capture cores and the two fight
# (which jitters cs2's present + starves its audio thread â†’ the frame/audio
# hitch). This computes one consistent split: capture gets the top CAPTURE_CORES
# cores (default 2), cs2 gets the rest. Sets GS_CAPTURE_CPUS + GS_CS2_CPUS (taskset
# -c lists). Env overrides win: pre-set CAPTURE_CPUS / CS2_CPUS are honored as-is;
# empty string = "don't pin this side". Only splits on a box with â‰¥4 cores (below
# that, carving out cores starves cs2 more than contention does). Idempotent.
compute_cpu_split() {
  [ -n "${GS_CPU_SPLIT_DONE:-}" ] && return 0
  local ncpu capn caphi caplo
  ncpu=$(nproc 2>/dev/null || echo 0)
  if [ "$ncpu" -ge 4 ]; then
    capn="${CAPTURE_CORES:-2}"
    [ "$capn" -lt 1 ] && capn=1
    [ "$capn" -ge "$ncpu" ] && capn=$(( ncpu - 1 ))
    caplo=$(( ncpu - capn )); caphi=$(( ncpu - 1 ))
    # `+x` test: only fill in a side the caller didn't explicitly set (even to "").
    # Capture pin: status quo from â‰¥4 cores. cs2 pin: only once there are enough
    # cores that confining cs2 still leaves it a healthy share â€” below
    # GS_CS2_PIN_MIN_CORES (default 6 â†’ cs2 keeps â‰¥4) we'd hand heavily-threaded
    # cs2 too few exclusive cores, which hurts more than the contention it removes.
    [ -z "${CAPTURE_CPUS+x}" ] && CAPTURE_CPUS="${caplo}-${caphi}"
    # Streams (not clip batches) also run the HUD (Electron), spec-server and picom
    # all the time; give them AUX_CORES (default 1) just below the capture cores so
    # they stop preempting cs2. Only with ≥ GS_AUX_PIN_MIN_CORES (10) cores.
    local auxn=0
    if [ -z "${AUX_CPUS+x}" ] && [ "${CLIP_BATCH_MODE:-0}" != "1" ] \
       && [ "$ncpu" -ge "${GS_AUX_PIN_MIN_CORES:-10}" ]; then
      auxn="${AUX_CORES:-1}"
      [ "$auxn" -ge 1 ] && AUX_CPUS="$(( caplo - auxn ))-$(( caplo - 1 ))"
    fi
    if [ -z "${CS2_CPUS+x}" ] && [ "$ncpu" -ge "${GS_CS2_PIN_MIN_CORES:-6}" ]; then
      CS2_CPUS="0-$(( caplo - auxn - 1 ))"
    fi
  fi
  GS_CAPTURE_CPUS="${CAPTURE_CPUS:-}"
  GS_CS2_CPUS="${CS2_CPUS:-}"
  GS_AUX_CPUS="${AUX_CPUS:-}"
  GS_CPU_SPLIT_DONE=1
  export GS_CAPTURE_CPUS GS_CS2_CPUS GS_AUX_CPUS GS_CPU_SPLIT_DONE CAPTURE_CPUS CS2_CPUS AUX_CPUS
}

# Set the CPU affinity of <pid>, every thread of it, and all its descendants.
# Threads and children created later inherit it. Usage: pin_pid_tree <cpus> <pid>
pin_pid_tree() {
  local cpus="$1" pid="$2" kid
  [ -n "$cpus" ] && [ -n "$pid" ] && command -v taskset >/dev/null 2>&1 || return 0
  taskset -a -p -c "$cpus" "$pid" >/dev/null 2>&1 || return 0
  for kid in $(pgrep -P "$pid" 2>/dev/null); do pin_pid_tree "$cpus" "$kid"; done
}

# Apply the CPU split to the running processes. cs2 is started by the already-running
# Steam client (-applaunch just forwards the command line and exits), so wrapping
# the launch in taskset never reached it: cs2 ran on every core, capture cores
# included. Pin it — and, on streams, the HUD/spec-server/picom — once it's up.
apply_cpu_split() {
  compute_cpu_split
  local cs2
  cs2=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  if [ -n "$cs2" ] && [ -n "$GS_CS2_CPUS" ]; then
    pin_pid_tree "$GS_CS2_CPUS" "$cs2"
    log "cpu split: cs2 (pid $cs2) -> cores $GS_CS2_CPUS"
  fi
  pin_aux_procs
}

# Move the HUD (Electron) and picom onto the AUX core. Not spec-server: affinity is
# inherited, and it starts on-demand clip renders (routes/render-clip.mjs) and
# switch-match.sh, which would then capture, render the chip and encode on that one
# core. Also called when the HUD respawns (position_hud_overlay).
pin_aux_procs() {
  compute_cpu_split
  [ -n "$GS_AUX_CPUS" ] || return 0
  local p n=0
  for p in $(pgrep -f '[j]ts-hud-manager') $(pgrep -x picom); do
    pin_pid_tree "$GS_AUX_CPUS" "$p"; n=$((n + 1))
  done
  log "cpu split: HUD/picom ($n procs) -> cores $GS_AUX_CPUS; capture -> ${GS_CAPTURE_CPUS:-all}"
}

# taskset prefix array for cs2: confines cs2 to GS_CS2_CPUS so it never shares a
# core with the capture pipeline. Usage: read into an array, prepend to the launch
# cmd. Empty (no-op) when taskset is missing or the split decided not to pin.
cs2_cpu_pin() {
  compute_cpu_split
  if [ -n "${GS_CS2_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
    printf 'taskset\n-c\n%s\n' "$GS_CS2_CPUS"
  fi
}

# True when CLIP_CAPTURE_METHOD selects vkcapture AND it can run here (consumer
# binary built + modeset on). Drives the present-hook for clips, and for the
# live/demo composite (cs2 via present-hook + HUD overlay) in stream.sh. A miss =>
# the ximagesrc fallback, which needs no DRM. NOTE: does not check cs2-running â€”
# callers that capture pre-cs2 (DEBUG_STREAM boot) gate on that separately.
vkcapture_available() {
  [ "${CLIP_CAPTURE_METHOD:-vkcapture}" = "vkcapture" ] || return 1
  command -v vkcapture-consumer >/dev/null 2>&1 || return 1
  _drm_modeset_on
}

# Trap-friendly verbose toggle. `GS_TRACE=1 ./game-streamer.sh ...` runs
# under `set -x` so every command is echoed.
[ "${GS_TRACE:-0}" = "1" ] && set -x

require_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "missing required env: $v"
  done
}

load_env() {
  local f="$SRC_DIR/.env"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}
