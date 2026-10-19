// node --test src/lib/clip-helpers.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const HELPERS = new URL("./clip-helpers.mjs", import.meta.url).pathname;

function run(subcmd, rounds) {
  const path = join(mkdtempSync(join(tmpdir(), "clip-helpers-")), "round-ticks.json");
  writeFileSync(path, JSON.stringify(rounds));
  return execFileSync("node", [HELPERS, subcmd, path], { encoding: "utf8" });
}

// A Rush demo recorded without playcast: gameover at tick 15163, but the server kept
// recording for tv_delay, so the file runs to tick 22523.
const RUSH_ROUNDS = [
  { round: 1, start_tick: 75, freeze_end_tick: 1194, end_tick: 2796, winner: "t", reason: 9 },
  { round: 2, start_tick: 2796, freeze_end_tick: 3500, end_tick: 5181, winner: "t", reason: 9 },
  { round: 3, start_tick: 5181, freeze_end_tick: 5885, end_tick: 8528, winner: "ct", reason: 8 },
  { round: 4, start_tick: 8528, freeze_end_tick: 9232, end_tick: 10714, winner: "t", reason: 9 },
  { round: 5, start_tick: 10714, freeze_end_tick: 11418, end_tick: 13399, winner: "t", reason: 9 },
  { round: 6, start_tick: 13399, freeze_end_tick: 14103, end_tick: 15482, winner: "t", reason: 9 },
];

test("the match ends with its decided final round, not at the demo's last tick", () => {
  assert.equal(run("rounds-match-end-tick", RUSH_ROUNDS), "15482");
});

test("a demo cut off mid-round has no match end", () => {
  const cut = [...RUSH_ROUNDS.slice(0, 5), { round: 6, start_tick: 13399, end_tick: 13650 }];
  assert.equal(run("rounds-match-end-tick", cut), "");
});

test("no round ticks means no match end", () => {
  assert.equal(run("rounds-match-end-tick", []), "");
});

test("the last end tick is still the highest one", () => {
  assert.equal(run("rounds-last-end-tick", RUSH_ROUNDS), "15482");
});
