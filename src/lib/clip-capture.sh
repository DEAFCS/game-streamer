# shellcheck shell=bash
# File-output GStreamer pipeline for render-clip â€” mirrors stream.sh
# but writes a local mp4 (qtmux + filesink) instead of publishing.

# start_clip_capture <output-file> [fps] [video-kbps] [audio]
# Sets $CLIP_CAPTURE_PID; stop with stop_clip_capture for clean EOS.
# Dispatches on CLIP_CAPTURE_METHOD:
#   vkcapture â€” obs-vkcapture Vulkan present-hook (DEFAULT). The layer inside cs2
#               (OBS_VKCAPTURE=1) shares the swapchain over a socket; our
#               vkcapture-consumer feeds it into the NVENC pipeline below. Never
#               touches the X server, so it can't stall cs2's present (the
#               gunfight-stutter fix). Needs nvidia-drm.modeset=1 on the host.
#   ximagesrc â€” the gstreamer X11-grab pipeline; fallback if vkcapture can't start.
# vkcapture is gated on three preflight checks (binary present, nvidia-drm modeset
# on â€” _drm_modeset_on in common.sh, consumer survives spawn); any miss => ximagesrc,
# which needs no DRM and always works. The modeset gate matters because a modeset-off
# node would spawn the consumer fine but never receive a dmabuf â€” so without it we'd
# produce empty segments instead of degrading cleanly.
start_clip_capture() {
  local method="${CLIP_CAPTURE_METHOD:-vkcapture}"
  CLIP_CAPTURE_READY_FILE=""
  CLIP_CAPTURE_START_FILE=""
  if [ "$method" = "vkcapture" ]; then
    if ! command -v vkcapture-consumer >/dev/null 2>&1; then
      warn "CLIP_CAPTURE_METHOD=vkcapture but vkcapture-consumer not installed â€” using ximagesrc"
    elif ! _drm_modeset_on; then
      warn "CLIP_CAPTURE_METHOD=vkcapture but nvidia-drm modeset is OFF â€” using ximagesrc (set nvidia-drm.modeset=1 on the host to enable the present-hook)"
    elif _start_clip_capture_vkcapture "$@"; then
      return 0
    else
      warn "vkcapture capture failed to start â€” falling back to ximagesrc"
    fi
  fi
  _start_clip_capture_gst "$@"
}

# Resolve the NVENC encoder fragment + parser for a clip, honoring CLIP_VIDEO_CODEC
# (h264 default; falls back to h264 if no NVENC HEVC). Sets CLIP_ENC / CLIP_PARSE_CAPS
# / CLIP_CODEC. The hvc1 caps on h265 are required for mp4 / Safari / iOS playback.
_clip_resolve_encoder() {
  local gop="$1" kbps="$2"
  CLIP_CODEC="${CLIP_VIDEO_CODEC:-h264}"
  CLIP_ENC="" CLIP_PARSE_CAPS=""
  case "$CLIP_CODEC" in
    h265|hevc)
      if CLIP_ENC=$(pick_h265_pipeline "$gop" "$kbps" clip); then
        CLIP_PARSE_CAPS="h265parse config-interval=1 ! video/x-h265,stream-format=hvc1,alignment=au"
        return 0
      fi
      warn "CLIP_VIDEO_CODEC=$CLIP_CODEC but no NVENC HEVC encoder available â€” falling back to h264"
      ;;
    h264) : ;;
    *) warn "CLIP_VIDEO_CODEC=$CLIP_CODEC unrecognized â€” using h264" ;;
  esac
  CLIP_CODEC=h264
  CLIP_ENC=$(pick_h264_pipeline "$gop" "$kbps" clip)
  CLIP_PARSE_CAPS="h264parse config-interval=1"
}

# vkcapture: feed cs2's Vulkan swapchain (obs-vkcapture layer -> our
# vkcapture-consumer) into the SAME NVENC encode tail as the ximagesrc path. The
# consumer runs a GStreamer pipeline whose source is `appsrc name=vksrc` and pushes
# frames sampled from the shared dmabuf at $fps; encode/scale/mux are byte-for-byte
# the gst path, so output dims, codec selection and audio behave identically. The
# consumer finalizes the mp4 on SIGINT (clean EOS), same contract as stop_clip_capture.
_start_clip_capture_vkcapture() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-16000}"
  local audio="${4:-1}"

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))

  local out_w="${CLIP_OUTPUT_DIMS%x*}"
  local out_h="${CLIP_OUTPUT_DIMS#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

  mkdir -p "$(dirname "$out_file")"
  rm -f "$out_file"

  # The consumer touches this the instant it's ARMED (shared texture mapped, frames
  # arriving). wait_clip_capture_ready blocks on it before the caller starts playback.
  CLIP_CAPTURE_READY_FILE="${out_file}.ready"
  rm -f "$CLIP_CAPTURE_READY_FILE"
  export VKCAP_READY_FILE="$CLIP_CAPTURE_READY_FILE"

  # ...and holds every armed frame until clip_capture_go touches this. The caller
  # opens the gate once the demo is confirmed moving, so the mp4 doesn't open on the
  # paused SEG_START frame cs2 holds while it processes the unpause.
  CLIP_CAPTURE_START_FILE="${out_file}.go"
  rm -f "$CLIP_CAPTURE_START_FILE"
  export VKCAP_START_FILE="$CLIP_CAPTURE_START_FILE"

  _clip_resolve_encoder "$gop" "$kbps"
  local codec="$CLIP_CODEC" enc="$CLIP_ENC" parse_caps="$CLIP_PARSE_CAPS"

  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")
  _assert_cuda_chain "$convert" "$enc"

  # Zero-copy dmabuf import (VKCAP_ZEROCOPY, default ON): the consumer hands appsrc
  # a DEVICE-LOCAL dmabuf and cudaupload imports it on the GPU â€” the CPU never
  # copies a frame (vs. the host-map wc_copy + PCIe round-trip). Preflight gates it
  # to where it can work: the encode chain must be CUDA (a CPU videoconvert can't
  # consume memory:DMABuf) and this gst's cudaupload must advertise DMABuf import.
  # Either miss => host-map copy path (correct, just costs the CPU copy).
  local zc="${VKCAP_ZEROCOPY:-1}"
  if [ "$zc" != "0" ]; then
    if [[ "$convert" != *cudaupload* ]]; then
      warn "zero-copy wanted but encode chain isn't CUDA (no cudaupload) â€” using host-map copy"
      zc=0
    elif ! _cudaupload_dmabuf_ok; then
      warn "zero-copy wanted but this gst cudaupload lacks memory:DMABuf import â€” using host-map copy"
      zc=0
    else
      zc=1
    fi
  fi

  log "  clip capture: $out_file (vkcapture/present-hook -> ${out_w}x${out_h}@${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  export VKCAP_FPS="$fps"
  # Diagnostics: when the per-segment capture diag is on, have the consumer log
  # presents/s each second too. It's present-locked, so presents/s == cs2's real
  # render fps â€” this is the missing signal next to the DIAG gpu/cpu lines (a low
  # presents/s with GPU pegged = GPU-bound; low presents/s with GPU idle + cs2cpu
  # near one core = sim/CPU-bound). Set CLIP_CAPTURE_DIAG=0 to mute both.
  [ "${CLIP_CAPTURE_DIAG:-1}" = "1" ] && export VKCAP_DEBUG="${VKCAP_DEBUG:-1}"
  # Pin the consumer to dedicated high cores so its gst threads don't pile
  # (wake-affinity) onto a core cs2 is using and jitter the sampling. cs2 is
  # pinned to the complementary cores at launch (cs2_cpu_pin), so the split is
  # real â€” they never share a core. CAPTURE_CPUS overrides the list (empty = no pin).
  local capture_pin=()
  compute_cpu_split
  if [ -n "${GS_CAPTURE_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
    capture_pin=(taskset -c "$GS_CAPTURE_CPUS")
    log "  clip capture pinned to cores $GS_CAPTURE_CPUS (cs2 confined to ${GS_CS2_CPUS:-all})"
  fi

  # Spawn the consumer. Zero-copy can still fail at runtime on a bad node
  # (driver / dmabuf modifier); if the consumer dies on spawn, retry ONCE with
  # zero-copy off (host-map copy) before giving up to ximagesrc â€” host-map
  # vkcapture still beats the X-server grab.
  local attempt
  for attempt in 1 2; do
    export VKCAP_ZEROCOPY="$zc"
    # $vfeat tags the appsrc caps with memory:DMABuf so the feature survives the
    # framerate filter into cudaupload. appsrc (name=vksrc) is filled by the
    # consumer from cs2's swapchain; everything downstream matches the ximagesrc
    # path. qtmux faststart=true keeps moov first. videorate + framerate caps ->
    # exact CFR (appsrc frames are do-timestamp stamped on the live clock, so timing
    # can wobble; videorate dups/drops to lock $fps).
    local vfeat=""
    [ "$zc" = "1" ] && { vfeat="(memory:DMABuf)"; log "  clip capture: zero-copy dmabuf import ON (no CPU frame copy)"; }
    local vsrc="appsrc name=vksrc ! queue ! videorate ! video/x-raw${vfeat},framerate=$fps/1"
    local pipeline
    if [ "$audio" = "1" ]; then
      # Deep pulsesrc buffer (2s) + a non-leaky 2s audio queue: file output has no
      # latency budget, so the slack lets a transient video-encode stall ride through
      # without the Pulse capture overflowing -> the audio hitch. provide-clock=false
      # keeps a jittery monitor source from driving the pipeline clock.
      pipeline="$vsrc ! $convert ! $enc ! $parse_caps ! queue ! mux. \
pulsesrc device=$pulse_source buffer-time=2000000 provide-clock=false ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! audioresample ! avenc_aac bitrate=192000 ! aacparse ! queue max-size-time=2000000000 max-size-buffers=0 max-size-bytes=0 ! mux. \
qtmux faststart=true name=mux ! filesink location=$out_file"
    else
      pipeline="$vsrc ! $convert ! $enc ! $parse_caps ! qtmux faststart=true ! filesink location=$out_file"
    fi
    spawn_logged vkcap-clip "${capture_pin[@]}" vkcapture-consumer "$pipeline"
    local pid=$SPAWNED_PID
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
      CLIP_CAPTURE_PID=$pid
      return 0
    fi
    if [ "$zc" = "1" ]; then
      warn "zero-copy consumer died on spawn â€” retrying with host-map copy"
      zc=0
      continue
    fi
    warn "vkcapture-consumer died on spawn â€” obs-vkcapture layer not loaded in cs2 (OBS_VKCAPTURE=1 launch option?), nvidia-drm.modeset=1 missing on host, or bad gst pipeline"
    return 1
  done
  return 1
}

# Reads $CLIP_OUTPUT_DIMS from env to scale capture â†’ output dims so
# the produced mp4 is always at the spec'd resolution regardless of
# the X display's native size (the node may run CS2 at 1080p or 1440p).
_start_clip_capture_gst() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-16000}"
  local audio="${4:-1}"

  # ximagesrc grabs as soon as the pipeline hits PLAYING, so this path has neither a
  # first-frame marker to wait on nor a start gate to hold — it records the held
  # SEG_START frame like it always did (also clears markers left by a failed
  # vkcapture attempt that fell through to here).
  CLIP_CAPTURE_READY_FILE=""
  CLIP_CAPTURE_START_FILE=""

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))
  local gst_tag="gst-clip"

  # Output dims: scale capture to CLIP_OUTPUT_DIMS (e.g. 1920x1080). The
  # chip overlay + outro are rendered/picked at the same dims, so the
  # ffmpeg polish + concat passes downstream don't hit dimension
  # mismatches even when the X display is 1440p.
  local out_w="${CLIP_OUTPUT_DIMS%x*}"
  local out_h="${CLIP_OUTPUT_DIMS#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

  mkdir -p "$(dirname "$out_file")"
  rm -f "$out_file"

  _clip_resolve_encoder "$gop" "$kbps"
  local codec="$CLIP_CODEC" enc="$CLIP_ENC" parse_caps="$CLIP_PARSE_CAPS"

  log "  clip capture: $out_file (${out_w}x${out_h}@${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  # GPU scale+convert when the encoder is CUDA-based (see pick_scale_convert).
  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")
  _assert_cuda_chain "$convert" "$enc"

  # qtmux faststart=true puts moov first so the api streams uploads to S3 without buffering.
  if [ "$audio" = "1" ]; then
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! $convert \
        ! $enc \
        ! $parse_caps \
        ! queue ! mux. \
      pulsesrc device="$pulse_source" buffer-time=2000000 provide-clock=false \
        ! audio/x-raw,rate=48000,channels=2 \
        ! audioconvert \
        ! audioresample \
        ! avenc_aac bitrate=192000 \
        ! aacparse \
        ! queue max-size-time=2000000000 max-size-buffers=0 max-size-bytes=0 ! mux. \
      qtmux faststart=true name=mux \
        ! filesink location="$out_file"
  else
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! $convert \
        ! $enc \
        ! $parse_caps \
        ! qtmux faststart=true \
        ! filesink location="$out_file"
  fi

  local pid=$SPAWNED_PID
  # 300ms catches spawn failures; the segment loop catches mid-render deaths.
  # Longer waits add frozen-frame padding at the start of the mp4.
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "clip capture died on spawn"
    return 1
  fi
  CLIP_CAPTURE_PID=$pid
  return 0
}

# Block until the capture is ARMED, so the caller never starts playback into a
# pipeline that isn't ready yet. On the vkcapture path the obs-vkcapture layer
# inside cs2 retries connect() on a 1s cadence and the swapchain handshake follows,
# so a freshly spawned consumer can be ~0.5-2s from its first buffer — every one of
# those seconds used to be demo time that played with nothing being recorded, which
# is what ate the pre-kill lead. Armed frames are held until clip_capture_go.
# Returns 0 when the consumer is armed, 1 on timeout (caller proceeds anyway — a
# late clip beats no clip).
wait_clip_capture_ready() {
  local timeout_ms="${CLIP_CAPTURE_READY_TIMEOUT_MS:-8000}"
  local marker="${CLIP_CAPTURE_READY_FILE:-}"
  if [ -z "$marker" ]; then
    return 0
  fi
  local waited=0
  while [ "$waited" -lt "$timeout_ms" ]; do
    if [ -f "$marker" ]; then
      log "  clip capture armed after ${waited}ms"
      return 0
    fi
    if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
      warn "clip capture died before its first frame"
      return 1
    fi
    sleep 0.05
    waited=$((waited + 50))
  done
  warn "clip capture never armed within ${timeout_ms}ms — starting playback anyway"
  return 1
}

# Open the start gate: the armed consumer records from its next frame. Called once
# the demo is confirmed MOVING, so the clip opens on motion instead of on the held
# paused frame. No-op on the ximagesrc path (no gate) — it just records throughout.
clip_capture_go() {
  local gate="${CLIP_CAPTURE_START_FILE:-}"
  [ -z "$gate" ] && return 0
  : >"$gate" 2>/dev/null || warn "could not open the capture start gate ($gate)"
  return 0
}

# SIGINT + gst -e = clean EOS so qtmux finalises moov. SIGTERM truncates.
stop_clip_capture() {
  local pid="${CLIP_CAPTURE_PID:-}"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  [ -n "${CLIP_CAPTURE_READY_FILE:-}" ] && rm -f "$CLIP_CAPTURE_READY_FILE"
  [ -n "${CLIP_CAPTURE_START_FILE:-}" ] && rm -f "$CLIP_CAPTURE_START_FILE"
  kill -INT "$pid" 2>/dev/null || true
  # 0.1s polls: gst usually flushes EOS in <100ms, and every extra poll
  # period is dead time between segments. Same 15s cap as before.
  for _ in $(seq 1 150); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "clip capture didn't exit â€” forcing"
    kill -9 "$pid" 2>/dev/null || true
  fi
  CLIP_CAPTURE_PID=""
}
