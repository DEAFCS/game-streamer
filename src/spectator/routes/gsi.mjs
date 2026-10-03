import process from "node:process";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import path from "node:path";

import { AUTODIRECTOR_DEFAULT, HUD_GSI_FORWARD_URL, LOG_DIR, SRC_DIR } from "../env.mjs";
import { applyGsiUpdate, gsiState } from "../state/gsi.mjs";
import { bumpActivity, reconcileTickFromGsi } from "../state/demo.mjs";
import { directorState, directorTick, startDirector } from "../director/index.mjs";
import { reportDemoPlayingOnce } from "../reporters/demo-playing.mjs";
import { maybeReverseSideOnFreezetime } from "../reporters/sides.mjs";
import { sendJson } from "../util/http.mjs";

let lastSeededMap = null;
function maybeReseedHudOnMapChange(currentMapName) {
  const matchId = process.env.MATCH_ID;
  if (!matchId || !currentMapName) return;
  if (lastSeededMap === null) {
    lastSeededMap = currentMapName;
    return;
  }
  if (lastSeededMap === currentMapName) return;
  const prev = lastSeededMap;
  lastSeededMap = currentMapName;
  process.stderr.write(
    `[spec-server] map changed ${prev} -> ${currentMapName}, reseeding hud-manager for match ${matchId}\n`,
  );
  const child = spawn(
    "bash",
    ["-c", `. "${SRC_DIR}/lib/hud-manager.sh" && seed_hud_db "$MATCH_ID"`],
    { env: process.env, stdio: ["ignore", "inherit", "inherit"], detached: true },
  );
  child.unref();
}

// Forward to hud-manager fire-and-forget. cs2 fires GSI at ~10Hz so we
// throttle the failure log to avoid flooding when hud-manager is down.
let lastForwardFailLogMs = 0;
function forwardToHud(body) {
  fetch(HUD_GSI_FORWARD_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(2_000),
  }).catch((err) => {
    const now = Date.now();
    if (now - lastForwardFailLogMs > 10_000) {
      lastForwardFailLogMs = now;
      process.stderr.write(
        `[spec-server] gsi forward to ${HUD_GSI_FORWARD_URL} failed: ${(err && err.message) || err}\n`,
      );
    }
  });
}

export function gsiHandler(_req, res, body) {
  const { prevMapPhase, prevRoundPhase, prevPhaseEndsIn, wasReceiving, playersUpdated } =
    applyGsiUpdate(body);

  bumpActivity();
  reconcileTickFromGsi({ prevRoundPhase, prevPhaseEndsIn });
  sendJson(res, 200, { ok: true });
  // Batch highlight pods run no hud-manager: forwarding would just fail at ~10Hz.
  if (process.env.CLIP_BATCH_MODE !== "1") {
    forwardToHud(body);
    maybeReseedHudOnMapChange(gsiState.mapName);
  }

  // cs2's first GSI sometimes lands with empty map/phase — wait for
  // real game context before firing the one-shot "playing" beacon or
  // auto-enabling the director.
  if (gsiState.mapName && gsiState.mapPhase) {
    void reportDemoPlayingOnce();
    if (AUTODIRECTOR_DEFAULT && !directorState.bootstrapped) {
      directorState.bootstrapped = true;
      if (!directorState.enabled) void startDirector();
    }
  }

  if (prevRoundPhase !== "freezetime" && gsiState.roundPhase === "freezetime") {
    void maybeReverseSideOnFreezetime();
  }

  if (playersUpdated && directorState.enabled) {
    void directorTick().catch((err) =>
      process.stderr.write(
        `[spec-server] director tick threw: ${(err && err.stack) || err}\n`,
      ),
    );
  }

  if (!wasReceiving) {
    // Marker so the snapshot loop knows the demo is actually playing (not just
    // a cs2 window up on a load/shader screen) and can drop to slow cadence.
    try { writeFileSync(path.join(LOG_DIR, "gsi-flowing"), ""); } catch { /* best-effort */ }
    process.stderr.write(
      `[spec-server] gsi first event — map=${gsiState.mapName ?? "?"}/${gsiState.mapPhase ?? "?"} ` +
        `round=${gsiState.roundNumber ?? "?"} spec=${gsiState.spectatedSteamId ?? "?"}\n`,
    );
  } else if (prevMapPhase !== gsiState.mapPhase || prevRoundPhase !== gsiState.roundPhase) {
    process.stderr.write(
      `[spec-server] gsi map=${gsiState.mapName ?? "?"}/${gsiState.mapPhase ?? "?"} ` +
        `round=${gsiState.roundNumber ?? "?"}/${gsiState.roundPhase ?? "?"}\n`,
    );
  }
}
