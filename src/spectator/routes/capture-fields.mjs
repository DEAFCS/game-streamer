import { gsiState } from "../state/gsi.mjs";
import { estimateCurrentTick, isSeeking } from "../state/demo.mjs";

// In-process replacement for `GET /demo/state | clip-helpers.mjs
// capture-fields` — the clip capture loop polls this at ~6Hz, and the
// node spawn per poll was the dominant cost. Byte-identical output:
//   round_phase|phase_ends_in|world_motion|gsi_age_ms|map_phase|round_number|pov_round_kills
// text/plain, no trailing newline. All fields empty when GSI is stale
// (>30s), mirroring /demo/state's `gsi: null`.
export async function captureFieldsHandler(req, res) {
  const pov = new URL(req.url, "http://localhost").searchParams.get("pov") ?? "";
  const gsiFresh =
    gsiState.lastReceivedMs > 0 &&
    Date.now() - gsiState.lastReceivedMs < 30_000;
  let line = "||||||";
  if (gsiFresh) {
    // Same world_motion sum as demo-state.mjs — flat across polls = frozen demo.
    let worldMotion = 0;
    for (const p of gsiState.players.values()) {
      if (p.position) worldMotion += p.position[0] + p.position[1] + p.position[2];
    }
    const str = (v) => (typeof v === "string" ? v : "");
    const num = (v) => (typeof v === "number" && Number.isFinite(v) ? String(Math.floor(v)) : "");
    let povKills = "";
    if (pov) {
      const slot = gsiState.specSlots.find((s) => s?.steam_id === pov);
      if (slot && Number.isFinite(slot.round_kills)) povKills = String(slot.round_kills);
    }
    line = [
      str(gsiState.roundPhase),
      str(gsiState.phaseEndsIn),
      String(Math.round(worldMotion)),
      String(Date.now() - gsiState.lastReceivedMs),
      str(gsiState.mapPhase),
      num(gsiState.roundNumber),
      povKills,
    ].join("|");
  }
  const body = Buffer.from(line);
  res.writeHead(200, {
    "Content-Type": "text/plain",
    "Content-Length": String(body.length),
  });
  res.end(body);
}

// In-process replacement for the lead-in POV-lock helpers (slot lookup,
// spectated check, slot-table wait, tick advance) — polled at ~7Hz
// during verify_spec_lock, where the per-poll node spawn dominated.
//   spectated_steam_id|pov_slot|slots_count|tick
// GSI fields empty / slots "0" when stale (>30s); tick is demo
// bookkeeping, not GSI, so it's always present ("?" when unknown).
export async function povStateHandler(req, res) {
  const pov = new URL(req.url, "http://localhost").searchParams.get("pov") ?? "";
  const gsiFresh =
    gsiState.lastReceivedMs > 0 &&
    Date.now() - gsiState.lastReceivedMs < 30_000;
  let spectated = "";
  let slot = "";
  let slots = "0";
  if (gsiFresh) {
    if (typeof gsiState.spectatedSteamId === "string") spectated = gsiState.spectatedSteamId;
    slots = String(gsiState.specSlots.length);
    if (pov) {
      const m = gsiState.specSlots.find((s) => s?.steam_id === pov);
      if (m && typeof m.slot === "number") slot = String(m.slot);
    }
  }
  const t = estimateCurrentTick();
  const tick = typeof t === "number" && Number.isFinite(t) ? String(Math.floor(t)) : "?";
  const body = Buffer.from([spectated, slot, slots, tick].join("|"));
  res.writeHead(200, {
    "Content-Type": "text/plain",
    "Content-Length": String(body.length),
  });
  res.end(body);
}

// "seeking|tick|round_number" — polled by the clip renderer between issuing a
// seek and starting capture. A separate endpoint on purpose: /demo/pov-state is
// parsed positionally from the END of the line, and /demo/capture-fields is
// contractually byte-identical to the clip-helpers.mjs fallback, so appending a
// field to either silently breaks its consumers.
export async function seekStateHandler(_req, res) {
  const t = estimateCurrentTick();
  const tick = typeof t === "number" && Number.isFinite(t) ? String(Math.floor(t)) : "?";
  const round = typeof gsiState.roundNumber === "number" ? String(gsiState.roundNumber) : "";
  const body = Buffer.from([isSeeking() ? "1" : "0", tick, round].join("|"));
  res.writeHead(200, {
    "Content-Type": "text/plain",
    "Content-Length": String(body.length),
  });
  res.end(body);
}
