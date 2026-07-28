import process from "node:process";

import { DEMO_FILE, DEMO_TICK_RATE, DEMO_TOTAL_TICKS } from "../env.mjs";
import { run } from "../util/run.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { gsiState } from "./gsi.mjs";
import { loadRoundTicks } from "./bindings.mjs";

// demo_gototick is not instant: ~2s stall forward, replay from tick 0
// backward. While settling, the estimate pins at the target.
const SEEK_SETTLE_CEILING_MS = 20_000;
// GSI events already in flight when the seek was issued still describe
// the pre-seek world; ignore them for this long.
const SEEK_SETTLE_MIN_MS = 400;

export const demoState = {
  lastTickAtSeek: 0,
  lastSeekRealMs: Date.now(),
  rate: 1,
  paused: false,
  totalTicks: DEMO_TOTAL_TICKS,
  tickRate: DEMO_TICK_RATE,
  lastActivityMs: Date.now(),
  // Non-null while a gototick is settling; the estimate is pinned here.
  seekTargetTick: null,
  seekIssuedMs: 0,
  worldMotionAtSeek: 0,
  // GSI frames in flight still show advancing time briefly after a real
  // pause lands; the pause-truth check ignores that window.
  lastPauseCmdMs: 0,
};

export function notePauseCommanded() {
  demoState.lastPauseCmdMs = Date.now();
}

export function bumpActivity() {
  demoState.lastActivityMs = Date.now();
}

function currentWorldMotion() {
  let sum = 0;
  for (const p of gsiState.players.values()) {
    if (p.position) {
      sum += p.position[0] + p.position[1] + p.position[2];
    }
  }
  return Math.round(sum);
}

export function noteSeek(targetTick) {
  demoState.lastTickAtSeek = targetTick;
  demoState.lastSeekRealMs = Date.now();
  demoState.seekTargetTick = targetTick;
  demoState.seekIssuedMs = Date.now();
  demoState.worldMotionAtSeek = currentWorldMotion();
}

export function clearSeek() {
  demoState.seekTargetTick = null;
}

export function isSeeking() {
  if (demoState.seekTargetTick === null) {
    return false;
  }
  if (Date.now() - demoState.seekIssuedMs > SEEK_SETTLE_CEILING_MS) {
    // No GSI confirmation (e.g. paused mid-settle) — un-pin.
    demoState.lastTickAtSeek = demoState.seekTargetTick;
    demoState.lastSeekRealMs = Date.now();
    demoState.seekTargetTick = null;
    return false;
  }
  return true;
}

export function estimateCurrentTick() {
  if (isSeeking()) {
    return demoState.seekTargetTick;
  }
  if (demoState.paused) {
    return demoState.lastTickAtSeek;
  }
  const elapsedSec = (Date.now() - demoState.lastSeekRealMs) / 1000;
  return Math.max(
    0,
    Math.round(demoState.lastTickAtSeek + elapsedSec * demoState.rate * demoState.tickRate),
  );
}

function roundContainingTick(roundTicks, tick) {
  for (const r of roundTicks) {
    if (tick >= r.start_tick && tick <= r.end_tick) {
      return r.round;
    }
  }
  return null;
}

// Seek-settle detection + freezetime anchoring. GSI map.round counts
// COMPLETED rounds: freezetime of parser round N reports map.round =
// N-1; round_ticks rounds are 1-based.
export function reconcileTickFromGsi(prev) {
  const now = Date.now();

  if (demoState.seekTargetTick !== null) {
    if (now - demoState.seekIssuedMs < SEEK_SETTLE_MIN_MS) {
      return;
    }
    const timeAdvanced =
      prev.prevPhaseEndsIn !== gsiState.phaseEndsIn &&
      gsiState.phaseEndsIn !== null;
    const worldMoved = currentWorldMotion() !== demoState.worldMotionAtSeek;
    if (!timeAdvanced && !worldMoved) {
      return;
    }
    const roundTicks = loadRoundTicks();
    const targetRound = roundContainingTick(roundTicks, demoState.seekTargetTick);
    const gsiRound = gsiState.roundNumber !== null ? gsiState.roundNumber + 1 : null;
    if (targetRound !== null && gsiRound !== null && gsiRound !== targetRound) {
      // Mid-sweep (backward seek replaying up to the target) — stay pinned.
      return;
    }
    demoState.lastTickAtSeek = demoState.seekTargetTick;
    demoState.lastSeekRealMs = now;
    demoState.seekTargetTick = null;
    return;
  }

  // cs2 can lose a demo_pause (exec-cfg keypress on a not-yet-
  // interactable cs2); if demo time advances while we believe paused,
  // adopt reality.
  const timeAdvanced =
    prev.prevPhaseEndsIn !== null &&
    gsiState.phaseEndsIn !== null &&
    prev.prevPhaseEndsIn !== gsiState.phaseEndsIn;
  if (
    timeAdvanced &&
    demoState.paused &&
    now - demoState.lastPauseCmdMs > 2_500
  ) {
    // Re-arm the throttle immediately so a slow cs2 doesn't get spammed
    // with pause retries every GSI tick (~10Hz) while this settles.
    notePauseCommanded();
    process.stderr.write(
      "[spec-server] pause desync: demo time advancing while paused=true — re-sending demo_pause\n",
    );
    void execCfgCommand("demo_pause").then((ok) => {
      if (!ok) {
        process.stderr.write(
          "[spec-server] pause desync: demo_pause re-send failed — cs2 not running?\n",
        );
      }
    });
  }

  const enteredFreezetime =
    prev.prevRoundPhase !== "freezetime" && gsiState.roundPhase === "freezetime";
  if (!enteredFreezetime || gsiState.roundNumber === null) {
    return;
  }
  // Don't fight a user action that just moved the playhead.
  if (now - demoState.lastSeekRealMs < 3_000) {
    return;
  }
  const entry = loadRoundTicks().find((r) => r.round === gsiState.roundNumber + 1);
  if (!entry) {
    return;
  }
  const drift = entry.start_tick - estimateCurrentTick();
  if (Math.abs(drift) < demoState.tickRate * 2) {
    return;
  }
  demoState.lastTickAtSeek = entry.start_tick;
  demoState.lastSeekRealMs = now;
  process.stderr.write(
    `[spec-server] tick anchor: round ${gsiState.roundNumber + 1} start=${entry.start_tick} corrected drift of ${Math.round(drift / demoState.tickRate)}s\n`,
  );
}

// cs2 keeps the .dem file open via fd for the entire playback, so
// presence in /proc/<pid>/fd/ is a reliable "demo is loaded" signal.
export async function demoLoadedInProc() {
  const wid = await findCs2Window();
  if (!wid) return false;
  const r = await run(["pgrep", "-f", "/linuxsteamrt64/cs2"]);
  if (r.code !== 0) return false;
  const pid = r.stdout.trim().split("\n")[0];
  if (!pid) return false;
  try {
    const fs = await import("node:fs/promises");
    const fdDir = `/proc/${pid}/fd`;
    for (const e of await fs.readdir(fdDir)) {
      try {
        if ((await fs.readlink(`${fdDir}/${e}`)) === DEMO_FILE) return true;
      } catch { /* fd closed between readdir and readlink */ }
    }
  } catch { /* /proc/<pid>/fd gone */ }
  return false;
}
