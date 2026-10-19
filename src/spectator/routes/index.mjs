import process from "node:process";

import { SPEC_SERVER_TOKEN } from "../env.mjs";
import { bearerToken, fromLoopback, tokenMatches } from "../util/auth.mjs";
import { readJsonBody, sendBodyError, sendJson } from "../util/http.mjs";

import { healthHandler } from "./health.mjs";
import { demoStateHandler } from "./demo-state.mjs";
import {
  captureFieldsHandler,
  povStateHandler,
  seekStateHandler,
} from "./capture-fields.mjs";
import { demouiScoreHandler } from "./demoui.mjs";
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
  specFocusHandler,
  specScoreboardHandler,
  specXrayHandler,
} from "./spec.mjs";
import {
  demouiHandler,
  execHandler,
  pauseHandler,
  reloadHandler,
  resetSessionHandler,
  resumeHandler,
  roundHandler,
  seekHandler,
  skipHandler,
  speedHandler,
  toggleHandler,
  xrayHandler,
} from "./demo.mjs";
import { nadeSelfHandler } from "./nade-self.mjs";
import { renderClipHandler } from "./render-clip.mjs";
import { switchMatchHandler } from "./switch-match.mjs";
import { reconnectHandler } from "./reconnect.mjs";
import { skipShadersHandler } from "./skip-shaders.mjs";
import { cameraStateHandler, cameraWhepHandler } from "./camera.mjs";

const HEALTH_GET_URLS = new Set(["/", "/health", "/spec/health"]);

const WHEP_PATH = /^\/camera\/\d{17}\/whep$/;

// The HUD overlay is a browser page that third-party HUD code shares, so it is
// never handed the token; its camera calls are taken from loopback alone.
// Loopback still reaches every hostNetwork pod on the node, game servers
// included, so nothing else may be exempt.
const LOOPBACK_ROUTES = new Set(["GET /camera/state", "POST /camera/whep"]);

// cs2 cannot set a header on its GSI posts; the token rides in the body's
// auth block instead, from the gamestate_integration cfg.
const GSI_ROUTE = "POST /gsi";

function refusal(req, route) {
  if (!SPEC_SERVER_TOKEN || route === GSI_ROUTE) {
    return null;
  }
  if (LOOPBACK_ROUTES.has(route)) {
    return fromLoopback(req) ? null : { status: 403, error: "loopback only" };
  }
  return tokenMatches(SPEC_SERVER_TOKEN, bearerToken(req))
    ? null
    : { status: 401, error: "unauthorized" };
}

function gsiRefused(body) {
  return SPEC_SERVER_TOKEN !== null && !tokenMatches(SPEC_SERVER_TOKEN, body.auth?.token);
}

const ROUTES = new Map([
  ["GET /spec/focus", specFocusHandler],
  ["GET /camera/state", cameraStateHandler],
  ["GET /demo/state", demoStateHandler],
  ["GET /demo/capture-fields", captureFieldsHandler],
  ["GET /demo/pov-state", povStateHandler],
  ["GET /demo/seek-state", seekStateHandler],
  ["GET /demo/demoui-score", demouiScoreHandler],
  ["GET /nade/self", nadeSelfHandler],
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
  ["POST /demo/reset-session", resetSessionHandler],
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

    // Route on the path only — /demo/capture-fields carries a query string.
    const qIdx = url.indexOf("?");
    const path = qIdx >= 0 ? url.slice(0, qIdx) : url;
    const whep = method === "POST" && WHEP_PATH.test(path);
    const route = whep ? "POST /camera/whep" : `${method} ${path}`;

    const refused = refusal(req, route);
    if (refused) {
      sendJson(res, refused.status, { error: refused.error });
      logResponse(method, path, res);
      return;
    }

    if (method === "GET" && HEALTH_GET_URLS.has(url)) {
      await healthHandler(req, res, {});
      logResponse(method, url, res);
      return;
    }

    // Handled ahead of the table: the steam id is a path segment, and the body
    // is application/sdp rather than the JSON every other route expects.
    if (whep) {
      await cameraWhepHandler(req, res);
      logResponse(method, path, res);
      return;
    }

    const handler = ROUTES.get(route);
    if (!handler) {
      sendJson(res, 404, { error: "not found" });
      logResponse(method, path, res);
      return;
    }

    let body = {};
    if (method !== "GET") {
      try { body = await readJsonBody(req); }
      catch (err) {
        sendBodyError(req, res, err);
        logResponse(method, url, res);
        return;
      }
    }
    if (route === GSI_ROUTE && gsiRefused(body)) {
      sendJson(res, 401, { error: "unauthorized" });
      return;
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
  "/demo/seek-state", "/demo/demoui-score",
  // Polled every second by the nade render pod's session gate.
  "/nade/self",
  // Polled by the HUD overlay to follow the spectated player.
  "/camera/state",
]);

function logResponse(method, url, res) {
  if (QUIET_URLS.has(url)) return;
  process.stderr.write(`[spec-server] ${method} ${url} -> ${res.statusCode}\n`);
}
