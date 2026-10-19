import process from "node:process";

import { gsiState } from "../state/gsi.mjs";
import { STATUS_API_BASE } from "../env.mjs";
import { readBody, sendBodyError, sendJson } from "../util/http.mjs";

// The HUD overlay is a browser page on a different local origin and has no
// business holding the match password, so the SDP exchange is proxied here:
// this process already has the pod's credentials and can add the same
// x-origin-auth header status-reporter and snapshot use.

const STEAM_ID_PATTERN = /^\d{17}$/;

// The overlay offers a single recvonly video transceiver with its ICE
// candidates already gathered, which is a few KB of SDP.
const SDP_BODY_LIMIT = 64 * 1024;

function matchAuth() {
  const matchId = process.env.MATCH_ID ?? "";
  const password =
    process.env.MATCH_PASSWORD ?? process.env.CONNECT_TV_PASSWORD ?? "";

  if (!matchId || !password || !STATUS_API_BASE) {
    return null;
  }

  return { matchId, auth: `${matchId}:${password}` };
}

// Who the broadcast is currently watching. The overlay follows this rather than
// deciding for itself, so the camera always matches what viewers are seeing.
export async function cameraStateHandler(req, res) {
  const credentials = matchAuth();
  const spectated = gsiState.spectatedSteamId;

  sendJson(res, 200, {
    enabled: credentials !== null,
    steam_id: typeof spectated === "string" ? spectated : null,
  });
}

export async function cameraWhepHandler(req, res) {
  const credentials = matchAuth();

  if (!credentials) {
    sendJson(res, 404, { error: "camera overlay not configured" });
    return;
  }

  const steamId = (req.url ?? "").split("/")[2] ?? "";

  if (!STEAM_ID_PATTERN.test(steamId)) {
    sendJson(res, 400, { error: "invalid steam id" });
    return;
  }

  // This route is open to loopback, which is every hostNetwork process on the
  // node, so it hands out only the camera the broadcast is already showing.
  // 409, not 403: the director can cut away while the overlay is still
  // gathering ICE, and the overlay backs off from any other refusal.
  if (steamId !== gsiState.spectatedSteamId) {
    sendJson(res, 409, { error: "not the spectated player" });
    return;
  }

  let sdp;
  try {
    sdp = await readBody(req, SDP_BODY_LIMIT);
  } catch (err) {
    sendBodyError(req, res, err);
    return;
  }

  let response;
  try {
    response = await fetch(
      `${STATUS_API_BASE.replace(/\/$/, "")}/matches/camera/broadcast/${credentials.matchId}/${steamId}/whep`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/sdp",
          "x-origin-auth": credentials.auth,
        },
        body: sdp,
        signal: AbortSignal.timeout(10_000),
      },
    );
  } catch {
    sendJson(res, 502, { error: "camera signaling unreachable" });
    return;
  }

  const body = await response.text();

  if (!response.ok) {
    // A missing path is the normal case for a player who has not connected a
    // camera, so this is not logged as an error.
    sendJson(res, response.status, { error: body.slice(0, 200) });
    return;
  }

  res.writeHead(200, {
    "Content-Type": "application/sdp",
    "Content-Length": String(Buffer.byteLength(body)),
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  });
  res.end(body);
}
