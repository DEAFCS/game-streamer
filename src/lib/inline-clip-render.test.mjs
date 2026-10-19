// node --test src/lib/inline-clip-render.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = readFileSync(new URL("./inline-clip-render.sh", import.meta.url), "utf8");

// The whole script needs cs2 and a GPU, so these run its own text for the exit trap
// and for everything after the segments are concatenated, with the api, ffmpeg and
// the playback calls stubbed.
function fn(name) {
  const m = SCRIPT.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}$`, "m"));
  assert.ok(m, `${name}() not found in inline-clip-render.sh`);
  return m[0];
}

function tail() {
  const i = SCRIPT.indexOf('\nrm -rf "$SEG_DIR"\n');
  assert.ok(i >= 0, "post-concat cleanup not found in inline-clip-render.sh");
  return SCRIPT.slice(i + 1);
}

function scratch() {
  const root = mkdtempSync(join(tmpdir(), "inline-clip-render-"));
  const clips = join(root, "clips");
  const bin = join(root, "bin");
  mkdirSync(clips);
  mkdirSync(bin);
  const files = {
    segDir: join(clips, "job.segs"),
    chipMov: join(clips, "job-chip.mov"),
    outFile: join(clips, "job.mp4"),
  };
  mkdirSync(files.segDir);
  writeFileSync(join(files.segDir, "seg-000.mp4"), "segment");
  writeFileSync(files.chipMov, "chip");
  writeFileSync(files.outFile, "clip");
  for (const [tool, rc] of [["curl", "${CURL_RC:-0}"], ["ffmpeg", "1"], ["ffprobe", "1"]]) {
    writeFileSync(join(bin, tool), `#!/usr/bin/env bash\nexit ${rc}\n`);
    chmodSync(join(bin, tool), 0o755);
  }
  return { bin, files };
}

function runBash(body, { bin, files }, env = {}) {
  const harness = `set -uo pipefail
say() { :; }
api_status() { :; }
api_progress_settle() { :; }
restart_capture() { :; }
restore_user_playback() { :; }
stop_capture_diag() { :; }
parse_upload_progress() { cat >/dev/null; }
${fn("die_failed")}
CLIP_RENDER_JOB_ID=job
CLIP_RENDER_TOKEN=token
STATUS_API_BASE=http://api.invalid
LIVE_CAPTURE_STOPPED=0
TOTAL_DURATION_TICKS=640
SEG_DIR='${files.segDir}'
CHIP_MOV='${files.chipMov}'
CLIP_OUT_FILE='${files.outFile}'
CLIP_THUMB_FILE='${files.outFile}.jpg'
${body}
`;
  return spawnSync("bash", ["-c", harness], {
    encoding: "utf8",
    env: { ...process.env, ...env, PATH: `${bin}:${process.env.PATH}` },
  });
}

function leftovers({ files }) {
  return Object.values(files).filter((path) => existsSync(path));
}

test("a render that dies before upload leaves no segments, chip or partial clip behind", () => {
  const job = scratch();
  const r = runBash(`${fn("on_exit")}\ntrap on_exit EXIT\nexit 1`, job);
  assert.equal(r.status, 1, r.stderr);
  assert.deepEqual(leftovers(job), []);
});

test("an uploaded clip leaves no chip intermediate behind", () => {
  const job = scratch();
  const r = runBash(tail(), job);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(leftovers(job), []);
});

test("a failed upload removes the rendered clip", () => {
  const job = scratch();
  const r = runBash(tail(), job, { CURL_RC: "7" });
  assert.equal(r.status, 1, r.stderr);
  assert.deepEqual(leftovers(job), []);
});
