import process from "node:process";

import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { DEMO_SESSION_ID, STATUS_API_BASE } from "../env.mjs";
import { demoState } from "../state/demo.mjs";

export const playingState = {
  reported: false,
  // Set after the deferred demoui-hide keystroke lands. Surfaced in
  // /demo/state so batch-highlights doesn't capture the demoui panel.
  demouiHidden: false,
};

export function resetPlayingState() {
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
  // GSI lands AFTER the demoui panel renders; defer so the toggle
  // actually flips visible → hidden instead of no-op'ing pre-paint.
  // 500ms was tested and the demoui panel was still showing up in
  // captured clips — cs2 needs this full ~3s window between GSI's
  // first map-phase event and the panel being interactable.
  setTimeout(async () => {
    const ok = await execCfgCommand("demoui").catch(() => false);
    if (ok) {
      playingState.demouiHidden = true;
      return;
    }
    process.stderr.write(
      "[spec-server] demoui hide command failed to send — retrying once\n",
    );
    const retryOk = await execCfgCommand("demoui").catch(() => false);
    if (!retryOk) {
      process.stderr.write(
        "[spec-server] demoui hide retry failed — proceeding anyway (cs2 not running?)\n",
      );
    }
    playingState.demouiHidden = true;
  }, 3000);

  demoState.paused         = false;
  demoState.lastTickAtSeek = 0;
  demoState.lastSeekRealMs = Date.now();

  if (!DEMO_SESSION_ID || !STATUS_API_BASE) return;
  const url = `${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/status`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ status: "playing" }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      process.stderr.write(`[spec-server] status=playing POST ${res.status}\n`);
    }
  } catch (err) {
    process.stderr.write(
      `[spec-server] status=playing POST failed: ${(err && err.message) || err}\n`,
    );
  }
}
