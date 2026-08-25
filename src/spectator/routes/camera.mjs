import process from "node:process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

import { gsiState } from "../state/gsi.mjs";
import { sendJson, CORS_HEADERS } from "../util/http.mjs";

// Streamer-facing camera overlay: hud-manager/camera-overlay.js (running
// inside the HUD's Electron overlay window) polls GET /camera/state to
// find out who's currently spectated, then points a plain <img> at
// GET /camera/:steamId/stream -- a continuous multipart/x-mixed-replace
// MJPEG stream, proxied straight through from streamer-camera-snapshotter
// -- for the actual live picture. No JS polling loop for the video
// itself: browsers have handled multipart JPEG streams in <img> natively
// forever, so once pointed at the URL it just plays, no different from
// how most IP/security cameras have always streamed to a browser.
//
// This used to be a real WHEP-to-WHEP relay all the way through to
// api-deafcs, with the game-streamer pod itself acting as a WebRTC
// client -- reverted after live debugging on an actual deployment
// showed that specific pod's network (a laptop on a university network,
// reachable only over a VPN tunnel) consistently could not complete a
// WebRTC/DTLS handshake to *any* destination, direct or TURN-relayed,
// while every other client (including a real external viewer against
// the exact same media server) connected fine. It was then briefly a
// GET-a-single-JPEG-every-2s poll (cameraSnapshotHandler, still below,
// unused by the live flow now but left in place) -- that avoided the
// WebRTC problem but read as a slideshow, not live video, which wasn't
// good enough. MJPEG streaming gets real continuous video while still
// only ever needing plain HTTPS on this pod's side (proven reliable --
// every other spec-server <-> api-deafcs call already uses it, and so
// does the snapshotter's own WHEP consumption of the camera, which runs
// same-cluster rather than from this pod). See DEAFCS/deafcs-web#91.
//
// This route doesn't need to know or care whether
// match_options.streamer_camera_enabled is actually on, or whether the
// player has published anything -- the snapshotter just 404s (stream)
// or silently skips frames (stream, once connected) if there's nothing
// live, which the overlay's own state-driven show/hide already handles.
// Deliberately separate from the "camera required" anti-cheat feature --
// no shared code, no shared MediaMTX path, no shared toggle.

const SNAPSHOTTER_BASE =
  process.env.SNAPSHOTTER_BASE || "http://streamer-camera-snapshotter:8080";

export async function cameraStateHandler(_req, res) {
  sendJson(res, 200, {
    enabled: !!gsiState.spectatedSteamId,
    steam_id: gsiState.spectatedSteamId,
  });
}

export async function cameraStreamHandler(req, res, steamId) {
  const matchId = process.env.MATCH_ID;
  if (!matchId) {
    res.writeHead(503, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end("camera stream not configured");
    return;
  }
  if (!/^\d{17}$/.test(steamId)) {
    res.writeHead(400, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end("invalid steamId");
    return;
  }

  const controller = new AbortController();
  req.on("close", () => controller.abort());

  let upstream;
  try {
    upstream = await fetch(
      `${SNAPSHOTTER_BASE.replace(/\/$/, "")}/stream/${matchId}/${steamId}`,
      { signal: controller.signal },
    );
  } catch (err) {
    if (controller.signal.aborted) return; // viewer already gone
    res.writeHead(502, { "Content-Type": "text/plain", ...CORS_HEADERS });
    res.end(`snapshotter unreachable: ${err?.message ?? err}`);
    return;
  }

  if (!upstream.ok || !upstream.body) {
    res.writeHead(upstream.status || 502, CORS_HEADERS).end();
    return;
  }

  // Forward the multipart boundary as-is (a fixed boundary=frame, set
  // by the snapshotter) rather than re-declaring our own -- the body
  // bytes are already framed for it.
  res.writeHead(200, {
    "Content-Type": upstream.headers.get("content-type") || "multipart/x-mixed-replace",
    "Cache-Control": "no-store",
    ...CORS_HEADERS,
  });

  try {
    // stream.pipeline(), not a manual .pipe() -- .pipe() returns the
    // *destination* stream, so awaiting finished() on its return value
    // (an earlier version of this code) was watching the wrong object:
    // the source (Readable.fromWeb(upstream.body)) had no error
    // listener of its own, so an abort (a viewer disconnecting, or the
    // overlay switching targets) crashed the entire spec-server process
    // with an unhandled 'error' event instead of landing here. pipeline()
    // correctly wires up and aggregates errors from every stream in the
    // chain.
    await pipeline(Readable.fromWeb(upstream.body), res);
  } catch {
    // Viewer disconnected mid-stream, or the upstream session got torn
    // down -- both routine, nothing to log every time.
  }
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
