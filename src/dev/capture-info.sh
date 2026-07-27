#!/usr/bin/env bash
# Dry-run (no stream needed): show which NVENC encoder and which
# scale/convert path the capture pipeline will pick on THIS pod, so you can
# confirm the GPU scale path (cudaconvertscale) is actually active before
# spending a match on it.
#
# Usage: src/dev/capture-info.sh [h265|h264]
#   defaults to LIVE_VIDEO_CODEC (or h264). Honors LIVE_OUTPUT_DIMS, FPS,
#   VIDEO_KBPS, GS_GPU_SCALE, GS_NVENC_ELEMENT just like the live pipeline.
set -uo pipefail
SCRIPT_TAG=capture-info

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-tune.sh"

CODEC="${1:-${LIVE_VIDEO_CODEC:-h264}}"
OUT="${LIVE_OUTPUT_DIMS:-1920x1080}"
W="${OUT%x*}"; H="${OUT#*x}"
FPS="${FPS:-60}"
GOP=$(( FPS * 2 ))
KBPS="${VIDEO_KBPS:-12000}"

say "Hardware auto-tune"
GPU_NAME="$(detect_gpu_name)"
log "gpu='${GPU_NAME:-unknown}' tier=$(classify_gpu_tier "$GPU_NAME") cores=$(nproc 2>/dev/null || echo '?')"
cs2_autotune

say "Inputs"
log "codec=$CODEC out=${W}x${H} fps=$FPS gop=$GOP kbps=$KBPS"
log "GS_GPU_SCALE=${GS_GPU_SCALE:-auto} GS_NVENC_ELEMENT=${GS_NVENC_ELEMENT:-auto} GS_NVENC_H265_ELEMENT=${GS_NVENC_H265_ELEMENT:-auto}"

say "Encoder selection (runs the same gst-inspect probes as a real stream)"
enc=""
if [ "$CODEC" = h265 ] || [ "$CODEC" = hevc ]; then
  if enc=$(pick_h265_pipeline "$GOP" "$KBPS" live); then
    :
  else
    log "no NVENC HEVC on this pod -> live would fall back to h264"
    CODEC=h264
  fi
fi
if [ "$CODEC" = h264 ]; then
  enc=$(pick_h264_pipeline "$GOP" "$KBPS" live)
fi
log "encoder fragment : $enc"

say "Scale/convert selection"
conv=$(pick_scale_convert "$W" "$H" "$FPS" "$CODEC")
log "scaler fragment  : $conv"

say "Verdict"
if [[ "$conv" == *cudaconvertscale* ]]; then
  log "GPU scale+convert ACTIVE â€” videoscale/videoconvert are OFF the CPU."
elif [[ "$conv" == *cudaupload ]]; then
  log "CUDA encoder but CPU convert â€” cudaconvertscale not found on this pod."
  log "  (encoder still needs CUDA memory, so we CPU-convert then upload.)"
  log "  Install gstreamer's cudaconvertscale (nvcodec plugin) for the GPU path."
else
  log "CPU scale+convert â€” encoder is not CUDA-based, or GS_GPU_SCALE disables it."
  log "  Encoder picked: ${GS_NVENC_PICK_H265:-} ${GS_NVENC_PICK:-} (legacy nvenc/x264 -> no GPU scale)."
fi
