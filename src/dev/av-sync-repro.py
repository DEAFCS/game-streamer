#!/usr/bin/env python3
"""Reproduce the live stream's A/V behaviour without cs2/NVENC.

Mirrors the live composite pipeline (src/lib/stream.sh) with the pieces that
matter for A/V sync:
  video: appsrc stamped like vkcapture-consumer's fixed_ts path (frame-count PTS
         and its re-anchoring, --mode), fed by a loop that paces like the layer's
         present-eventfd.patch grid (skip mode; the grid restarts after a capture
         reset, so a gap advances 1 slot; an overrun pacing sleep pokes 1 slot and
         the next present carries the rest).
  audio: clock-stamped PCM -> opusenc ! opusparse !
         queue leaky=downstream max-size-time=500ms ! mpegtsmux (as in stream.sh).
Swaps: x264enc for NVENC, appsrc PCM for pulsesrc; filesink, or srtsink (--srt)
to run it through MediaMTX into a browser.

Every --mark-every seconds of wall clock the video frame goes white and the audio
beeps at the same instant, so the output carries its own A/V offset.

  apt install gstreamer1.0-plugins-{base,good,bad,ugly} python3-gst-1.0 ffmpeg
  python3 av-sync-repro.py --mode current --out current.ts --mark-every 12 \
    --gaps 10:180,40:300 --hitch-start 6 --spike-every 2 &
  sleep 20; kill -STOP $!; sleep 6; kill -CONT $!   # a 6s capture stall
  wait; python3 av-sync-analyze.py current.ts 6
"""
import argparse
import json
import math
import struct
import threading
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

Gst.init(None)

ap = argparse.ArgumentParser()
ap.add_argument("--seconds", type=float, default=60.0)
ap.add_argument("--out", default="out.ts")
ap.add_argument("--events", default="events.json")
ap.add_argument("--srt", default="", help="also publish to this SRT URL (MediaMTX)")
ap.add_argument("--mark-every", type=float, default=4.0)
# Video-only pause (cs2 not presenting): no frames; the grid keeps counting slots.
ap.add_argument("--vpause", default="", help="at:sec,...")
# Audio-only pause: no audio pushed. keep = PTS carry on from the sample count
# (the capture lost that time); skip = PTS jump over the pause (clock-correct).
ap.add_argument("--apause", default="", help="at:sec,...")
ap.add_argument("--apause-pts", choices=["keep", "skip"], default="skip")
# Capture resets (swapchain rebuild on a demo seek, map change, ...): wall time, ms.
ap.add_argument("--gaps", default="10:180,22:150")
# Video-leg stalls (compositor / encoder hiccup): first, every, ms.
ap.add_argument("--hitch-start", type=float, default=6.0)
ap.add_argument("--hitch-every", type=float, default=8.0)
ap.add_argument("--hitch-ms", type=float, default=300.0)
# One late consumer read (CPU contention): every N s, one frame read this late.
ap.add_argument("--spike-every", type=float, default=0.0)
ap.add_argument("--spike-ms", type=float, default=60.0)
# current = before the fix; naive = re-anchor on any one frame's lag (ratchets the
# other way on late reads); fix = vkcapture-consumer.c's windowed floor.
ap.add_argument("--mode", choices=["current", "naive", "fix"], default="fix")
args = ap.parse_args()
MODE = args.mode
WINDOW = 30                                      # FRAME_PTS_GRID_WINDOW_FRAMES

FPS = 60
W, H = 320, 180
RATE = 48000
CHUNK_MS = 10
MARK_EVERY = args.mark_every
MARK_FIRST = 2.0
FRAME_PTS_MAX_LAG = 250 * Gst.MSECOND           # vkcapture-consumer.c
FIX_TOLERANCE = 2 * Gst.SECOND // FPS           # FRAME_PTS_GRID_MAX_LAG_FRAMES

def plan(spec):
    return [[float(a), float(b), False] for a, b in (x.split(":") for x in filter(None, spec.split(",")))]


vpauses = plan(args.vpause)
apauses = plan(args.apause)
gaps = []
for g in filter(None, args.gaps.split(",")):
    t, ms = g.split(":")
    gaps.append([float(t), float(ms) / 1000.0, False])

sink = (f"tee name=t ! queue ! srtsink uri=\"{args.srt}\" latency=200 auto-reconnect=false "
        f"t. ! queue ! filesink location={args.out}" if args.srt
        else f"filesink location={args.out}")
desc = f"""
appsrc name=vsrc is-live=true format=time do-timestamp=false
  caps=video/x-raw,format=I420,width={W},height={H},framerate={FPS}/1
  ! queue ! videorate ! video/x-raw,framerate={FPS}/1
  ! queue max-size-buffers=8 max-size-bytes=0 max-size-time=0
  ! identity name=hitch
  ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max={FPS} bitrate=2000
  ! h264parse config-interval=1 ! queue ! mux.
appsrc name=asrc is-live=true format=time do-timestamp=false
  caps=audio/x-raw,format=S16LE,rate={RATE},channels=2,layout=interleaved
  ! audioconvert ! audioresample ! opusenc bitrate=128000 ! opusparse
  ! queue name=aq leaky=downstream max-size-time=500000000 max-size-buffers=0 max-size-bytes=0 ! mux.
mpegtsmux name=mux alignment=7 ! {sink}
"""
pipe = Gst.parse_launch(desc)
vsrc = pipe.get_by_name("vsrc")
asrc = pipe.get_by_name("asrc")
aq = pipe.get_by_name("aq")

events = {"vmarks": [], "amarks": [], "overruns": [], "aq_level": [], "lag": [], "reanchors": [], "gaps": [], "hitches": []}
stop = threading.Event()
t0_mono = None


def wall():
    return time.monotonic() - t0_mono


def running_time():
    return clock.get_time() - pipe.get_base_time()


aq.connect("overrun", lambda q: events["overruns"].append(round(wall(), 3)))

# Video-leg stall: block the streaming thread like a compositor/NVENC hiccup.
next_hitch = [args.hitch_start]


def on_hitch(pad, info):
    if wall() >= next_hitch[0]:
        events["hitches"].append(round(wall(), 3))
        next_hitch[0] += args.hitch_every
        time.sleep(args.hitch_ms / 1000.0)
    return Gst.PadProbeReturn.OK


pipe.get_by_name("hitch").get_static_pad("sink").add_probe(Gst.PadProbeType.BUFFER, on_hitch)

dark = bytes([40]) * (W * H) + bytes([128]) * (W * H // 2)
white = bytes([235]) * (W * H) + bytes([128]) * (W * H // 2)


def video_loop():
    """The layer's grid pacing + the consumer's frame-count PTS."""
    interval = 1_000_000_000 // FPS          # integer, as in the patch
    pace_next = 0
    pts_base = 0
    pts_frames = 0
    reanchors = 0
    next_mark = MARK_FIRST
    last_lag_log = -1.0
    next_spike = [args.spike_every or 0.0]
    win = [0, 0, 0]
    while not stop.is_set():
        # Capture reset: no presents for the gap, then the grid restarts (pace_next=0).
        for g in gaps:
            if not g[2] and wall() >= g[0]:
                g[2] = True
                events["gaps"].append(round(wall(), 3))
                time.sleep(g[1])
                pace_next = 0
        now = time.monotonic_ns()
        slots = 1
        if pace_next != 0 and now >= pace_next:
            missed = (now - pace_next) // interval
            slots = 1 + missed
            pace_next += (missed + 1) * interval
        elif pace_next == 0:
            pace_next = now + interval
        else:
            time.sleep((pace_next - now) / 1e9)
            pace_next += interval

        if any(p[0] <= wall() < p[0] + p[1] for p in vpauses):
            continue

        is_mark = wall() >= next_mark
        if is_mark:
            next_mark += MARK_EVERY

        # A late consumer read: the frame's content is from its slot, rt is read late.
        if args.spike_every and wall() >= next_spike[0]:
            next_spike[0] += args.spike_every
            time.sleep(args.spike_ms / 1000.0)

        # vkcapture-consumer.c push_one_frame(), fixed_ts branch.
        rt = running_time()
        if pts_frames == 0:
            pts_base = rt
        pts_frames += slots
        pts = pts_base + (pts_frames - 1) * Gst.SECOND // FPS
        if MODE != "fix" and rt > pts + FRAME_PTS_MAX_LAG:
            shift = rt - FRAME_PTS_MAX_LAG - pts
            pts_base += shift
            pts += shift
            reanchors += 1
            events["reanchors"].append(round(wall(), 3))
        if MODE == "naive" and rt > pts + FIX_TOLERANCE:
            shift = rt - pts
            pts_base += shift
            pts += shift
            events["reanchors"].append(round(wall(), 3))
        if MODE == "fix":
            # The patch (grid pacing): no immediate re-anchor; the floor of the lag
            # over a 30-frame window, both ways. Lag jumps forward; a lead is slewed
            # out a tenth of a frame per frame so PTS never go backwards.
            lag = rt - pts
            if win[1] == 0 or lag < win[0]:
                win[0] = lag
            win[1] += 1
            if win[1] >= WINDOW:
                if win[0] > FIX_TOLERANCE:
                    pts_base += win[0]
                    pts += win[0]
                    events["reanchors"].append(round(wall(), 3))
                elif win[0] < -FIX_TOLERANCE:
                    win[2] = win[0]
                    events["reanchors"].append(round(wall(), 3))
                win[1] = 0
            if win[2] < 0:
                step = max(win[2], -(Gst.SECOND // FPS) // 10)
                pts_base += step
                pts += step
                win[2] -= step

        if wall() - last_lag_log >= 0.5:
            last_lag_log = wall()
            events["lag"].append([round(wall(), 2), round((rt - pts) / Gst.MSECOND, 1)])

        buf = Gst.Buffer.new_wrapped(white if is_mark else dark)
        buf.pts = pts
        if is_mark:
            events["vmarks"].append([round(wall(), 3), round(pts / 1e6, 1)])
        buf.dts = Gst.CLOCK_TIME_NONE
        buf.duration = Gst.SECOND // FPS
        vsrc.emit("push-buffer", buf)


def audio_loop():
    """A clock-driven capture: 10ms chunks, sample-count PTS from the start."""
    n = RATE * CHUNK_MS // 1000
    start = time.monotonic()
    base = running_time()
    i = 0
    beep_left = 0
    next_mark = MARK_FIRST
    phase = 0.0
    skipped = 0
    while not stop.is_set():
        for p in apauses:
            if not p[2] and wall() >= p[0]:
                p[2] = True
                time.sleep(p[1])
                start += p[1]  # pacing resumes from now
                if args.apause_pts == "skip":
                    skipped += int(round(p[1] * 1000 / CHUNK_MS))
        target = start + i * CHUNK_MS / 1000.0
        d = target - time.monotonic()
        if d > 0:
            time.sleep(d)
        if wall() >= next_mark:
            next_mark += MARK_EVERY
            beep_left = 3  # 30ms
            events["amarks"].append([round(wall(), 3), round((base + (i + skipped) * CHUNK_MS * Gst.MSECOND) / 1e6, 1)])
        frames = []
        for _ in range(n):
            if beep_left > 0:
                s = int(30000 * math.sin(phase))
                phase += 2 * math.pi * 1000 / RATE
            else:
                s = 0
            frames.append(struct.pack("<hh", s, s))
        if beep_left > 0:
            beep_left -= 1
        buf = Gst.Buffer.new_wrapped(b"".join(frames))
        # skip: PTS stay on the clock across a pause; keep: they lose the pause.
        buf.pts = base + (i + skipped) * CHUNK_MS * Gst.MSECOND
        buf.duration = CHUNK_MS * Gst.MSECOND
        asrc.emit("push-buffer", buf)
        i += 1


def level_loop():
    while not stop.is_set():
        events["aq_level"].append([round(wall(), 2), aq.get_property("current-level-time") // Gst.MSECOND])
        time.sleep(0.1)


# Fixed clock + base time so running time is defined from the first push (a live
# pipeline only commits PLAYING once data reaches the sink).
clock = Gst.SystemClock.obtain()
pipe.use_clock(clock)
pipe.set_start_time(Gst.CLOCK_TIME_NONE)
pipe.set_base_time(clock.get_time())
pipe.set_state(Gst.State.PLAYING)
t0_mono = time.monotonic()
threads = [threading.Thread(target=f, daemon=True) for f in (video_loop, audio_loop, level_loop)]
for th in threads:
    th.start()
time.sleep(args.seconds)
stop.set()
for th in threads:
    th.join(timeout=2)
vsrc.emit("end-of-stream")
asrc.emit("end-of-stream")
bus = pipe.get_bus()
bus.timed_pop_filtered(10 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
pipe.set_state(Gst.State.NULL)
with open(args.events, "w") as f:
    json.dump(events, f)
print(f"done: overruns={len(events['overruns'])} reanchors={len(events['reanchors'])} "
      f"max aq level={max(l for _, l in events['aq_level'])}ms")
