import { readFile, rm } from "node:fs/promises";
import process from "node:process";

import { DISPLAY, LOG_DIR } from "../env.mjs";
import { run } from "../util/run.mjs";

// cs2's demo bar (`demoui`) can only be toggled — no explicit hide and no way to
// ask whether it's open — so we look at the screen instead of guessing a delay.

const GRAB_W = 960;
const GRAB_H = 540;
const GRAB_PATH = `${LOG_DIR}/demoui-grab.gray`;

// The bar's top border is a straight edge across the full width; game scenes almost
// never have one in the bottom strip. Measured on real clips: bar open 0.97-1.00,
// closed 0.08-0.57.
export const DEMOUI_BAR_THRESHOLD = 0.85;

// Share of columns with a sharp vertical step on the most "edgy" row of the bottom
// 15% of a GRAY8 frame.
export function demouiBarScore(gray, width, height) {
  let best = 0;
  for (let y = Math.floor(height * 0.85); y < height - 1; y++) {
    const a = y * width;
    const b = a + width;
    let edges = 0;
    for (let x = 0; x < width; x++) {
      if (Math.abs(gray[b + x] - gray[a + x]) > 6) edges++;
    }
    best = Math.max(best, edges / width);
  }
  return best;
}

// Grab the screen as GRAY8 at GRAB_W x GRAB_H; null when the grab fails.
async function grabScreenGray() {
  await rm(GRAB_PATH, { force: true });
  const { code } = await run([
    "gst-launch-1.0", "-q",
    "ximagesrc", `display-name=${DISPLAY}`, "use-damage=0", "num-buffers=1", "show-pointer=false",
    "!", "videoconvert", "!", "video/x-raw,format=GRAY8",
    "!", "videoscale", "method=bilinear", "!", `video/x-raw,width=${GRAB_W},height=${GRAB_H}`,
    "!", "filesink", `location=${GRAB_PATH}`,
  ], { timeoutMs: 5000 });
  if (code !== 0) return null;
  try {
    const buf = await readFile(GRAB_PATH);
    return buf.length >= GRAB_W * GRAB_H ? buf : null;
  } catch {
    return null;
  }
}

// null when the screen can't be read.
export async function demouiBarVisible() {
  const gray = await grabScreenGray();
  if (!gray) return null;
  const score = demouiBarScore(gray, GRAB_W, GRAB_H);
  // Average brightness: ~0 means the grab came back black rather than showing cs2.
  let sum = 0;
  for (let i = 0; i < GRAB_W * GRAB_H; i++) sum += gray[i];
  return { visible: score >= DEMOUI_BAR_THRESHOLD, score, mean: sum / (GRAB_W * GRAB_H) };
}

export function logDemoui(msg) {
  process.stderr.write(`[spec-server] demoui: ${msg}\n`);
}

const CHECK_MS = 1_000;
// A bar we never see may just be late on a slow box; stop waiting for it after this.
const NEVER_SEEN_MS = 30_000;
// Once closed, it has to stay closed this many checks in a row (a late toggle could reopen it).
const CONFIRM_CHECKS = 3;
// Toggles sent before the panel is interactable can no-op; retry, but not forever.
const MAX_TOGGLES = 4;
// Fallback when the screen can't be read: the old fixed delay after the first GSI event.
const BLIND_TOGGLE_MS = 3_000;

const realSleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Toggle the demo bar only while it's actually showing, then confirm it stays hidden.
// Returns how it ended: "hidden" | "never-showed" | "gave-up" | "blind" | "stale".
export async function hideDemoui({
  toggle,
  isCurrent = () => true,
  check = demouiBarVisible,
  sleep = realSleep,
  now = Date.now,
  log = logDemoui,
}) {
  const start = now();
  let seen = false;
  let toggles = 0;
  let closedChecks = 0;
  let lowest = Infinity;
  let highest = 0;
  await sleep(CHECK_MS);
  while (isCurrent()) {
    const bar = await check();
    if (!bar) {
      log("can't read the screen — falling back to the timed toggle");
      await sleep(Math.max(0, BLIND_TOGGLE_MS - (now() - start)));
      await toggle();
      return "blind";
    }
    lowest = Math.min(lowest, bar.score);
    highest = Math.max(highest, bar.score);
    if (bar.visible) {
      if (toggles >= MAX_TOGGLES) {
        log(`still showing after ${toggles} toggles (score ${bar.score.toFixed(2)}) — giving up`);
        return "gave-up";
      }
      seen = true;
      closedChecks = 0;
      toggles += 1;
      log(`bar showing (score ${bar.score.toFixed(2)}) — toggle ${toggles}`);
      await toggle();
    } else {
      closedChecks += 1;
      if (seen && closedChecks >= CONFIRM_CHECKS) {
        log(`hidden and staying hidden after ${now() - start}ms (score ${bar.score.toFixed(2)})`);
        return "hidden";
      }
      if (!seen && now() - start >= NEVER_SEEN_MS) {
        log(`never showed in ${NEVER_SEEN_MS}ms (scores ${lowest.toFixed(2)}-${highest.toFixed(2)}, brightness ${bar.mean.toFixed(0)}) — nothing to hide`);
        return "never-showed";
      }
    }
    await sleep(CHECK_MS);
  }
  return "stale";
}
