#!/usr/bin/env python3
"""Measure what a viewer would get from av-sync-repro.py's output.

- A/V offset at each marker: beep PTS - flash PTS (positive = audio late).
- Holes in the audio: gaps between consecutive Opus packets (what the browser
  conceals, and hears as the volume dipping then coming back).
"""
import json
import subprocess
import sys

path = sys.argv[1]
# Pairing window, s: keep it under half of --mark-every or offsets alias.
WINDOW = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5


def probe(lavfi, entries):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-f", "lavfi", "-i", lavfi,
         "-show_entries", entries, "-of", "json"],
        capture_output=True, text=True, check=True).stdout
    return json.loads(out).get("frames", [])


def onsets(frames, key, threshold):
    """First frame of each run above threshold, as PTS seconds."""
    out, inside = [], False
    for f in frames:
        tags = f.get("tags", {})
        if key not in tags or "pts_time" not in f:
            continue
        v = float(tags[key]) if tags[key] not in ("-inf", "inf", "nan") else -999.0
        hot = v > threshold
        if hot and not inside:
            out.append(float(f["pts_time"]))
        inside = hot
    return out


vf = probe(f"movie={path},signalstats", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG")
flashes = onsets(vf, "lavfi.signalstats.YAVG", 150)
af = probe(f"amovie={path},astats=metadata=1:reset=1",
           "frame=pts_time:frame_tags=lavfi.astats.Overall.RMS_level")
beeps = onsets(af, "lavfi.astats.Overall.RMS_level", -30)

pairs = []
for fl in flashes:
    near = [b for b in beeps if abs(b - fl) < WINDOW]
    if near:
        b = min(near, key=lambda x: abs(x - fl))
        pairs.append((fl, round((b - fl) * 1000)))
    else:
        pairs.append((fl, None))

pk = json.loads(subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
     "packet=pts_time,duration_time", "-of", "json", path],
    capture_output=True, text=True, check=True).stdout)["packets"]
holes = []
for a, b in zip(pk, pk[1:]):
    end = float(a["pts_time"]) + float(a["duration_time"])
    gap = float(b["pts_time"]) - end
    if gap > 0.005:
        holes.append((round(float(a["pts_time"]), 2), round(gap * 1000)))

t0 = float(pk[0]["pts_time"]) if pk else 0.0
print("A/V offset at each marker (ms, + = audio late):")
print("  " + "  ".join(f"t={fl - t0:5.1f}s:{'missing' if o is None else f'{o:+d}'}" for fl, o in pairs))
print(f"audio holes: {len(holes)}, total {sum(h for _, h in holes)}ms")
for t, ms in holes[:20]:
    print(f"  at {t - t0:6.2f}s: {ms}ms of audio missing")
