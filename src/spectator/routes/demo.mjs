import process from "node:process";

import {
  KEY_DEMO_TOGGLE,
  KEY_XRAY_TOGGLE,
  SPEED_KEY_BY_RATE,
} from "../constants.mjs";
import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { sendKey } from "../cs2/input.mjs";
import {
  bumpActivity,
  clearSeek,
  demoState,
  estimateCurrentTick,
  notePauseCommanded,
  noteSeek,
} from "../state/demo.mjs";
import { gsiState } from "../state/gsi.mjs";
import { loadRoundTicks } from "../state/bindings.mjs";
import { resetPlayingState } from "../reporters/demo-playing.mjs";
import { pushStateSoon } from "../reporters/state-push.mjs";
import { sendJson } from "../util/http.mjs";

// cs2 executes every gototick it's handed (multi-second stalls), so
// seeks coalesce: one pending slot, newest target wins.
let pendingSeek = null;
let seekRunnerActive = false;

function queueSeek(tick, pauseAfter) {
  pendingSeek = { tick, pauseAfter };
  // Pin now so /demo/state parks at the target during catch-up.
  noteSeek(tick);
  demoState.paused = pauseAfter;
  if (pauseAfter) {
    notePauseCommanded();
  }
  bumpActivity();
  pushStateSoon();
  void runSeekQueue();
}

async function runSeekQueue() {
  if (seekRunnerActive) {
    return;
  }
  seekRunnerActive = true;
  try {
    while (pendingSeek) {
      const { tick, pauseAfter } = pendingSeek;
      pendingSeek = null;
      // cs2's post-gototick play state isn't deterministic across
      // builds — always pass the explicit pause arg.
      const ok = await execCfgCommand(`demo_gototick ${tick} 0 ${pauseAfter ? 1 : 0}`);
      if (!ok) {
        process.stderr.write(`[spec-server] seek to ${tick} failed — cs2 not running?\n`);
        clearSeek();
      } else if (pendingSeek === null) {
        // Restart the settle clock from when cs2 actually received it.
        noteSeek(tick);
      }
    }
  } finally {
    seekRunnerActive = false;
  }
}

export async function toggleHandler(_req, res) {
  const ok = await sendKey(KEY_DEMO_TOGGLE);
  if (ok) {
    demoState.paused = !demoState.paused;
    if (demoState.paused) {
      demoState.lastTickAtSeek = estimateCurrentTick();
      notePauseCommanded();
    }
    demoState.lastSeekRealMs = Date.now();
    bumpActivity();
    pushStateSoon();
  }
  sendJson(res, ok ? 200 : 503, ok ? { ok, paused: demoState.paused } : { error: "cs2 not running" });
}

export async function pauseHandler(_req, res) {
  if (pendingSeek) {
    pendingSeek.pauseAfter = true;
  }
  const ok = await execCfgCommand("demo_pause");
  if (ok) {
    demoState.lastTickAtSeek = estimateCurrentTick();
    demoState.paused = true;
    demoState.lastSeekRealMs = Date.now();
    notePauseCommanded();
    bumpActivity();
    pushStateSoon();
  }
  sendJson(res, ok ? 200 : 503, ok ? { ok, paused: true } : { error: "cs2 not running" });
}

export async function resumeHandler(_req, res) {
  if (pendingSeek) {
    pendingSeek.pauseAfter = false;
  }
  const ok = await execCfgCommand("demo_resume");
  if (ok) {
    demoState.paused = false;
    demoState.lastSeekRealMs = Date.now();
    bumpActivity();
    pushStateSoon();
  }
  sendJson(res, ok ? 200 : 503, ok ? { ok, paused: false } : { error: "cs2 not running" });
}

export async function seekHandler(_req, res, body) {
  const tick = Number.parseInt(body.tick, 10);
  if (!Number.isFinite(tick) || tick < 0) {
    sendJson(res, 400, { error: "tick (non-negative int) required" });
    return;
  }
  const pauseAfter =
    body.pause_after === true ? true :
    body.pause_after === false ? false :
    demoState.paused;
  queueSeek(tick, pauseAfter);
  sendJson(res, 200, { ok: true, tick, paused: pauseAfter });
}

export async function skipHandler(_req, res, body) {
  const secs = Number.parseFloat(body.secs);
  if (!Number.isFinite(secs)) {
    sendJson(res, 400, { error: "secs (number) required" });
    return;
  }
  // Relative moves must use the pod estimate — the client's drifts.
  const target = Math.max(0, estimateCurrentTick() + Math.round(secs * demoState.tickRate));
  queueSeek(target, demoState.paused);
  sendJson(res, 200, { ok: true, secs, tick: target });
}

export async function speedHandler(_req, res, body) {
  const rate = Number.parseFloat(body.rate);
  if (!Number.isFinite(rate) || rate <= 0) {
    sendJson(res, 400, { error: "rate (positive number) required" });
    return;
  }
  // host_timescale > 8 destabilises cs2's tick + audio sync.
  const clamped = Math.min(8, Math.max(0.1, rate));
  demoState.lastTickAtSeek = estimateCurrentTick();
  demoState.lastSeekRealMs = Date.now();
  const presetKey = SPEED_KEY_BY_RATE[String(clamped)];
  const ok = presetKey
    ? await sendKey(presetKey)
    : await execCfgCommand(`host_timescale ${clamped}`);
  if (ok) {
    demoState.rate = clamped;
    bumpActivity();
    pushStateSoon();
  }
  sendJson(res, ok ? 200 : 503,
    ok ? { ok, rate: clamped, via: presetKey ? "key" : "console" } : { error: "cs2 not running" },
  );
}

export async function reloadHandler(_req, res) {
  const ok = await execCfgCommand(`playdemo /tmp/game-streamer/demo.dem`);
  if (ok) {
    pendingSeek = null;
    clearSeek();
    demoState.lastTickAtSeek = 0;
    demoState.lastSeekRealMs = Date.now();
    demoState.paused = false;
    resetPlayingState();
    bumpActivity();
    pushStateSoon();
  }
  sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
}

// A clip batch relaunched cs2 after an engine fatal. The new process replays the demo
// from tick 0 and must send GSI and get its demo bar hidden before the batch records,
// so forget everything the old one reported.
export async function resetSessionHandler(_req, res) {
  pendingSeek = null;
  clearSeek();
  demoState.lastTickAtSeek = 0;
  demoState.lastSeekRealMs = Date.now();
  demoState.paused = false;
  demoState.rate = 1;
  gsiState.lastReceivedMs = 0;
  resetPlayingState();
  bumpActivity();
  sendJson(res, 200, { ok: true });
}

export async function xrayHandler(_req, res, body) {
  const ok = await sendKey(KEY_XRAY_TOGGLE);
  if (ok) bumpActivity();
  sendJson(res, ok ? 200 : 503, ok ? { ok, enabled: Boolean(body.enabled) } : { error: "cs2 not running" });
}

export async function demouiHandler(_req, res) {
  const ok = await sendKey("F11");
  if (ok) bumpActivity();
  sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
}

export async function roundHandler(_req, res, body) {
  const round = Number.parseInt(body.round, 10);
  if (!Number.isFinite(round) || round < 1) {
    sendJson(res, 400, { error: "round (int >= 1) required" });
    return;
  }
  const entry = loadRoundTicks().find((r) => r.round === round);
  if (!entry) {
    sendJson(res, 404, { error: `no tick mapping for round ${round}` });
    return;
  }
  queueSeek(entry.start_tick, demoState.paused);
  sendJson(res, 200, { ok: true, round, tick: entry.start_tick });
}

export async function execHandler(_req, res, body) {
  const cmd = typeof body.cmd === "string" ? body.cmd : "";
  if (!cmd.trim()) {
    sendJson(res, 400, { error: "cmd (string) required" });
    return;
  }
  const ok = await execCfgCommand(cmd);
  bumpActivity();
  sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
}
