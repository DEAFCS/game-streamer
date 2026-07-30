import process from "node:process";

import { readJsonBody, sendJson } from "../util/http.mjs";

import { healthHandler } from "./health.mjs";
import { demoStateHandler } from "./demo-state.mjs";
import {
  captureFieldsHandler,
  povStateHandler,
  seekStateHandler,
} from "./capture-fields.mjs";
import { gsiHandler } from "./gsi.mjs";
import {
  autodirectorHandler,
  clickHandler,
  hudHandler,
  hudModeHandler,
  hudReloadHandler,
  hudSidesHandler,
  jumpHandler,
  playerHandler,
  slotHandler,
  specScoreboardHandler,
  specXrayHandler,
} from "./spec.mjs";
import {
  demouiHandler,
  execHandler,
  pauseHandler,
  reloadHandler,
  resumeHandler,
  roundHandler,
  seekHandler,
  skipHandler,
  speedHandler,
  toggleHandler,
  xrayHandler,
} from "./demo.mjs";
import { renderClipHandler } from "./render-clip.mjs";
import { switchMatchHandler } from "./switch-match.mjs";
import { reconnectHandler } from "./reconnect.mjs";
import { skipShadersHandler } from "./skip-shaders.mjs";

const HEALTH_GET_URLS = new Set(["/", "/health", "/spec/health"]);

const ROUTES = new Map([
  ["GET /demo/state", demoStateHandler],
  ["GET /demo/capture-fields", captureFieldsHandler],
  ["GET /demo/pov-state", povStateHandler],
  ["GET /demo/seek-state", seekStateHandler],
  ["POST /gsi", gsiHandler],

  ["POST /spec/click",        clickHandler],
  ["POST /spec/jump",         jumpHandler],
  ["POST /spec/player",       playerHandler],
  ["POST /spec/slot",         slotHandler],
  ["POST /spec/autodirector", autodirectorHandler],
  ["POST /spec/hud",          hudHandler],
  ["POST /spec/hud-mode",     hudModeHandler],
  ["POST /spec/hud-reload",   hudReloadHandler],
  ["POST /spec/hud-sides",    hudSidesHandler],
  ["POST /spec/switch-match", switchMatchHandler],
  ["POST /spec/reconnect",    reconnectHandler],
  ["POST /spec/skip-shaders", skipShadersHandler],
  ["POST /spec/xray",         specXrayHandler],
  ["POST /spec/scoreboard",   specScoreboardHandler],

  ["POST /demo/toggle",      toggleHandler],
  ["POST /demo/pause",       pauseHandler],
  ["POST /demo/resume",      resumeHandler],
  ["POST /demo/seek",        seekHandler],
  ["POST /demo/skip",        skipHandler],
  ["POST /demo/speed",       speedHandler],
  ["POST /demo/reload",      reloadHandler],
  ["POST /demo/xray",        xrayHandler],
  ["POST /demo/demoui",      demouiHandler],
  ["POST /demo/round",       roundHandler],
  ["POST /demo/exec",        execHandler],
  ["POST /demo/render-clip", renderClipHandler],
]);

export async function dispatch(req, res) {
  const method = req.method ?? "GET";
  const url    = req.url ?? "/";

  try {
    if (method === "OPTIONS") { sendJson(res, 204, {}); return; }

    if (method === "GET" && HEALTH_GET_URLS.has(url)) {
      await healthHandler(req, res, {});
      logResponse(method, url, res);
      return;
    }

    // Route on the path only — /demo/capture-fields carries a query string.
    const qIdx = url.indexOf("?");
    const path = qIdx >= 0 ? url.slice(0, qIdx) : url;
    const handler = ROUTES.get(`${method} ${path}`);
    if (!handler) {
      sendJson(res, 404, { error: "not found" });
      logResponse(method, path, res);
      return;
    }

    let body = {};
    if (method !== "GET") {
      try { body = await readJsonBody(req); }
      catch {
        sendJson(res, 400, { error: "invalid json" });
        logResponse(method, url, res);
        return;
      }
    }
    await handler(req, res, body);
    logResponse(method, path, res);
  } catch (err) {
    process.stderr.write(`[spec-server] handler threw ${(err && err.stack) || err}\n`);
    if (!res.headersSent) sendJson(res, 500, { error: "internal" });
  }
}

// These endpoints are polled at high frequency by upstream consumers
// (gsi: cs2 @10Hz, demo/state: web scrubber @1Hz, capture-fields: clip
// loop @~6Hz). Their handlers log state transitions themselves;
// per-request lines just drown the log.
const QUIET_URLS = new Set([
  "/gsi", "/demo/state", "/demo/capture-fields", "/demo/pov-state",
  "/demo/seek-state",
]);

function logResponse(method, url, res) {
  if (QUIET_URLS.has(url)) return;
  process.stderr.write(`[spec-server] ${method} ${url} -> ${res.statusCode}\n`);
}
