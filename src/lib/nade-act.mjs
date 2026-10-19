// How the render pod acts a lineup's throw out with its own keys. The flight
// is not decided here: the practice plugin snaps the projectile to the recorded
// seed the moment it exists. This only makes the throw LOOK like the lineup --
// the run-up, right click for a lob, a jump for a jump throw.

const JUMP_TECHNIQUES = new Set(["jump", "runjump", "walkjump", "crouchjump"]);
const CROUCH_TECHNIQUES = new Set(["crouch", "crouchjump"]);

export const TICK_MS = 1000 / 64;
export const MAX_RUN_UP_MS = 2000;
export const DEFAULT_PIN_PULL_MS = 600;
export const DEFAULT_AFTER_MS = 150;

const MIN_HOLD_TICKS = 2;
const JUMP_AT_RELEASE_MS = 2 * TICK_MS + 1;

// CS2 InputBitMask_t, the low 32 bits of ButtonStates[0].
export const IN = {
  ATTACK: 1 << 0,
  JUMP: 1 << 1,
  DUCK: 1 << 2,
  FORWARD: 1 << 3,
  BACK: 1 << 4,
  MOVELEFT: 1 << 9,
  MOVERIGHT: 1 << 10,
  SPEED: 1 << 16,
};

// cs2 walks on +sprint, which is what sets IN_SPEED; +speed is CS:GO's name.
const STANCE_KEYS = [
  [IN.SPEED, "sprint"],
  [IN.DUCK, "duck"],
];
const MOVE_KEYS = [
  [IN.FORWARD, "forward"],
  [IN.BACK, "back"],
  [IN.MOVELEFT, "moveleft"],
  [IN.MOVERIGHT, "moveright"],
];

const SAMPLE_NUMBERS = ["t", "x", "y", "z", "vx", "vy", "vz", "pitch", "yaw", "buttons"];
const SAMPLE_FLAGS = ["on_ground", "ducked"];

function lower(value) {
  return String(value ?? "").trim().toLowerCase();
}

function grip(strength) {
  switch (lower(strength)) {
    case "half":
      return ["attack", "attack2"];
    case "drop":
      return ["attack2"];
    default:
      return ["attack"];
  }
}

export function nadeActKeys({ technique, strength, jumpBind } = {}) {
  const tech = lower(technique);
  const hold = grip(strength);
  const crouch = CROUCH_TECHNIQUES.has(tech);
  const jump = jumpBind === true || JUMP_TECHNIQUES.has(tech);

  const press = [...(crouch ? ["+duck"] : []), ...hold.map((key) => `+${key}`)];
  const release = [...(jump ? ["+jump"] : []), ...hold.map((key) => `-${key}`)];
  const after = [...(jump ? ["-jump"] : []), ...(crouch ? ["-duck"] : [])];

  return {
    press: press.join("; "),
    release: release.join("; "),
    after: after.join("; "),
  };
}

// Whole or nothing, the plugin's own rule (UtilityApproachPoint.ToSamples):
// it stages at the run-up's start only when every sample is complete, so a run-up
// it threw away must not be walked from the stance.
function runUp(approach) {
  if (!Array.isArray(approach)) {
    return null;
  }

  const samples = [];
  for (const sample of approach) {
    if (
      sample === null
      || typeof sample !== "object"
      || !SAMPLE_NUMBERS.every((key) => Number.isFinite(sample[key]))
      || !SAMPLE_FLAGS.every((key) => typeof sample[key] === "boolean")
      || sample.t > 0
      || (samples.length > 0 && sample.t <= samples[samples.length - 1].t)
    ) {
      return null;
    }
    samples.push({ t: sample.t, buttons: sample.buttons });
  }

  const window = samples.filter((sample) => sample.t >= -MAX_RUN_UP_MS);

  return window.length >= 2 ? window : null;
}

function held(samples, bit) {
  return samples.map((sample) => (sample.buttons & bit) !== 0);
}

function steady(samples, states) {
  const runs = [];
  states.forEach((state, index) => {
    const last = runs[runs.length - 1];
    if (last && last.state === state) {
      last.end = index;
    } else {
      runs.push({ state, start: index, end: index });
    }
  });

  const out = [...states];
  let previous = null;
  runs.forEach((run, index) => {
    const ticks = Math.round((samples[run.end].t - samples[run.start].t) / TICK_MS) + 1;
    let state = run.state;
    if (ticks < MIN_HOLD_TICKS) {
      state = previous ?? runs[index + 1]?.state ?? run.state;
    }
    out.fill(state, run.start, run.end + 1);
    previous = state;
  });

  return out;
}

function steps(commands, at) {
  return commands
    .split(";")
    .map((cmd) => cmd.trim())
    .filter(Boolean)
    .map((cmd) => ({ at, cmd }));
}

function milliseconds(value, fallback) {
  const parsed = Number.parseInt(value, 10);

  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

// Every step is ONE console action at `at` ms after the pin pull starts. Steps
// sharing an offset go in array order.
export function nadeActTimeline({
  approach,
  technique,
  strength,
  jumpBind,
  pinPullMs = DEFAULT_PIN_PULL_MS,
  afterMs = DEFAULT_AFTER_MS,
} = {}) {
  const pin = milliseconds(pinPullMs, DEFAULT_PIN_PULL_MS);
  const after = milliseconds(afterMs, DEFAULT_AFTER_MS);
  const samples = runUp(approach);

  if (!samples) {
    const keys = nadeActKeys({ technique, strength, jumpBind });

    return [
      ...steps(keys.press, 0),
      ...steps(keys.release, pin),
      ...steps(keys.after, pin + after),
    ];
  }

  const tech = lower(technique);
  const hold = grip(strength);
  const first = samples[0].t;
  const offset = (t) => pin + Math.round(t - first);
  const releaseAt = offset(0);
  const last = samples.length - 1;

  const keys = [...STANCE_KEYS, ...MOVE_KEYS].map(([bit, name]) => ({
    name,
    stance: STANCE_KEYS.some(([stanceBit]) => stanceBit === bit),
    states: steady(samples, held(samples, bit)),
  }));
  const duck = keys.find((key) => key.name === "duck");
  if (!duck.states.some(Boolean) && CROUCH_TECHNIQUES.has(tech)) {
    duck.states = samples.map(() => true);
  }

  const timeline = [];
  for (const key of keys.filter((key) => key.stance && key.states[0])) {
    timeline.push({ at: 0, cmd: `+${key.name}` });
  }
  timeline.push(...hold.map((name) => ({ at: 0, cmd: `+${name}` })));
  for (const key of keys.filter((key) => !key.stance && key.states[0])) {
    timeline.push({ at: offset(first), cmd: `+${key.name}` });
  }

  const jumping = held(samples, IN.JUMP);
  let jumpAtRelease = false;
  let jumpHeld = false;
  let jumped = false;

  samples.forEach((sample, index) => {
    if (index > 0) {
      for (const key of keys) {
        if (key.states[index] !== key.states[index - 1]) {
          timeline.push({
            at: offset(sample.t),
            cmd: `${key.states[index] ? "+" : "-"}${key.name}`,
          });
        }
      }
    }

    // Never smoothed: a scroll-wheel jump is down for one tick.
    const rising = jumping[index] && (index === 0 || !jumping[index - 1]);
    const falling = index > 0 && !jumping[index] && jumping[index - 1];
    if (falling && jumpHeld) {
      timeline.push({ at: offset(sample.t), cmd: "-jump" });
      jumpHeld = false;
    }
    if (!rising) {
      return;
    }
    jumped = true;
    if (-sample.t <= JUMP_AT_RELEASE_MS) {
      jumpAtRelease = true;
      return;
    }
    timeline.push({ at: offset(sample.t), cmd: "+jump" });
    jumpHeld = true;
  });

  if (!jumped && (jumpBind === true || JUMP_TECHNIQUES.has(tech))) {
    jumpAtRelease = true;
  }

  if (jumpAtRelease) {
    timeline.push({ at: releaseAt, cmd: "+jump" });
  }
  timeline.push(...hold.map((name) => ({ at: releaseAt, cmd: `-${name}` })));

  const up = releaseAt + after;
  if (jumpAtRelease || jumpHeld) {
    timeline.push({ at: up, cmd: "-jump" });
  }
  for (const key of [...keys.filter((key) => !key.stance), ...keys.filter((key) => key.stance)]) {
    if (key.states[last]) {
      timeline.push({ at: up, cmd: `-${key.name}` });
    }
  }

  return timeline
    .map((step, index) => ({ ...step, index }))
    .sort((a, b) => a.at - b.at || a.index - b.index)
    .map(({ at, cmd }) => ({ at, cmd }));
}
