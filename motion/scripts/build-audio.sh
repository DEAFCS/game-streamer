#!/usr/bin/env bash
# Generates motion/public/outro-audio.wav. Re-run after editing
# timing constants; Outro.tsx loads the resulting file via
# staticFile("outro-audio.wav").
#
# Design: a single tonal sub-bass thump at IMPACT_S over silence.
# No drone, no chime â€” just the logo-strike impact.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/.." && pwd)/public/outro-audio.wav"

# Keep these in sync with Outro.tsx timings.
# 3.0s composition; FLASH_S = 0.5.
TOTAL_S=3
IMPACT_S=0.5

impact_delay_ms=$(awk -v t="$IMPACT_S" 'BEGIN{printf "%d", t*1000}')

mkdir -p "$(dirname "$OUT")"

ffmpeg -y -hide_banner -loglevel warning \
  `# Silent bed for the full composition length.` \
  -f lavfi -t "$TOTAL_S" -i "anullsrc=r=48000:cl=stereo" \
  `# Impact: 55Hz sub-bass, short envelope.` \
  -f lavfi -t 0.5         -i "sine=f=55:r=48000:d=0.5" \
  -filter_complex "
    [1:a]afade=t=in:d=0.005,afade=t=out:st=0.05:d=0.45,volume=1.2,adelay=${impact_delay_ms}|${impact_delay_ms}[thump];

    [0:a][thump]amix=inputs=2:duration=first:normalize=0[mix_raw];
    [mix_raw]afade=t=out:st=2.55:d=0.45,alimiter=limit=0.6:attack=5:release=50,aresample=48000[out]
  " \
  -map "[out]" \
  -ar 48000 -ac 2 -c:a pcm_s16le \
  "$OUT"

echo "build-audio: wrote $OUT ($(du -h "$OUT" | awk '{print $1}'))"
