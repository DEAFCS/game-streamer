// node --test src/lib/nade-next.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { NEXT_WAIT_MAX_SECONDS, NEXT_WAIT_MIN_SECONDS, nadeNext } from "./nade-next.mjs";

const JOB = { job_id: "render-1", token: "token-1", spec: { lineup_id: "lineup-1" } };

test("a render carries its jobs through untouched", () => {
  assert.deepEqual(nadeNext({ action: "render", jobs: [JOB] }), {
    action: "render",
    map: "",
    seconds: 0,
    jobs: [JOB],
  });
});

// The fields end up in a NUL-separated record and an auth header.
test("a job that could not be filmed or reported is dropped, not passed on", () => {
  const next = nadeNext({
    action: "render",
    jobs: [
      JOB,
      { job_id: "render-2", token: "tok\nen", spec: {} },
      { job_id: "", token: "token-3", spec: {} },
      { job_id: "render-4", token: "token-4" },
      null,
    ],
  });

  assert.deepEqual(next.jobs, [JOB]);
});

test("a render with nothing usable in it asks again instead of stopping", () => {
  assert.equal(nadeNext({ action: "render", jobs: [] }).action, "wait");
  assert.equal(nadeNext({ action: "render" }).action, "wait");
});

test("a map change names a map the client could actually be on", () => {
  assert.deepEqual(nadeNext({ action: "map", map_name: "de_inferno" }), {
    action: "map",
    map: "de_inferno",
    seconds: 0,
    jobs: [],
  });
  assert.equal(nadeNext({ action: "map", map_name: "workshop/3070315843/de_x" }).map, "workshop/3070315843/de_x");
  assert.equal(nadeNext({ action: "map", map_name: "de_x; quit" }).action, "done");
  assert.equal(nadeNext({ action: "map" }).action, "done");
});

test("a wait is held to something a pod can sit out", () => {
  assert.equal(nadeNext({ action: "wait", seconds: 5 }).seconds, 5);
  assert.equal(nadeNext({ action: "wait", seconds: 0 }).seconds, NEXT_WAIT_MIN_SECONDS);
  assert.equal(nadeNext({ action: "wait", seconds: 86400 }).seconds, NEXT_WAIT_MAX_SECONDS);
  assert.equal(nadeNext({ action: "wait", seconds: "soon" }).seconds, NEXT_WAIT_MIN_SECONDS);
});

// An api that has moved on must not leave a pod looping on a queue it cannot
// read: the batch job books whatever is left a pod that can.
test("anything it does not recognise is a stop", () => {
  for (const body of [null, undefined, "done", [], {}, { action: "explode" }, { action: "done" }]) {
    assert.equal(nadeNext(body).action, "done");
  }
});
