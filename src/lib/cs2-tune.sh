# shellcheck shell=bash
# Boot-time hardware auto-tune. The fleet spans GTX 980-class (Maxwell) to
# RTX 50-series and a wide range of CPUs, so a single hardcoded config is
# either too heavy for the weak nodes or leaves the strong ones idle. This
# detects the GPU class + CPU core count and sets the capture/cs2 perf knobs
# per node so each card runs at its sweet spot.
#
# Every value is set with `:=` (or an explicit-unset guard), so an env /
# pod-spec override ALWAYS wins — auto-tune only fills in what wasn't pinned.
#
# Sets when unset: CS2_THREADS, GS_GPU_SCALE. Emits advisories for the
# knobs it deliberately won't change silently (FPS halving, codec — which is
# playback-gated, not encode-gated). Sourced by run-live.sh / run-demo.sh;
# depends on log/warn from common.sh.

# Primary GPU product name, trimmed; "" when nvidia-smi is unavailable.
detect_gpu_name() {
  nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
    | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Coarse GPU tier: low|mid|high. Drives the GPU-offload + framerate calls.
# Heuristic on the series number (RTX 30/40/50 -> high; 20/16/10 -> mid;
# GTX 9xx and older -> low). Unknown names default to "mid" — GPU scale on,
# 60fps — which is safe for anything modern enough to not be matched.
classify_gpu_tier() {
  local name="$1" n
  case "$name" in
    *Tesla*|*Quadro*|*A100*|*H100*|*L4*|*L40*|*A40*|*A10*) echo high; return ;;
  esac
  n=$(printf '%s' "$name" | grep -oE '[0-9]{3,4}' | head -1)
  [ -z "$n" ] && { echo mid; return; }
  case "$n" in
    [3-9][0-9][0-9][0-9]) echo high ;;   # 3000-9999 -> RTX 30/40/50+
    2[0-9][0-9][0-9])     echo mid  ;;   # 2000      -> Turing RTX
    1[0-9][0-9][0-9])     echo mid  ;;   # 1000/1600 -> Pascal / Turing GTX
    9[0-9][0-9])          echo low  ;;   # 900       -> Maxwell
    [1-8][0-9][0-9])      echo low  ;;   # 100-800   -> older
    *)                    echo mid  ;;
  esac
}

# Pin the GPU to a fixed high graphics clock so it doesn't downclock during
# low-utilisation moments and then lag/oscillate ramping back up when the action
# spikes load — that P-state oscillation shows up as intermittent frame-time
# stutter even while the GPU sits well under 100% (we measured ~49%). This is
# the headless equivalent of nvidia-settings PowerMizer "Prefer Maximum
# Performance". Best-effort: needs GPU admin rights (we have them — root +
# NVIDIA_DRIVER_CAPABILITIES=all); on a restricted/shared node nvidia-smi
# refuses and we just continue unpinned. Gated by GS_GPU_LOCK_CLOCKS (default
# 1); GS_GPU_LOCK_MHZ overrides the target (defaults to the card's max).
# The lock persists for the GPU's lifetime — fine on a dedicated streamer node.
lock_gpu_clocks() {
  case "${GS_GPU_LOCK_CLOCKS:-1}" in 0|off|false|no) return 0 ;; esac
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local clk="${GS_GPU_LOCK_MHZ:-}"
  [ -z "$clk" ] && clk=$(nvidia-smi --query-gpu=clocks.max.gr \
    --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  case "$clk" in ''|*[!0-9]*) warn "gpu clock lock: no usable max clock — skipping"; return 0 ;; esac
  nvidia-smi -pm 1 >/dev/null 2>&1 || true
  if nvidia-smi -lgc "${clk},${clk}" >/dev/null 2>&1; then
    log "gpu clock lock: pinned graphics clock to ${clk}MHz (prevents downclock / P-state oscillation stutter)"
  else
    warn "gpu clock lock: nvidia-smi -lgc refused (restricted/shared node?) — continuing unpinned"
  fi
}

# Detect hardware and fill in GS_GPU_SCALE for this node (+ pin GPU clocks).
# cs2's thread count is left to the engine (auto-detect) — we never pass -threads.
# Safe to call once per flow after FPS is resolved.
cs2_autotune() {
  local gpu tier cores
  gpu="$(detect_gpu_name)"
  cores="$(nproc 2>/dev/null || echo 4)"

  if [ -n "$gpu" ]; then
    tier="$(classify_gpu_tier "$gpu")"
  else
    tier="mid"
    warn "autotune: nvidia-smi unavailable — assuming '$tier' tier"
  fi

  # GPU scale+convert offload. Modern GPUs have headroom to do the capture
  # scale (e.g. 1440p->1080p) + RGB->NV12 convert; on weak (Maxwell-class)
  # cards cs2 itself is the thing fighting for the GPU, so keep that work on
  # the CPU there (which has the spare cycles). pick_scale_convert reads
  # GS_GPU_SCALE. This also serves cs2 perf: on modern nodes it frees CPU
  # cores for cs2.
  case "$tier" in
    low) : "${GS_GPU_SCALE:=0}" ;;
    *)   : "${GS_GPU_SCALE:=auto}" ;;
  esac

  # cs2 worker threads: left to the engine — we never pass -threads. Auto-detect
  # is Valve's recommendation; a high explicit -threads is a known stutter source,
  # and these dedicated nodes give cs2 the whole box anyway. (Escape hatch: the
  # flows still honor an explicit CS2_THREADS=N to force -threads N on a bad node.)
  export GS_GPU_SCALE
  log "autotune: gpu='${gpu:-unknown}' tier=$tier cores=$cores GS_GPU_SCALE=$GS_GPU_SCALE (threads=engine auto-detect)"

  # Advisory only — too visible / playback-constrained to change silently.
  if [ "$tier" = low ]; then
    log "autotune: '$tier' tier — if it can't hold ${FPS:-60}fps, prefer FPS=30 (smooth 30 beats stuttery 60) and/or a lower CS2_DISPLAY_RES."
  fi

  # Pin clocks so the GPU doesn't downclock-then-stutter under bursty load.
  lock_gpu_clocks
}
