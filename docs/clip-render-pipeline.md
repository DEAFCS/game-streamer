# Highlight clip render pipeline

How a batch pod turns a demo + a queue of clip jobs into uploaded highlight clips.
Covers the queue, one job's steps, and — in the most detail — what happens inside a
single segment, since that's where every timing bug so far has lived.

Source of truth for the behaviour described here:

| Layer | File |
| --- | --- |
| Batch queue | `src/lib/batch-highlights.sh` |
| One job, one segment | `src/lib/inline-clip-render.sh` |
| Capture lifecycle | `src/lib/clip-capture.sh` |
| Capture consumer | `src/vkcapture/vkcapture-consumer.c` |
| Demo/GSI endpoints | `src/spectator/routes/` |

---

## 1. The queue

A **job** is one player's kills in one round — the spec carries `round`, `kills_count`
and a `segments[]` list, one segment per kill (`start_tick`, `end_tick`, `kill_tick`,
`pov_steam_id`).

Jobs never render in parallel: each drives the shared CS2 process exclusively. Only the
tail — thumbnail extraction and upload, which touch nothing but disk and network —
overlaps the next job's capture.

```mermaid
gantt
    title Batch pod: one demo, one CS2, N jobs in series
    dateFormat X
    axisFormat %s

    section CS2 (exclusive)
    wait demo-ready (GSI + demoui hidden)   :crit, 0, 7
    warm-up 4x (uncaptured)                 :done, 7, 9
    job 1 capture (round 14, 3 kills)       :active, 9, 14
    job 2 capture (round 19, 2 kills)       :active, 14, 18
    job 3 capture (round 22, 4 kills)       :active, 18, 23

    section Assemble
    concat 1                                :14, 16
    concat 2                                :18, 20
    concat 3                                :23, 25

    section Upload tail (overlaps)
    thumb + upload 1                        :16, 20
    thumb + upload 2                        :20, 24
    thumb + upload 3                        :25, 29
```

CS2 is released at the `.cs2done` marker — written right after concat, **before** the
upload — which is what lets job N+1 start seeking while job N is still uploading.

### Queue rules

| Rule | Knob | Why |
| --- | --- | --- |
| Wait for the demo to be render-ready before job 1 | `DEMO_READY_TIMEOUT` (300s) | Seeking an unloaded demo lands on tick 0 and captures black. Requires GSI to have fired **and** the demo UI panel to be hidden. |
| At most 2 upload tails in flight | `CLIP_BATCH_MAX_TAILS` (2) | A slow API would otherwise stack every finished clip on local disk at once. The oldest is reaped before the next job starts. |
| Warm each segment's Vulkan pipelines before recording it | `CLIP_WARMUP` (on), `CLIP_WARMUP_RATE` (4x), `CLIP_WARMUP_SETTLE_MS` (12s), `CLIP_WARMUP_ONCE` (off) | Before each segment, replays its range at 4x with nothing recording, then waits for cs2's CPU to settle (the compile queue draining), so pipeline compilation doesn't land inside a real capture. Without it the first segment rendered at ~25fps for ~7s with cs2 at ~1000% CPU, and with only the first segment warmed a later kill still held ~0.5s of frames. Ranges already warmed for this CS2 are skipped (marker file, dropped when a fresh CS2 starts). `CLIP_WARMUP_ONCE=1` warms only the first segment. |
| An engine fatal kills the rest of the batch | `CS2_FATAL_SENTINEL` | Once CS2 dies, remaining jobs are failed fast with a reason instead of capturing frozen frames. |

---

## 2. One job

These are the `STEP` labels as they print in the render log, in order.

| Log label | What it does |
| --- | --- |
| `STEP 1` | Snapshot the demo state (tick, paused) so the job can be undone. |
| `STEP 1b` | `spec_autodirector 0` — otherwise CS2's director fights the POV lock and the camera flickers at segment starts. |
| `STEP 1a` | Stop the live capture (live pods only — the GPU encoder can't serve stream and clip at once). |
| prep | Decide branding; **defer** the Remotion player-chip render. Running it during a capture caused a visible stutter, so it's kept outside the capture window. |
| warm-up | Before each segment, replay its range at 4x, uncaptured, then wait for the compiles to settle. Ranges this CS2 already warmed are skipped. |
| `STEP 2`–`STEP 8` | **Segment loop**, once per kill. Each pass writes one `seg-NNN.mp4`. See below. |
| polish | Burn the chip overlay into each segment, backgrounded so it overlaps the next segment's capture. Reaped before assembly. |
| `STEP 9` | Concat segments + append the outro. Tries a stream copy first and verifies the output duration; falls back to a filter-graph re-encode if the copy is refused or the duration drifts >2s. Direct cuts, no fades — crossfades compounded with CS2's seek-load frames into ~1s of dead air per join. |
| `STEP 9a` | Restart the live capture, then touch the release marker — this is the handoff that lets the next job start. |
| tail | Extract a thumbnail, upload the clip. Runs after CS2 is already handed over. |

---

## 3. One segment

Everything here exists because **`POST /demo/seek` returns as soon as the seek is
*queued***. CS2 executes it asynchronously and slowly, and a backward seek replays from
tick 0 — which is what every segment does.

```mermaid
sequenceDiagram
    autonumber
    participant R as inline-clip-render
    participant S as spec-server / CS2
    participant C as capture consumer

    R->>S: STEP 2 force-pause
    R->>S: STEP 3 seek to SEG_PRE (SEG_START - pre-roll)
    S-->>R: 200 (queued, not arrived)
    R->>R: wait_seek_settled (<=8s)

    R->>S: STEP 4 toggle play (0.6s lead-in)
    Note over R,S: spec commands no-op while paused,<br/>so the POV lock needs playback
    R->>S: STEP 4b lock POV to the kill's player
    R->>R: verify via GSI spectated_steam_id

    R->>S: pause + seek to SEG_PRE again + speed 1
    Note over R,S: large backward seek — the slowest kind
    R->>R: wait_seek_settled (<=8s)
    R->>S: STEP 4c re-press slot (re-seek reset the POV)

    R->>C: STEP 6 start capture
    C->>C: layer handshake, map shared texture
    C-->>R: armed (ready file)
    R->>R: wait_clip_capture_ready (<=8s)

    R->>S: STEP 5 force-pause, toggle play
    R->>R: wait_playback_moving (<=2.5s)
    R->>S: re-press POV slot
    R->>R: wait_preroll (2s of demo time, off the phase clock)
    R->>C: clip_capture_go (start gate, at SEG_START)
    Note over C: recording begins HERE

    loop STEP 7, poll 150ms
        R->>S: capture-fields (phase, clock, motion, kills)
        R->>R: bill wall-clock, withhold real freezes
    end

    R->>C: STEP 8 SIGINT -> EOS -> moov
```

### The playhead

Demo tick against wall-clock time, for one segment. Dashed = seek (playhead sweeps back
through tick 0), solid = real playback.

```
 tick
   |                                                        ,-* END
   |                                                    ,--'
   |                                                ,--'
   |                                            ,--'
   |                                        ,--'
   |                                    ,--'      <- recorded window
   |         _.-*                   ,--'
   |     _.-'                   ,--'
 START *'         *===========*'
   |   /\         /\           ^ gate opens after the pre-roll (demo back at START)
   |  /  \       /  \
   | /    \     /    \         *=====*  held paused (capture arming +
   |/      \   /      \                  CS2 digesting the unpause)
   0 -------\-/--------\-/------------------------------------------> wall clock
        seek back    seek back again
        (STEP 3)     (STEP 4c)
```

### What lands in the file

| | |
| --- | --- |
| **Reaches the mp4** | Only the final play-through: from the moment the demo is confirmed moving, until the wall-clock budget is spent. |
| **Never recorded** | Both backward seeks, the 0.6s lead-in, POV-lock polling, the capture handshake, the frame CS2 holds while it digests the unpause, and the 2s pre-roll (smokes re-blooming, sound restarting and the POV re-press all settle there). |
| **Recorded but not billed** | A mid-clip freeze, detected via a flat GSI phase clock, is withheld from the budget so the kill isn't cut off — capped at `CLIP_UNBILLED_CAP_MS` (2200ms). |

### The start gate

The capture is deliberately spawned **while the demo is still paused at `SEG_START`**, so
that recording opens exactly at the pre-roll rather than wherever the demo drifted to. But
spawning is not recording, and CS2 holds the paused frame for a while after a big backward
unpause — so the consumer separates *armed* from *recording*:

1. `VKCAP_READY_FILE` is touched when the shared texture is mapped — **armed**. The
   renderer waits for this before pressing play.
2. `VKCAP_START_FILE` holds the pipeline in `READY`, discarding CS2's frames, until
   `clip_capture_go` touches it.
3. Going `PLAYING` happens on the first frame after the gate opens, so the pulsesrc audio
   starts in lockstep with the first *recorded* video frame.

Without `VKCAP_START_FILE` the consumer arms and records immediately — that's the path the
live stream uses, and it's unchanged.

### The fixed timestep

cs2's own `fps_max` limiter overshoots (~63-64 presents/s at `fps_max 60`), so a
wall-clock capture squeezed 64 renders into 60 slots — `videorate` dropped 3-4 frames a
second — and any render spike froze frames. While a segment records (`CLIP_FIXED_TIMESTEP=1`,
**off by default**: in production cs2 fell to ~25fps under it during a fight, so the
game ran at ~0.45x; frame stamps are now re-anchored rather than trail the clock by
more than 250ms, which had backed the muxer's audio queue up into an EOS deadlock):

| Piece | Where | What it does |
| --- | --- | --- |
| Exact pacing | `present-eventfd.patch` | The layer holds each present to an absolute 1/fps grid, catching up after a stall of up to 250ms. Only when the consumer asks (`pace_fps`), and it echoes the rate back in the texture message. |
| Frame-count PTS | `vkcapture-consumer.c` | Present N is stamped `base + N/fps` instead of its arrival time. Engaged only when the layer confirmed pacing; reported as `paced=1` in the ready file. |
| Fixed game step | `inline-clip-render.sh` | `host_framerate <fps>` from STEP 5 to STEP 8, only on a `paced=1` capture, so each frame is exactly one game step. The first segment logs cs2's console echo (`host_framerate console:`). |
| Audio retime | `inline-clip-render.sh` | The consumer writes the video (game) and wall spans to `<seg>.timing`; a drift over 35ms stretches the audio by wall/video (`atempo`). |

`fps_max` for clip batches is 2x the clip rate: headroom for the catch-up, the layer does
the exact pacing. An image without the patched layer degrades to the wall-clock capture.

### Grid pacing

`CLIP_PACE` (on by default; `CLIP_PACE=0` turns it off) keeps the exact pacing and frame-count PTS but leaves the
game clock alone (no `host_framerate`). A frame that misses its 1/fps slot presents in
the slot it lands in and the missed slots are skipped, keeping the grid's phase, instead
of the next frames catching up; the layer's poke carries how many slots the frame
advanced, so the consumer's frame count always equals wall time. That fixes the
`fps_max` overshoot drops, a render spike shows as an honest repeated frame, and the
stamps can't drift behind the audio. The consumer's `DEBUG` line reports slots/s, frames,
skipped slots and how long each frame took to read.

Live and replay streams use the same grid pacing on their cs2+HUD composite capture
(`LIVE_PACE`, on by default). The frame handoff is opt-in there
(`LIVE_FRAME_HANDOFF=1`): on a replay stream it skipped 5-20 frames a second during
rounds, while the same demo recorded as clips skipped none.

### Zero-copy

`CLIP_ZEROCOPY=1` (off by default). Measured on a node against the host-map copy with the frame handoff on: it engaged cleanly but capture CPU didn't drop (34% → 38%), GPU use rose (49% → 60%) and frame reads went from 1.4ms to ~5ms (the synchronous CUDA copy), so it stays opt-in. `cudaupload` has never taken DMABuf input on any
GStreamer, so the consumer imports the image itself: the layer exports the shared image
as an `OPAQUE_FD` (it reports the allocation size and whether the export worked in the
texture message), the consumer imports it with CUDA's external-memory API (resolved from
libcuda at runtime; gst-cuda's headers build against GStreamer's stub `cuda.h`), and each
frame is one `CuMemcpy2DAsync` + sync into a pooled CUDA buffer pushed as
`memory:CUDAMemory` on our CUDA context, which `cudaupload` passes through. The copy is
synchronous, so the frame handoff still acks after the read. Fallbacks: no CUDA => the
consumer drops the CUDA feature from the `vkcaps` filter (host-map path as before); the
export or import fails => it asks the layer for the host-mapped image and uploads each
frame to CUDA itself; the consumer dies on spawn => the shell retries without zero-copy.

### The frame handoff

The layer copies each frame into ONE shared image that the consumer reads on the CPU.
Poking the consumer right after the copy was *submitted* let it read before the copy
*landed* — the previous frame, or a torn one, depending on GPU timing. With
`CLIP_FRAME_HANDOFF` (on by default; `0` turns it off):

1. The layer hands the copy's fence to a helper thread; the present thread doesn't wait.
2. The helper waits for the fence, pokes, then waits (≤20ms) for the consumer to report
   the read done on an ack socket (a running total, so a late ack can't count twice).
3. The next present drains that before submitting its copy, so the image never changes
   under a read.

The consumer logs `frame handoff ENGAGED`, or a WARN when the layer predates it. It covers
zero-copy too: the CUDA copy out of the shared image is synchronous, so the ack still
follows the read.

### Encode quality

Segments are captured with NVENC at `CLIP_VIDEO_KBPS` (24 Mbps) CBR, p5/high-quality,
with spatial and temporal AQ when the element has them. That file is an intermediate:
STEP 9 (and the chip polish) re-encode it with `h264_nvenc` p6/hq, two-pass (quarter
res), spatial+temporal AQ, lookahead and B-frames as references, at `CLIP_FINAL_BITRATE`
(9 Mbps) VBR with peaks to `CLIP_FINAL_MAXRATE` (14 Mbps) — about the size the old
libx264 veryfast/crf 22 encode made, and roughly twice as fast. Constant quality 19
tripled the file size without a visible difference. NVENC is checked with a tiny test
encode first; the old libx264 encode is the fallback, and `CLIP_FINAL_ENCODER=x264`
forces it.

---

## 4. Every wait, and what happens when it expires

Nothing blocks forever. The standing rule is that a late clip beats no clip.

| Gate | Signal | Ceiling | On expiry |
| --- | --- | --- | --- |
| Demo ready | GSI fired **and** `demoui_hidden` | `DEMO_READY_TIMEOUT` 300s | Fails the whole batch with a reason so the node frees instead of hanging. |
| Seek settled | `/demo/seek-state` reports the gototick finished (needs a post-landing GSI frame that shows a change — the 1s GSI heartbeat provides one while paused; a seek to the tick cs2 is already on never settles) | `CLIP_SEEK_SETTLE_TIMEOUT_MS` 8s (the STEP 4d re-seek: `CLIP_RESEEK_SETTLE_TIMEOUT_MS` 3s) | Proceeds anyway. Motion is **not** usable here — the backward replay sweep moves the world and ticks the round clock, so a motion check reads "playing" mid-sweep. |
| POV locked | GSI `spectated_steam_id` matches the target | 2 tries | Re-presses the slot once, then proceeds on whatever POV CS2 has. |
| Capture armed | Consumer's ready file appears | `CLIP_CAPTURE_READY_TIMEOUT_MS` 8s | Starts playback anyway — the opening frames won't be in the file. |
| Playback moving | Fresh GSI whose `phase_ends_in`/`world_motion` differ from the pre-unpause values (GSI stops while paused, so fresh GSI itself means rolling) | `CLIP_PLAY_CONFIRM_TIMEOUT_MS` 2.5s | Continues to the pre-roll regardless. |
| Pre-roll | `CLIP_PREROLL_MS` (2s) of demo time off the `phase_ends_in` countdown — a flat clock (post-seek stall) isn't counted | pre-roll + `CLIP_UNBILLED_CAP_MS` + 2s | Opens the gate anyway. vkcapture only; `CLIP_PREROLL_MS=0` restores gate-at-START. |
| Start gate backstop | Consumer polls for the go file each frame | `VKCAP_START_TIMEOUT_MS` 20s | Records anyway, so a renderer that never signals yields a late clip rather than an empty one. |
| Segment budget | Wall clock, billed per 150ms poll | `CLIP_SEGMENT_TIMEOUT_FACTOR` 2x duration | Hard stop for a wedged demo, tight enough that a misfire can't run deep into the next round. |
| Capture drain | SIGINT → EOS → qtmux writes the moov atom | 15s | Polls at 100ms; every extra poll is dead time between segments. |

Worst case these compound: a single segment can spend ~18s in setup gates before recording
a frame. In practice each one returns in well under a second.

---

## 5. What cuts a segment short

The record loop doesn't only count down.

| Condition | Detection | Action |
| --- | --- | --- |
| Round bleed | GSI round number advances past the one the segment opened in | Stops immediately — the clip has run out of its round. |
| Match end | Map phase hits gameover (armed only for segments near the demo's end) | Stops early rather than recording the post-match screen. |
| Demo frozen | Phase clock flat for 2 consecutive polls | Withholds the time from the budget and kicks playback with pause→toggle, up to 4 times. |
| Demo never advanced | GSI signature identical across 12+ polls | Marks the CS2 session fatal and fails the job — the known engine replay bug. |
| Empty capture | Raw mp4 probes as zero-length or undecodable | Retries the segment once on the ximagesrc path, then drops it from the concat rather than silently truncating the montage. |

---

## Caveat: the ximagesrc fallback

The armed-but-holding state — and therefore the clean opening frame — exists only on the
vkcapture path (`CLIP_CAPTURE_METHOD=vkcapture`, the default, which needs
`nvidia-drm.modeset=1` on the host). The ximagesrc fallback grabs the screen the instant
its pipeline goes live, so it still records the held frame at the top of every segment.
