import process from "node:process";

import { gsiState } from "../state/gsi.mjs";
import { sendJson, CORS_HEADERS } from "../util/http.mjs";

// Streamer-facing camera overlay: hud-manager/camera-overlay.js (running
// inside the HUD's Electron overlay window) polls GET /camera/state to
// find out who's currently spectated, then GET /camera/:steamId/snapshot
// to get a JPEG of their live feed, which we proxy on to the
// streamer-camera-snapshotter service.
//
// This used to be a real WHEP-to-WHEP relay all the way through to
// api-deafcs, with the game-streamer pod itself acting as a WebRTC
// client -- reverted after live debugging on an actual deployment
// showed that specific pod's network (a laptop on a university network,
// reachable only over a VPN tunnel) consistently could not complete a
// WebRTC/DTLS handshake to *any* destination, direct or TURN-relayed,
// while every other client (including a real external viewer against
// the exact same media server) connected fine. Plain HTTPS image
// polling sidesteps the problem entirely: the game-streamer pod already
// proves out plain HTTP works fine on this same network path (every
// other spec-server <-> api-deafcs call already does). See
// DEAFCS/deafcs-web#91.
//
// This route doesn't need to know or care whether
// match_options.streamer_camera_enabled is actually on, or whether the
// player has published anything -- the snapshotter just 404s if there's
// no live frame, which the client's own retry/backoff already handles
// quietly. Deliberately separate from the "camera required" anti-cheat
// feature -- no shared code, no shared MediaMTX path, no shared toggle.

const SNAPSHOTTER_BASE =
  process.env.SNAPSHOTTER_BASE || "http://streamer-camera-snapshotter:8080";

export async function cameraStateHandler(_req, res) {
  sendJson(res, 200, {
    enabled: !!gsiState.spectatedSteamId,
    steam_id: gsiState.spectatedSteamId,
  });
}

export async function cameraSnapshotHandler(_req, res, steamId) {
  const matchId = process.env.MATCH_ID;
  if (!matchId) {
    res.writeHead(503, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end("camera snapshot not configured");
    return;
  }
  if (!/^\d{17}$/.test(steamId)) {
    res.writeHead(400, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end("invalid steamId");
    return;
  }

  let upstream;
  try {
    upstream = await fetch(
      `${SNAPSHOTTER_BASE.replace(/\/$/, "")}/snapshot/${matchId}/${steamId}`,
      { signal: AbortSignal.timeout(5_000) },
    );
  } catch (err) {
    res.writeHead(502, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end(`snapshotter unreachable: ${err?.message ?? err}`);
    return;
  }

  if (!upstream.ok) {
    res.writeHead(upstream.status, CORS_HEADERS).end();
    return;
  }

  const buf = Buffer.from(await upstream.arrayBuffer());
  res.writeHead(200, {
    "Content-Type": "image/jpeg",
    "Cache-Control": "no-store",
    "Content-Length": String(buf.length),
    ...CORS_HEADERS,
  });
  res.end(buf);
}
