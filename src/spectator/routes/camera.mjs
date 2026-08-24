import process from "node:process";

import { gsiState } from "../state/gsi.mjs";
import { sendJson } from "../util/http.mjs";
import { STATUS_API_BASE } from "../env.mjs";

// Streamer-facing camera overlay: hud-manager/camera-overlay.js (running
// inside the HUD's Electron overlay window) polls GET /camera/state to
// find out who's currently spectated, then WHEP-pulls their feed
// through POST /camera/:steamId/whep, which we proxy on to api-deafcs's
// StreamerCameraController with the same x-origin-auth scheme every
// other game-streamer <-> api call already uses.
//
// This route doesn't need to know or care whether
// match_options.streamer_camera_enabled is actually on, or whether the
// player has published anything -- api-deafcs's endpoint enforces both
// and just 400s if not, which the overlay's own retry/backoff already
// handles quietly (see camera-overlay.js). Deliberately separate from
// the "camera required" anti-cheat feature (api-deafcs's
// CameraService/CameraController) -- no shared code, no shared MediaMTX
// path, no shared toggle. See DEAFCS/deafcs-web#91.

export async function cameraStateHandler(_req, res) {
  sendJson(res, 200, {
    enabled: !!gsiState.spectatedSteamId,
    steam_id: gsiState.spectatedSteamId,
  });
}

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export async function cameraWhepHandler(req, res, steamId) {
  const matchId = process.env.MATCH_ID;
  const matchPassword = process.env.MATCH_PASSWORD;

  if (!STATUS_API_BASE || !matchId || !matchPassword) {
    res.writeHead(503, { "Content-Type": "text/plain" });
    res.end("camera broadcast not configured");
    return;
  }
  if (!/^\d{17}$/.test(steamId)) {
    res.writeHead(400, { "Content-Type": "text/plain" });
    res.end("invalid steamId");
    return;
  }

  const sdp = await readRawBody(req);
  let upstream;
  try {
    upstream = await fetch(
      `${STATUS_API_BASE.replace(/\/$/, "")}/matches/streamer-camera/${matchId}/broadcast/${steamId}/whep`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/sdp",
          "x-origin-auth": `${matchId}:${matchPassword}`,
        },
        body: sdp,
        signal: AbortSignal.timeout(10_000),
      },
    );
  } catch (err) {
    res.writeHead(502, { "Content-Type": "text/plain" });
    res.end(`camera broadcast unreachable: ${err?.message ?? err}`);
    return;
  }

  const text = await upstream.text();
  res.writeHead(upstream.status, { "Content-Type": "application/sdp" });
  res.end(text);
}
