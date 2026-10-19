// node --test src/spectator/routes/render-clip.test.mjs
import { before, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import { setTimeout as sleep } from "node:timers/promises";

const root = mkdtempSync(join(tmpdir(), "render-clip-"));
const launches = join(root, "launches");
let renderClipHandler;

// cs2 is "running" (xdotool finds a window) and the render script only records what
// it was launched with.
before(async () => {
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(join(root, "src", "lib"), { recursive: true });
  writeFileSync(join(bin, "xdotool"), "#!/bin/sh\necho 0x1\n");
  chmodSync(join(bin, "xdotool"), 0o755);
  writeFileSync(
    join(root, "src", "lib", "inline-clip-render.sh"),
    `printf '%s %s\\n' "$CLIP_RENDER_JOB_ID" "$CLIP_OUTPUT_FPS" >>"${launches}"\n`,
  );
  Object.assign(process.env, {
    LOG_DIR: root,
    SRC_DIR: join(root, "src"),
    PATH: `${bin}:${process.env.PATH}`,
  });
  ({ renderClipHandler } = await import("./render-clip.mjs"));
});

async function render(fields) {
  const res = {
    writeHead(status) { this.status = status; },
    end(body) { this.body = JSON.parse(body); },
  };
  await renderClipHandler(null, res, {
    token: "token",
    api_base: "http://api.invalid",
    segments: [{ start_tick: 100, end_tick: 740 }],
    ...fields,
  });
  return res;
}

async function launchedFps(jobId) {
  for (let i = 0; i < 100; i++) {
    const line = existsSync(launches)
      ? readFileSync(launches, "utf8").split("\n").find((l) => l.startsWith(`${jobId} `))
      : undefined;
    if (line) {
      return line.slice(jobId.length + 1);
    }
    await sleep(50);
  }
  return null;
}

test("the api's job ids launch a render", async () => {
  const res = await render({ job_id: "0b8c5a52-6f0e-4d1e-9a51-3c2f4e7d9b10", output_fps: 60 });
  assert.equal(res.status, 202);
  assert.equal(await launchedFps("0b8c5a52-6f0e-4d1e-9a51-3c2f4e7d9b10"), "60");
});

test("a job id that could leave the clips dir is refused before anything launches", async () => {
  for (const jobId of ["../../../opt/game-streamer/resources/video/outro_1920x1080_60", "a/b", "a b", "x".repeat(65)]) {
    const res = await render({ job_id: jobId, output_fps: 60 });
    assert.equal(res.status, 400, jobId);
  }
});

test("output_fps is clamped to 1..120 and defaults to 60", async () => {
  for (const [jobId, outputFps, expected] of [
    ["fps-30", 30, "30"],
    ["fps-huge", 100000, "120"],
    ["fps-negative", -5, "1"],
    ["fps-missing", undefined, "60"],
  ]) {
    const res = await render({ job_id: jobId, output_fps: outputFps });
    assert.equal(res.status, 202, jobId);
    assert.equal(await launchedFps(jobId), expected, jobId);
  }
});
