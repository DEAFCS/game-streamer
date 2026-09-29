// node --test src/spectator/cs2/demoui.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { DEMOUI_BAR_THRESHOLD, demouiBarScore, hideDemoui } from "./demoui.mjs";

// A fake cs2: the bar opens on its own at `opensAt`, and a toggle only takes effect once
// the panel is interactable (`interactableAt`), like the real one. Time is simulated.
function fakeCs2({ opensAt = 0, interactableAt = 0, reopensAt = null, readable = true } = {}) {
  let t = 0;
  let open = false;
  let opened = false;
  let reopened = false;
  const toggles = [];
  const settle = () => {
    if (!opened && t >= opensAt) { open = true; opened = true; }
    if (reopensAt !== null && !reopened && t >= reopensAt) { open = true; reopened = true; }
  };
  return {
    toggles,
    now: () => t,
    sleep: async (ms) => { t += ms; settle(); },
    check: async () => {
      settle();
      if (!readable) return null;
      const score = open ? 0.99 : 0.2;
      return { visible: score >= DEMOUI_BAR_THRESHOLD, score, mean: 90 };
    },
    toggle: async () => {
      toggles.push(t);
      if (t >= interactableAt) open = !open;
    },
    log: () => {},
  };
}

test("hides a bar that opens late on a slow box", async () => {
  const cs2 = fakeCs2({ opensAt: 6_000 });
  assert.equal(await hideDemoui(cs2), "hidden");
  assert.equal(cs2.toggles.length, 1);
  assert.ok(cs2.toggles[0] >= 6_000);
});

test("retries a toggle sent before the panel was interactable", async () => {
  const cs2 = fakeCs2({ opensAt: 0, interactableAt: 2_500 });
  assert.equal(await hideDemoui(cs2), "hidden");
  assert.ok(cs2.toggles.length >= 2);
});

test("closes the bar again if it reopens during confirmation", async () => {
  const cs2 = fakeCs2({ opensAt: 0, reopensAt: 2_500 });
  assert.equal(await hideDemoui(cs2), "hidden");
  assert.equal(cs2.toggles.length, 2);
});

test("never toggles a bar that never shows", async () => {
  const cs2 = fakeCs2({ opensAt: Infinity });
  assert.equal(await hideDemoui(cs2), "never-showed");
  assert.equal(cs2.toggles.length, 0);
});

test("falls back to the timed toggle when the screen can't be read", async () => {
  const cs2 = fakeCs2({ readable: false });
  assert.equal(await hideDemoui(cs2), "blind");
  assert.deepEqual(cs2.toggles, [3_000]);
});

test("stops when a newer demo playback takes over", async () => {
  const cs2 = fakeCs2({ opensAt: Infinity });
  assert.equal(await hideDemoui({ ...cs2, isCurrent: () => false }), "stale");
  assert.equal(cs2.toggles.length, 0);
});

test("scores a full-width edge in the bottom strip as the bar", () => {
  const w = 960;
  const h = 540;
  const frame = new Uint8Array(w * h);
  // Scene: lots of vertical detail, only a gentle top-to-bottom gradient.
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) frame[y * w + x] = ((x * 37) % 120) + Math.floor(y / 8);
  }
  assert.ok(demouiBarScore(frame, w, h) < DEMOUI_BAR_THRESHOLD);
  for (let y = 500; y < h; y++) frame.fill(20, y * w, (y + 1) * w); // dark panel
  frame.fill(200, 499 * w, 500 * w); // its bright top border
  assert.ok(demouiBarScore(frame, w, h) >= DEMOUI_BAR_THRESHOLD);
});
