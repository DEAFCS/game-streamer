#!/usr/bin/env bash
# Live capture profiler. Run this DURING an active stream to decide, from
# data, whether the CPU-side framebuffer readback (ximagesrc) is actually a
# bottleneck — i.e. whether a zero-copy GPU capture path (NVFBC / DMABUF /
# gamescope) would buy you anything, or whether capture is already cheap and
# you should leave the architecture alone.
#
# Usage: src/dev/profile-capture.sh [duration_s] [interval_s]
#   defaults: 15s total, 1s samples.
#
# Each sample (over one interval) reports:
#   gst%cpu   — capture process CPU, as % of ONE core (ximagesrc readback +
#               any CPU convert + mux live here; NVENC is on a separate block)
#   cs2%cpu   — cs2 process CPU, as % of one core (so >100% across its threads)
#   GPU g/m%  — GPU core / memory utilisation
#   hot cores — any logical core pinned >=85% this interval
set -uo pipefail
SCRIPT_TAG=profile-capture

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"

DURATION="${1:-15}"
INTERVAL="${2:-1}"
[ "$INTERVAL" -lt 1 ] 2>/dev/null && INTERVAL=1
ITERS=$(( DURATION / INTERVAL )); [ "$ITERS" -lt 1 ] && ITERS=1

CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)
NCPU=$(nproc 2>/dev/null || echo 1)

# Prefer the present-hook consumer (composite / clip path embeds the gst
# pipeline in vkcapture-consumer), then the live ximagesrc capture, then any
# gst-launch. The consumer's process CPU == the capture pipeline CPU
# (compositor + convert + mux threads).
GST_PID=$(pgrep -f 'vkcapture-consumer' | head -1)
[ -z "$GST_PID" ] && GST_PID=$(pgrep -f 'gst-launch-1.0.*ximagesrc' | head -1)
[ -z "$GST_PID" ] && GST_PID=$(pgrep -f 'gst-launch-1.0' | head -1)
CS2_PID=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)

say "Targets"
if [ -n "$GST_PID" ]; then
  log "gst capture pid : $GST_PID"
  PIPE=$(tr '\0' ' ' < "/proc/$GST_PID/cmdline" 2>/dev/null)
  if echo "$PIPE" | grep -q cudaconvertscale; then
    log "  scaler in use : cudaconvertscale (GPU)"
  elif echo "$PIPE" | grep -q videoscale; then
    log "  scaler in use : videoscale/videoconvert (CPU)"
  fi
else
  warn "no capture process found (vkcapture-consumer / gst-launch) — is a stream running?"
fi
[ -n "$CS2_PID" ] && log "cs2 pid         : $CS2_PID" || warn "no cs2 process found"
log "host            : ${NCPU} logical cores, CLK_TCK=${CLK}"

# Sum of utime+stime (jiffies) for a pid; '' if gone. Robust to a comm that
# contains spaces/parens by slicing after the final ') '.
_pid_jiffies() {
  local line rest
  line=$(cat "/proc/$1/stat" 2>/dev/null) || { echo ""; return 1; }
  rest=${line##*) }
  # shellcheck disable=SC2086
  set -- $rest          # $12=utime $13=stime (fields after comm)
  echo $(( ${12:-0} + ${13:-0} ))
}

# Per-core "<name> <busy> <total>" jiffies from /proc/stat.
_cpu_snapshot() {
  awk '/^cpu[0-9]* /{ t=0; for(i=2;i<=NF;i++) t+=$i; idle=$5+$6; print $1, t-idle, t }' /proc/stat
}

_pcpu() {  # delta_jiffies -> % of one core over INTERVAL
  awk -v d="$1" -v t="$INTERVAL" -v k="$CLK" 'BEGIN{ if(d<0)d=0; printf "%.0f", 100.0*d/k/t }'
}

say "Sampling ${DURATION}s @ ${INTERVAL}s"
printf '%-5s %8s %8s %9s   %s\n' "t" "gst%cpu" "cs2%cpu" "GPU g/m%" "hot cores (>=85%)"
i=0
while [ "$i" -lt "$ITERS" ]; do
  i=$(( i + 1 ))
  g0=$([ -n "$GST_PID" ] && _pid_jiffies "$GST_PID")
  c0=$([ -n "$CS2_PID" ] && _pid_jiffies "$CS2_PID")
  a=$(_cpu_snapshot)
  gpu=$(nvidia-smi --query-gpu=utilization.gpu,utilization.memory \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  sleep "$INTERVAL"
  b=$(_cpu_snapshot)
  g1=$([ -n "$GST_PID" ] && _pid_jiffies "$GST_PID")
  c1=$([ -n "$CS2_PID" ] && _pid_jiffies "$CS2_PID")

  gcpu="-"; [ -n "$g0" ] && [ -n "$g1" ] && gcpu=$(_pcpu $(( g1 - g0 )))
  ccpu="-"; [ -n "$c0" ] && [ -n "$c1" ] && ccpu=$(_pcpu $(( c1 - c0 )))
  hot=$(join <(echo "$a" | sort) <(echo "$b" | sort) | awk '{
    db=$4-$2; dt=$5-$3; p=(dt>0)?100*db/dt:0;
    if ($1!="cpu" && p>=85) printf "%s(%d%%) ", $1, p }')

  printf '%-5s %7s%% %7s%% %9s   %s\n' "${i}s" "$gcpu" "$ccpu" "${gpu:--}" "${hot:-none}"
done

if [ -n "$GST_PID" ]; then
  say "gst threads (busiest; %cpu is lifetime avg — stable on a steady stream)"
  ps -L -o tid,pcpu,comm -p "$GST_PID" --sort=-pcpu 2>/dev/null | head -8
fi

say "GPU sm/mem/enc/dec %"
nvidia-smi dmon -s u -c 2 2>/dev/null \
  || nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv 2>/dev/null \
  || warn "nvidia-smi unavailable"

say "How to read this"
cat <<'EOF'
- gst%cpu near/over 100 (one core saturated) and rising with resolution
    => the ximagesrc readback is the bottleneck. A zero-copy GPU capture
       (gamescope-nested on this stack; NVFBC is GeForce-locked) removes it.
- a core stuck >=85% ('hot cores') while cs2 wants more CPU
    => contention; freeing capture cores would lift cs2's fps.
- gst%cpu modest (<60%) and no hot cores
    => capture is NOT your bottleneck. Zero-copy buys latency/headroom but
       little fps — not worth the rearchitect yet.
- GPU g% pinned ~100
    => you're GPU-bound; moving more work to the GPU could cost a little.
       Check enc% above — NVENC is a separate block from the render cores.
EOF
