// node --test src/lib/nade-act.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { IN, TICK_MS, nadeActKeys, nadeActTimeline } from "./nade-act.mjs";

// Shaped like the api's spec.approach: 64Hz, whole ms relative to the release,
// rounded the way ApproachUtility.Milliseconds rounds.
function approach(buttons) {
  const last = buttons.length - 1;
  return buttons.map((held, index) => ({
    t: -Math.round((last - index) * TICK_MS),
    x: 10 + index * 3.9,
    y: 20,
    z: 30,
    vx: 250,
    vy: -12.5,
    vz: 0,
    pitch: -3.5,
    yaw: 90,
    buttons: held,
    on_ground: true,
    ducked: (held & IN.DUCK) !== 0,
  }));
}

function repeat(value, count) {
  return Array.from({ length: count }, () => value);
}

function line(timeline) {
  return timeline.map(({ at, cmd }) => `${at} ${cmd}`);
}

test("a standing left click is the default", () => {
  assert.deepEqual(nadeActKeys({ technique: "Stationary", strength: "Full" }), {
    press: "+attack",
    release: "-attack",
    after: "",
  });
  assert.deepEqual(nadeActKeys(), nadeActKeys({ strength: "Full" }));
});

test("throw strength picks the mouse buttons", () => {
  assert.equal(nadeActKeys({ strength: "Half" }).press, "+attack; +attack2");
  assert.equal(nadeActKeys({ strength: "Half" }).release, "-attack; -attack2");
  assert.equal(nadeActKeys({ strength: "Drop" }).press, "+attack2");
});

test("a jump throw jumps on the same frame the grenade is let go", () => {
  const keys = nadeActKeys({ technique: "Jump", strength: "Full" });

  assert.equal(keys.release, "+jump; -attack");
  assert.equal(keys.after, "-jump");
});

test("a jump-throw bind jumps whatever the technique says", () => {
  assert.equal(
    nadeActKeys({ technique: "Stationary", jumpBind: true }).release,
    "+jump; -attack",
  );
});

test("a crouch throw is crouched before the pin comes out", () => {
  const keys = nadeActKeys({ technique: "CrouchJump", strength: "Drop" });

  assert.equal(keys.press, "+duck; +attack2");
  assert.equal(keys.release, "+jump; -attack2");
  assert.equal(keys.after, "-jump; -duck");
});

test("a stationary throw is the press, the pin pull, the release and the key-ups", () => {
  assert.deepEqual(line(nadeActTimeline({ technique: "Stationary", strength: "Full" })), [
    "0 +attack",
    "600 -attack",
  ]);
  assert.deepEqual(
    line(nadeActTimeline({ technique: "CrouchJump", strength: "Drop", approach: null })),
    ["0 +duck", "0 +attack2", "600 +jump", "600 -attack2", "750 -jump", "750 -duck"],
  );
});

test("without a usable run-up every throw is acted exactly as nadeActKeys says", () => {
  const split = (keys) => keys.split(";").map((key) => key.trim()).filter(Boolean);
  const oneSample = approach([1024]);
  const holed = approach(repeat(1024, 8));
  delete holed[3].vx;
  const backwards = approach(repeat(1024, 8));
  backwards[5].t = backwards[2].t;

  for (const technique of ["Stationary", "Jump", "RunJump", "Crouch", "CrouchJump", ""]) {
    for (const strength of ["Full", "Half", "Drop", null]) {
      for (const jumpBind of [true, false]) {
        const keys = nadeActKeys({ technique, strength, jumpBind });
        const expected = [
          ...split(keys.press).map((cmd) => `0 ${cmd}`),
          ...split(keys.release).map((cmd) => `600 ${cmd}`),
          ...split(keys.after).map((cmd) => `750 ${cmd}`),
        ];

        for (const run of [undefined, null, [], "[]", oneSample, holed, backwards]) {
          assert.deepEqual(
            line(nadeActTimeline({ approach: run, technique, strength, jumpBind })),
            expected,
            `${technique}/${strength}/${jumpBind}`,
          );
        }
      }
    }
  }
});

test("holding D into a jump throw strafes after the pin pull and jumps on the release", () => {
  const run = approach([...repeat(IN.MOVERIGHT, 24), ...repeat(IN.MOVERIGHT | IN.JUMP, 2)]);

  assert.equal(run[0].t, -391);
  assert.deepEqual(line(nadeActTimeline({ approach: run, technique: "RunJump", strength: "Full" })), [
    "0 +attack",
    "600 +moveright",
    "991 +jump",
    "991 -attack",
    "1141 -jump",
    "1141 -moveright",
  ]);
});

test("the recorded attack button does not move the release off t=0", () => {
  const plain = approach([...repeat(IN.MOVERIGHT, 24), ...repeat(IN.MOVERIGHT | IN.JUMP, 2)]);
  const pinned = approach([
    ...repeat(IN.MOVERIGHT | IN.ATTACK, 24),
    ...repeat(IN.MOVERIGHT | IN.JUMP, 2),
  ]);

  assert.deepEqual(
    nadeActTimeline({ approach: pinned, strength: "Full" }),
    nadeActTimeline({ approach: plain, strength: "Full" }),
  );
});

test("a run-up that starts from a standstill moves when the recording did", () => {
  const run = approach([...repeat(0, 10), ...repeat(IN.MOVERIGHT, 14), ...repeat(IN.MOVERIGHT | IN.JUMP, 2)]);
  const timeline = nadeActTimeline({ approach: run, strength: "Full", jumpBind: true });

  assert.deepEqual(line(timeline), [
    "0 +attack",
    `${600 + run[10].t - run[0].t} +moveright`,
    "991 +jump",
    "991 -attack",
    "1141 -jump",
    "1141 -moveright",
  ]);
});

test("the pin pull is the configured time before the run-up starts", () => {
  const run = approach(repeat(IN.FORWARD, 20));
  const timeline = nadeActTimeline({ approach: run, strength: "Half", pinPullMs: "800" });

  assert.deepEqual(line(timeline), [
    "0 +attack",
    "0 +attack2",
    "800 +forward",
    "1097 -attack",
    "1097 -attack2",
    "1247 -forward",
  ]);
});

test("a crouch run is crouched before the pin comes out and stays crouched", () => {
  const run = approach(repeat(IN.FORWARD | IN.DUCK, 20));

  assert.deepEqual(line(nadeActTimeline({ approach: run, technique: "Crouch", strength: "Full" })), [
    "0 +duck",
    "0 +attack",
    "600 +forward",
    "897 -attack",
    "1047 -forward",
    "1047 -duck",
  ]);
});

test("a crouch pressed mid-run is pressed when the recording pressed it", () => {
  const run = approach([...repeat(IN.FORWARD, 10), ...repeat(IN.FORWARD | IN.DUCK, 10)]);

  assert.deepEqual(line(nadeActTimeline({ approach: run, technique: "Crouch", strength: "Full" })), [
    "0 +attack",
    "600 +forward",
    `${600 + run[10].t - run[0].t} +duck`,
    "897 -attack",
    "1047 -forward",
    "1047 -duck",
  ]);
});

test("a crouch technique with no recorded crouch still crouches the whole throw", () => {
  const run = approach(repeat(IN.FORWARD, 20));

  assert.deepEqual(line(nadeActTimeline({ approach: run, technique: "Crouch" })), [
    "0 +duck",
    "0 +attack",
    "600 +forward",
    "897 -attack",
    "1047 -forward",
    "1047 -duck",
  ]);
});

test("a walk holds the walk key from before the pin pull", () => {
  const run = approach(repeat(IN.FORWARD | IN.SPEED, 20));

  assert.deepEqual(line(nadeActTimeline({ approach: run })), [
    "0 +sprint",
    "0 +attack",
    "600 +forward",
    "897 -attack",
    "1047 -forward",
    "1047 -sprint",
  ]);
});

test("single-tick button blips are not acted", () => {
  const buttons = repeat(IN.FORWARD, 30);
  buttons[0] = 0;
  buttons[6] = 0;
  buttons[12] = IN.FORWARD | IN.MOVELEFT;
  buttons[18] = 0;
  buttons[20] = IN.FORWARD | IN.BACK;
  buttons[29] = 0;
  const run = approach(buttons);

  assert.deepEqual(line(nadeActTimeline({ approach: run })), [
    "0 +attack",
    "600 +forward",
    `${600 - run[0].t} -attack`,
    `${750 - run[0].t} -forward`,
  ]);
});

test("a two-tick tap is a real press", () => {
  const buttons = repeat(IN.FORWARD, 30);
  buttons[10] = IN.FORWARD | IN.MOVELEFT;
  buttons[11] = IN.FORWARD | IN.MOVELEFT;
  const run = approach(buttons);

  assert.deepEqual(line(nadeActTimeline({ approach: run })), [
    "0 +attack",
    "600 +forward",
    `${600 + run[10].t - run[0].t} +moveleft`,
    `${600 + run[12].t - run[0].t} -moveleft`,
    `${600 - run[0].t} -attack`,
    `${750 - run[0].t} -forward`,
  ]);
});

test("a one-tick jump early in the run-up is a scroll-wheel jump and is kept", () => {
  const buttons = repeat(IN.FORWARD, 30);
  buttons[5] = IN.FORWARD | IN.JUMP;
  const run = approach(buttons);

  assert.deepEqual(line(nadeActTimeline({ approach: run, technique: "RunJump" })), [
    "0 +attack",
    "600 +forward",
    `${600 + run[5].t - run[0].t} +jump`,
    `${600 + run[6].t - run[0].t} -jump`,
    `${600 - run[0].t} -attack`,
    `${750 - run[0].t} -forward`,
  ]);
});

test("only the last two seconds of a run-up are acted", () => {
  const run = approach(repeat(IN.MOVERIGHT, 200));
  const timeline = nadeActTimeline({ approach: run });
  const kept = run.find((sample) => sample.t >= -2000);

  assert.ok(run[0].t < -3000);
  assert.deepEqual(line(timeline), [
    "0 +attack",
    "600 +moveright",
    `${600 - kept.t} -attack`,
    `${750 - kept.t} -moveright`,
  ]);
  assert.ok(Math.max(...timeline.map((step) => step.at)) <= 600 + 2000 + 150);
});

test("every step is a single action", () => {
  const run = approach([
    ...repeat(IN.FORWARD | IN.SPEED | IN.DUCK, 10),
    ...repeat(IN.MOVERIGHT | IN.DUCK, 10),
    ...repeat(IN.MOVERIGHT | IN.JUMP, 2),
  ]);

  for (const step of nadeActTimeline({ approach: run, strength: "Half", jumpBind: true })) {
    assert.match(step.cmd, /^[+-][a-z0-9]+$/);
    assert.ok(Number.isInteger(step.at) && step.at >= 0);
  }
});
