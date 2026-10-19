# shellcheck shell=bash
# GStreamer SRT capture. Tagged by stream-id so we can find/kill specific streams.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

stream_pid() {
  local stream_id="$1"
  pgrep -f "publish:${stream_id}\b" | head -1
}

stream_running() {
  [ -n "$(stream_pid "$1")" ]
}

# Round trip to MediaMTX in ms: the fastest of a few TCP connects to its API,
# which runs on the same node as its SRT listener. Prints nothing if MediaMTX
# can't be reached.
mediamtx_rtt_ms() {
  local i timing samples=""
  for i in 1 2 3; do
    timing=$(curl -o /dev/null -s --max-time 2 \
      -w '%{time_namelookup} %{time_connect}' \
      "$MEDIAMTX_API_BASE/v3/paths/list") || break
    samples+="$timing"$'\n'
  done
  # time_connect includes the DNS lookup; the round trip is the handshake.
  printf '%s' "$samples" | awk '
    NF == 2 { ms = ($2 - $1) * 1000; if (best == "" || ms < best) best = ms }
    END { if (best != "") printf "%.1f\n", best }'
}

# SRT latency in ms for a round trip to MediaMTX. SRT holds every packet for
# this long so lost ones can be resent in time, which takes a few round trips:
# 4x the round trip, never under 120ms, the floor MediaMTX's SRT listener
# enforces anyway (it takes the larger of its own 120 and ours). 200ms when the
# round trip is unknown, which held up everywhere before it was measured.
srt_latency_for_rtt() {
  if [ -z "$1" ]; then
    echo 200
    return
  fi
  awk -v rtt="$1" 'BEGIN { ms = int(rtt * 4 + 0.999); print (ms < 120 ? 120 : ms) }'
}

# start_capture <stream-id> [fps] [video-kbps] [show-pointer] [audio]
#   audio: 1 to include PulseAudio leg (default), 0 video-only
start_capture() {
  local stream_id="${1:?stream-id required}"
  local fps="${2:-30}"
  local kbps="${3:-4000}"
  local pointer="${4:-true}"
  local audio="${5:-${CAPTURE_AUDIO:-1}}"
  # One keyframe a second. A viewer can only start decoding at a keyframe, and
  # MediaMTX can't ask an SRT publisher for one, so joining the stream and
  # recovering from packet loss both wait for the next one.
  local gop="$fps"
  local url="${MEDIAMTX_SRT_BASE}?streamid=publish:${stream_id}"
  local pulse_sink="${PULSE_SINK_NAME:-cs2}"
  local gst_tag="gst-${stream_id:0:8}"

  # Output dims: scale capture to LIVE_OUTPUT_DIMS (default 1920x1080).
  # CS2 may render at 1440p natively, but the live HLS stream + HUD
  # overlay CSS + viewer expectations all key off 1080p — and scaling
  # 1440p → 1080p at capture time gives a supersampled 1080p that's
  # crisper than rendering CS2 natively at 1080p.
  local live_out="${LIVE_OUTPUT_DIMS:-1920x1080}"
  local out_w="${live_out%x*}"
  local out_h="${live_out#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

  if stream_running "$stream_id"; then
    return 0
  fi

  log "starting capture '${stream_id}' (${out_w}x${out_h}@${fps}fps kbps=$kbps audio=$audio) -> $url"

  # Sized from this node's round trip to MediaMTX, so a far node gets the
  # headroom it needs and a near one adds no delay. SRT_LATENCY_MS overrides it.
  local srt_latency="${SRT_LATENCY_MS:-}"
  if [ -n "$srt_latency" ]; then
    log "  SRT latency ${srt_latency}ms (SRT_LATENCY_MS)"
  else
    local rtt
    rtt=$(mediamtx_rtt_ms)
    srt_latency=$(srt_latency_for_rtt "$rtt")
    log "  SRT latency ${srt_latency}ms (round trip to MediaMTX: ${rtt:-unreachable}${rtt:+ms})"
  fi

  # LIVE_VIDEO_CODEC=h265|h264. Default h264 — falls back to h264 if no NVENC HEVC.
  # Note: HEVC-over-WebRTC is Safari 17+ only; non-HEVC browsers fall back to HLS.
  local codec="${LIVE_VIDEO_CODEC:-h264}"
  local enc="" parse=""
  case "$codec" in
    h265|hevc)
      if enc=$(pick_h265_pipeline "$gop" "$kbps" live); then
        parse="h265parse config-interval=1"
      else
        warn "LIVE_VIDEO_CODEC=$codec but no NVENC HEVC encoder available — falling back to h264"
        codec="h264"
      fi
      ;;
    h264) : ;;
    *)
      warn "LIVE_VIDEO_CODEC=$codec unrecognized — using h264"
      codec="h264"
      ;;
  esac
  if [ "$codec" = "h264" ]; then
    enc=$(pick_h264_pipeline "$gop" "$kbps" live) \
      || { warn "no H.264 encoder resolved — not starting capture"; return 1; }
    parse="h264parse config-interval=1"
  fi
  log "  codec: $codec"

  # Scale + colorspace convert. Runs on the GPU (cudaconvertscale) when the
  # encoder is CUDA-based, off-loading it from the CPU that cs2 needs.
  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")
  _assert_cuda_chain "$convert" "$enc"

  # Persist args so restart_capture can re-invoke us identically.
  local args_dir="${LOG_DIR:-/tmp/game-streamer}"
  mkdir -p "$args_dir"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$stream_id" "$fps" "$kbps" "$pointer" "$audio" \
    > "${args_dir}/capture-${stream_id}.args"

  # Resolve the audio source up front (both capture paths use it). Pin to our
  # named null sink's .monitor — pactl's default can drift to hud-manager's Pulse
  # client / silence.
  local pulse_source=""
  if [ "$audio" = 1 ]; then
    pulse_source="${pulse_sink}.monitor"
    if ! pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$pulse_source"; then
      warn "  ${pulse_source} not present — falling back to default source"
      if command -v get_default_source >/dev/null 2>&1; then
        pulse_source=$(get_default_source)
      else
        pulse_source=$(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')
      fi
      [ -n "$pulse_source" ] || pulse_source="${pulse_sink}.monitor"
    fi
  fi

  # COMPOSITE (cs2 present-hook + HUD overlay): capture cs2's swapchain via the
  # vkcapture consumer (no X-server contention) and overlay the JTs HUD in gst.
  # Used for live + demo when vkcapture + cs2 + the HUD window are present; any
  # miss falls back to the plain ximagesrc grab below (HUD via picom).
  # HUD grab rate: match the OUTPUT fps so HUD elements (health/timer/money) update
  # as smoothly as the game — grabbing at 30 over a 60fps composite made the HUD
  # visibly choppy. cs2 renders via the present-hook (not X), so this ximagesrc is
  # the only X-server capture load; LIVE-DIAG showed capture at ~1.2/2 cores, plenty
  # of headroom for 60. Override with HUD_CAPTURE_FPS.
  local hud_xid="" used_composite=0 hud_fps="${HUD_CAPTURE_FPS:-$fps}"
  # HUD show/hide control file (composite only): the consumer polls it to alpha
  # the HUD pad; its presence tells the spec-server we're compositing. Clear any
  # stale copy so a non-composite path doesn't look composite.
  local hud_ctl="${LOG_DIR:-/tmp/game-streamer}/hud-visible"
  rm -f "$hud_ctl"
  # The HUD window can be briefly missing at stream start (run-demo reloads the
  # overlay right before this), and one miss silently left a whole replay stream on
  # the ximagesrc grab — no pacing, no present-hook. Wait for it (HUD_COMPOSITE_WAIT_S,
  # 10s) and say why when the composite isn't used.
  local why=""
  if ! vkcapture_available; then
    why="vkcapture unavailable"
  elif ! pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1; then
    why="cs2 not running"
  elif ! command -v find_hud_overlay_window >/dev/null 2>&1; then
    why="no HUD support loaded"
  elif declare -F hud_running >/dev/null 2>&1 && ! hud_running; then
    # Only wait for a window that can appear: with the HUD off or dead, waiting made
    # every restart_capture (SRT-drop recovery) 10s longer.
    why="HUD not running"
  else
    local waited=0 wait_max="${HUD_COMPOSITE_WAIT_S:-10}"
    wait_max="${wait_max//[!0-9]/}"; wait_max="${wait_max:-10}"
    while :; do
      hud_xid=$(find_hud_overlay_window 2>/dev/null || true)
      [ -n "$hud_xid" ] && break
      [ "$waited" -ge "$wait_max" ] && { why="HUD overlay window not found after ${waited}s"; break; }
      sleep 1; waited=$((waited + 1))
    done
    [ -n "$hud_xid" ] && [ "$waited" -gt 0 ] && log "  composite: HUD overlay window appeared after ${waited}s"
  fi
  [ -n "$why" ] && log "  composite unavailable ($why) — ximagesrc grab, no pacing"
  if [ -n "$hud_xid" ]; then
    log "  composite: cs2 present-hook + HUD overlay (xid=$hud_xid, hud=${hud_fps}fps)"
    # sink_0 = cs2 (base), sink_1 = HUD on top. The HUD ximagesrc MUST carry alpha
    # (BGRA) or it paints opaque over cs2 — verify this on-node first. The software
    # compositor stays: LIVE-DIAG measured the capture at ~1.1 of its 2 cores, so the
    # blend is NOT CPU-bound and GPU compositing would buy nothing here.
    local cs2_src="appsrc name=vksrc ! queue ! videorate ! video/x-raw,framerate=$fps/1 ! comp.sink_0"
    # leaky=downstream: a slow/blocked HUD grab drops its own frames instead of
    # back-pressuring the compositor (which would stall the cs2 leg too).
    local hud_src="ximagesrc xid=$hud_xid use-damage=0 show-pointer=false ! video/x-raw,framerate=$hud_fps/1 ! videoconvert ! video/x-raw,format=BGRA ! queue leaky=downstream max-size-buffers=2 ! comp.sink_1"
    # queue after the compositor = a thread boundary so the software blend and the
    # upload/encode run on separate cores (else they serialize on one). Bounded by
    # buffer count — raw frames are big, so the default byte cap would throttle.
    local outchain="compositor name=comp background=black ! queue max-size-buffers=8 max-size-bytes=0 max-size-time=0 ! $convert ! $enc ! $parse"
    local pipeline
    # Audio queue leaks like the video leg so it can't fall permanently behind.
    if [ "$audio" = 1 ]; then
      pipeline="$outchain ! queue ! mux. \
$cs2_src \
$hud_src \
pulsesrc device=$pulse_source buffer-time=400000 provide-clock=false ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! audioresample ! opusenc bitrate=128000 ! opusparse ! queue leaky=downstream max-size-time=500000000 max-size-buffers=0 max-size-bytes=0 ! mux. \
mpegtsmux name=mux alignment=7 ! srtsink uri=$url latency=$srt_latency auto-reconnect=false"
    else
      pipeline="$outchain ! mpegtsmux alignment=7 ! srtsink uri=$url latency=$srt_latency auto-reconnect=false \
$cs2_src \
$hud_src"
    fi
    export VKCAP_FPS="$fps"
    # With LIVE-DIAG on, also have the consumer log presents/s — present-locked,
    # so presents/s == cs2's REAL render fps feeding the stream. This is the signal
    # LIVE-DIAG lacked: presents/s consistently ≥ fps ⇒ the stream is true CFR and
    # any "not 60" feel is the camera switching or viewer-side; presents/s dipping
    # below fps ⇒ cs2 isn't holding the rate under live load (videorate then dups).
    [ "${GS_LIVE_DIAG:-1}" = "1" ] && export VKCAP_DEBUG="${VKCAP_DEBUG:-1}"
    # Zero-copy is clip-only: the software `compositor` here blends in system
    # memory and can't consume a device-local dmabuf. Force it off so a global
    # VKCAP_ZEROCOPY=1 can't push this path into the ximagesrc fallback.
    export VKCAP_ZEROCOPY=0
    # Seed visible=1; consumer reads VKCAP_HUD_CTL and polls it for show/hide.
    printf '1\n' > "$hud_ctl"
    export VKCAP_HUD_CTL="$hud_ctl"
    # Pin the capture pipeline to dedicated high cores so its gst threads don't
    # pile (wake-affinity) onto a core cs2 is using and peg it. cs2 is pinned to
    # the complementary cores at launch (cs2_cpu_pin), so the split is real — they
    # never share a core. CAPTURE_CPUS overrides the list (empty = no pin);
    # CAPTURE_CORES sets the count (2 is the floor — capture needs ~1.7 cores).
    local capture_pin=()
    compute_cpu_split
    if [ -n "${GS_CAPTURE_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
      capture_pin=(taskset -c "$GS_CAPTURE_CPUS")
      log "  capture pinned to cores $GS_CAPTURE_CPUS (cs2 confined to ${GS_CS2_CPUS:-all})"
    fi
    # Grid pacing, as for clips (LIVE_PACE, on by default; 0 = off). cs2 renders at
    # fps_max 2x$fps and overshoots its own limiter, so stamping arrivals by wall clock
    # and thinning with videorate stepped 2-3 presents at a time (uneven motion). The
    # layer now paces presents onto an exact $fps grid, a late frame skips the slots it
    # missed, and each frame is stamped by slot count (re-anchored to the clock if the
    # render ever lags) — so videorate passes every frame through.
    # The frame handoff (LIVE_FRAME_HANDOFF=1) is off by default here: on a replay
    # stream it skipped 5-20 frames a second during rounds, likely cs2 waiting on reads
    # slowed by the HUD grab and compositor sharing the 2 capture cores.
    if [ "${LIVE_PACE:-1}" = "1" ]; then
      export VKCAP_FRAME_PTS=1 VKCAP_PACE_FPS="$fps" VKCAP_PACE_SKIP=1
    else
      unset VKCAP_FRAME_PTS VKCAP_PACE_FPS VKCAP_PACE_SKIP
    fi
    export VKCAP_FRAME_ACK="${LIVE_FRAME_HANDOFF:-0}"
    spawn_logged "$gst_tag" "${capture_pin[@]}" vkcapture-consumer "$pipeline"
    sleep 1
    if kill -0 "$SPAWNED_PID" 2>/dev/null; then
      used_composite=1
    else
      warn "composite consumer died on spawn — falling back to ximagesrc"
      rm -f "$hud_ctl"
      unset VKCAP_HUD_CTL
    fi
  fi

  # ximagesrc fallback — grabs the composited X display (cs2 + HUD via picom). Used
  # when the composite is unavailable (no vkcapture / no cs2 / no HUD window, e.g.
  # the DEBUG_STREAM boot watch) or its consumer died. leaky=downstream decouples
  # the grab from convert+NVENC so a downstream hitch can't back-pressure the grab.
  if [ "$used_composite" = 0 ]; then
    if [ "$audio" = 1 ]; then
      # Opus: mediamtx forwards straight to WebRTC without per-viewer transcode.
      spawn_logged "$gst_tag" gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
          ! video/x-raw,framerate="$fps"/1 \
          ! queue leaky=downstream max-size-buffers=3 max-size-bytes=0 max-size-time=0 \
          ! $convert \
          ! $enc \
          ! $parse \
          ! queue ! mux. \
        pulsesrc device="$pulse_source" buffer-time=400000 provide-clock=false \
          ! audio/x-raw,rate=48000,channels=2 \
          ! audioconvert \
          ! audioresample \
          ! opusenc bitrate=128000 \
          ! opusparse \
          ! queue leaky=downstream max-size-time=500000000 max-size-buffers=0 max-size-bytes=0 ! mux. \
        mpegtsmux name=mux alignment=7 \
          ! srtsink uri="$url" latency="$srt_latency" auto-reconnect=false
    else
      spawn_logged "$gst_tag" gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
          ! video/x-raw,framerate="$fps"/1 \
          ! queue leaky=downstream max-size-buffers=3 max-size-bytes=0 max-size-time=0 \
          ! $convert \
          ! $enc \
          ! $parse \
          ! mpegtsmux alignment=7 \
          ! srtsink uri="$url" latency="$srt_latency" auto-reconnect=false
    fi
  fi

  # Liveness check — must survive pulse / NVENC init / srt handshake.
  local pid=$SPAWNED_PID
  local i
  for i in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s"
      return 1
    fi
    sleep 1
  done

  # Live perf sampler: every GS_LIVE_DIAG_INTERVAL s (default 15) while the stream
  # runs, log GPU util/clock + cs2 CPU% + the CAPTURE pipeline's CPU%. This is the
  # one signal we lacked for live: if capcpu pegs ~its pin (200% on 2 cores) the
  # capture is CPU-bound — almost always the SOFTWARE compositor (composite path) —
  # and GPU compositing is the fix; if cs2cpu/gpu dip with capcpu low it's cs2-side.
  # Slow cadence so a multi-hour stream doesn't spam; GS_LIVE_DIAG=0 mutes. Detaches
  # and self-exits when the capture pid dies.
  if [ "${GS_LIVE_DIAG:-1}" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
    (
      cap_pid="$pid" comp="$used_composite"
      cs2_pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
      hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
      jif() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null; }
      # AUDIO-DIAG: pulse-side per-stream latency (ms) — where seconds of audio lag
      # can hide BEFORE the gst caps (skew slaving re-stamps late samples as live, so
      # PTS never shows it). srcout = readers of the cs2 monitor (our capture);
      # sinkin = cs2's write stream into the sink. Comma list = one value per stream;
      # steady growth across samples = the backlog, and names the side it's on.
      mon="${PULSE_SINK_NAME:-cs2}.monitor"
      pa_lat() { # pa_lat <sink-inputs|source-outputs> <Sink:|Source:> <owner-idx>
        pactl list "$1" 2>/dev/null | awk -v f="$2" -v idx="$3" '
          function flush(){ if (cur==idx && lat>0) out=out (out?",":"") int(lat/1000) }
          /^(Sink Input|Source Output) #/ { flush(); cur=""; lat=0 }
          $1==f { cur=$2 }
          /Latency:/ { for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { lat+=$i; break } }
          END { flush(); print (out ? out : "?") }'
      }
      audio_lat() {
        local midx sidx
        midx=$(pactl list short sources 2>/dev/null | awk -v s="$mon" '$2==s{print $1; exit}')
        sidx=$(pactl list short sinks 2>/dev/null | awk -v s="${PULSE_SINK_NAME:-cs2}" '$2==s{print $1; exit}')
        printf 'srcout=%sms sinkin=%sms' \
          "$([ -n "$midx" ] && pa_lat source-outputs "Source:" "$midx" || echo '?')" \
          "$([ -n "$sidx" ] && pa_lat sink-inputs "Sink:" "$sidx" || echo '?')"
      }
      interval="${GS_LIVE_DIAG_INTERVAL:-15}"
      pcs2=$(jif "$cs2_pid"); pcap=$(jif "$cap_pid"); pms=$(date +%s%3N 2>/dev/null || echo 0)
      while kill -0 "$cap_pid" 2>/dev/null; do
        sleep "$interval"
        kill -0 "$cap_pid" 2>/dev/null || break
        now_ms=$(date +%s%3N 2>/dev/null || echo 0); dt=$(( now_ms - pms )); [ "$dt" -le 0 ] && dt=$((interval * 1000))
        g=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,clocks.gr,temperature.gpu \
              --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        ccs2=$(jif "$cs2_pid"); ccap=$(jif "$cap_pid")
        cs2cpu=$(awk -v a="${pcs2:-}" -v b="${ccs2:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100}')
        capcpu=$(awk -v a="${pcap:-}" -v b="${ccap:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100}')
        adiag=""
        [ "$audio" = 1 ] && adiag=" | audio $(audio_lat)"
        log "  LIVE-DIAG ${stream_id:0:8}: gpu(util,vramMiB,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% capcpu=${capcpu}% (composite=${comp})${adiag}"
        # One-shot raw dump so the parser can be validated against this pactl's
        # output format straight from the log if the numbers look off.
        if [ "$audio" = 1 ] && [ -z "${raw_dumped:-}" ]; then
          raw_dumped=1
          { pactl list source-outputs; pactl list sink-inputs; } 2>/dev/null \
            | grep -E 'Source Output #|Sink Input #|Sink:|Source:|Latency|application\.name' \
            | while IFS= read -r l; do log "    AUDIO-DIAG-RAW $l"; done
        fi
        pcs2=$ccs2; pcap=$ccap; pms=$now_ms
      done
    ) &
  fi

  # Log the watchable HLS URL (grep "WATCH") for the early/boot phase.
  local dom="${GAME_STREAM_DOMAIN:-hls.5stack.gg}"
  dom="${dom%/}"
  case "$dom" in
    http://*|https://*) ;;
    *) dom="https://$dom" ;;
  esac
  log "WATCH (HLS): ${dom}/${stream_id}/index.m3u8"

  return 0
}

restart_capture() {
  local stream_id="${1:?stream-id required}"
  local args_file="${LOG_DIR:-/tmp/game-streamer}/capture-${stream_id}.args"
  if [ ! -f "$args_file" ]; then
    warn "restart_capture: no saved args for '${stream_id}'"
    return 1
  fi
  local sid fps kbps pointer audio
  { read -r sid; read -r fps; read -r kbps; read -r pointer; read -r audio; } < "$args_file"

  stop_capture "$stream_id"
  # Let mediamtx clear the stale publisher before reconnecting.
  sleep 1
  start_capture "$sid" "$fps" "$kbps" "$pointer" "$audio"
}

stop_capture() {
  local stream_id="${1:?stream-id required}"
  local pid
  pid=$(stream_pid "$stream_id") || true
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
}
