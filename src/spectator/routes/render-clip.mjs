import { spawn } from "node:child_process";
import process from "node:process";

import { PORT, SRC_DIR } from "../env.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { bumpActivity, demoState } from "../state/demo.mjs";
import { sendJson } from "../util/http.mjs";

// The render script builds its scratch paths from the job id.
const JOB_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

export async function renderClipHandler(_req, res, body) {
  const jobId   = String(body.job_id ?? "");
  const token   = String(body.token  ?? "");
  const apiBase = String(body.api_base ?? "");
  const outputDims = String(body.output_dims ?? "1920x1080");
  const outputFps  = Math.min(120, Math.max(1, Number.parseInt(body.output_fps, 10) || 60));

  // Multi-segment editor sends `segments`; older callers send a single
  // start_tick/end_tick pair. Normalise to an array.
  let segments = Array.isArray(body.segments) ? body.segments : null;
  if (!segments && body.start_tick != null && body.end_tick != null) {
    segments = [{ start_tick: body.start_tick, end_tick: body.end_tick }];
  }
  const cleaned = (segments ?? [])
    .map((s) => {
      const killTick = Number.parseInt(s?.kill_tick ?? s?.event_tick, 10);
      return {
        start_tick: Number.parseInt(s?.start_tick, 10),
        end_tick:   Number.parseInt(s?.end_tick,   10),
        pov_steam_id: typeof s?.pov_steam_id === "string" ? s.pov_steam_id : null,
        ...(Number.isFinite(killTick) ? { kill_tick: killTick } : {}),
      };
    })
    .filter((s) =>
      Number.isFinite(s.start_tick) &&
      Number.isFinite(s.end_tick) &&
      s.end_tick > s.start_tick,
    );

  if (!jobId || !token || !apiBase || cleaned.length === 0) {
    sendJson(res, 400, {
      error: "job_id, token, api_base, and at least one valid segment required",
    });
    return;
  }
  if (!JOB_ID_PATTERN.test(jobId)) {
    sendJson(res, 400, { error: "job_id must be 1-64 letters, digits, '-' or '_'" });
    return;
  }
  if (!(await findCs2Window())) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const child = spawn("bash", [`${SRC_DIR}/lib/inline-clip-render.sh`], {
    detached: true,
    stdio: ["ignore", "inherit", "inherit"],
    env: {
      ...process.env,
      CLIP_RENDER_JOB_ID: jobId,
      CLIP_RENDER_TOKEN:  token,
      STATUS_API_BASE:    apiBase,
      CLIP_SEGMENTS:      JSON.stringify(cleaned),
      CLIP_OUTPUT_DIMS:   outputDims,
      CLIP_OUTPUT_FPS:    String(outputFps),
      CLIP_TICK_RATE:     String(demoState.tickRate || 64),
      SPEC_SERVER_URL:    `http://127.0.0.1:${PORT}`,
    },
  });
  child.unref();
  bumpActivity();
  sendJson(res, 202, { ok: true, job_id: jobId, pid: child.pid });
  const totalTicks = cleaned.reduce((acc, s) => acc + (s.end_tick - s.start_tick), 0);
  process.stderr.write(
    `[spec-server] render-clip job=${jobId} pid=${child.pid} segments=${cleaned.length} ticks=${totalTicks}\n`,
  );
}
