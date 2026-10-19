import process from "node:process";
import { readFileSync } from "node:fs";

import { hideDemoui } from "../cs2/demoui.mjs";
import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { DEMO_SESSION_ID, STATUS_ACK_FILE, STATUS_API_BASE } from "../env.mjs";
import { demoState } from "../state/demo.mjs";

export const playingState = {
  reported: false,
  // Set after the deferred demoui-hide keystroke lands. Surfaced in
  // /demo/state so batch-highlights doesn't capture the demoui panel.
  demouiHidden: false,
};

// Bumped on every reset so a beacon still waiting/retrying for the previous
// playback stops instead of double-posting alongside the new one.
let generation = 0;

const LIVE_ACK_POLL_MS    = 500;
const LIVE_ACK_TIMEOUT_MS = 60_000;
const POST_RETRY_MS       = 2_000;

export function resetPlayingState() {
  generation += 1;
  playingState.reported = false;
  playingState.demouiHidden = false;
}

export async function reportDemoPlayingOnce() {
  if (playingState.reported) return;
  playingState.reported = true;

  // No boot pause — the demo autoplays from tick 0. Real-time playback
  // from 0 keeps the estimate honest (freezetime anchors absorb drift),
  // and a demo_pause here raced cs2's not-yet-interactable window anyway.
  //
  // Clip batches watch the screen and toggle only while the bar is really showing, so a
  // slow box that opens it late can't leave it stuck open. Streaming keeps the timed
  // toggle: its HUD window sits over cs2 and would muddy the screen grab.
  if (process.env.CLIP_BATCH_MODE === "1") {
    hideDemouiWhenShowing(generation);
  } else {
    // GSI lands AFTER the demoui panel renders; defer so the toggle
    // actually flips visible → hidden instead of no-op'ing pre-paint.
    // 500ms was tested and the demoui panel was still showing up in
    // captured clips — cs2 needs this full ~3s window between GSI's
    // first map-phase event and the panel being interactable.
    setTimeout(() => {
      void execCfgCommand("demoui")
        .catch(() => undefined)
        .finally(() => { playingState.demouiHidden = true; });
    }, DEMOUI_BLIND_TOGGLE_MS);
  }

  demoState.paused         = false;
  demoState.lastTickAtSeek = 0;
  demoState.lastSeekRealMs = Date.now();

  if (!DEMO_SESSION_ID || !STATUS_API_BASE) return;
  await postPlaying(generation);
}

function liveAcked() {
  try {
    return JSON.parse(readFileSync(STATUS_ACK_FILE, "utf8")).status === "live";
  } catch {
    return false;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const DEMOUI_BLIND_TOGGLE_MS = 3_000;

function hideDemouiWhenShowing(mine) {
  const isCurrent = () => mine === generation;
  void hideDemoui({
    toggle: () => execCfgCommand("demoui").catch(() => undefined),
    isCurrent,
  }).finally(() => { if (isCurrent()) playingState.demouiHidden = true; });
}

// GSI flows as soon as cs2 has the demo loaded, which is routinely BEFORE
// run-demo.sh finishes start_capture and its `live` reaches the api through
// the 2s status daemon. `playing` sent that early either gets overwritten by
// the late `live` (viewer stuck on "Demo Loading") or mounts the WHEP player
// against a path with no publisher (3 failures → permanent HLS fallback). So
// hold it until `live` is acked, and keep retrying: nothing re-sends it.
async function postPlaying(mine) {
  const deadline = Date.now() + LIVE_ACK_TIMEOUT_MS;
  while (mine === generation && !liveAcked() && Date.now() < deadline) {
    await sleep(LIVE_ACK_POLL_MS);
  }
  if (mine === generation && !liveAcked()) {
    process.stderr.write(
      `[spec-server] status=live never acked after ${LIVE_ACK_TIMEOUT_MS}ms — sending playing anyway\n`,
    );
  }

  const url = `${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/status`;
  while (mine === generation) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "playing" }),
        signal: AbortSignal.timeout(5_000),
      });
      if (res.ok) return;
      process.stderr.write(`[spec-server] status=playing POST ${res.status}\n`);
      // 4xx won't get better by asking again (bad body / session gone).
      if (res.status >= 400 && res.status < 500) return;
    } catch (err) {
      process.stderr.write(
        `[spec-server] status=playing POST failed: ${(err && err.message) || err}\n`,
      );
    }
    await sleep(POST_RETRY_MS);
  }
}
