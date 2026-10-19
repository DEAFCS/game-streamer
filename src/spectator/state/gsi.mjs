import { SNIPER_WEAPONS } from "../constants.mjs";
import { parsePosition } from "../util/geometry.mjs";
import { steamIdToAccountId } from "../util/steamid.mjs";

export const gsiState = {
  lastReceivedMs:   0,
  mapName:          null,
  mapPhase:         null,
  roundPhase:       null,
  // phase_countdowns.phase_ends_in — seconds left in the current phase, as a
  // string. Advances with DEMO time during a live round (independent of player
  // movement), so a flat value across polls = real playback freeze, not a hold.
  phaseEndsIn:      null,
  roundNumber:      null,
  spectatedSteamId: null,
  specSlots:        [],
  // The `player` block for THIS client. On a server we joined as a player it's
  // the only block GSI sends (allplayers/allgrenades are observer-only); the
  // nade render pod's session gate reads its health.
  localPosition:    null,
  localForward:     null,
  localHealth:      0,
  localActivity:    null,
  localTeam:        null,
  teamCtName:       null,
  teamTName:        null,
  teamCtScore:      0,
  teamTScore:       0,
  // Map<steamId, {steamId, accountId, slot, name, team, alive, health,
  //   prevHealth, equipValue, hasDefuser, roundKills, prevRoundKills,
  //   position, activeSniper}>
  players:          new Map(),
};

function activeSniperOf(p) {
  const weapons = p?.weapons;
  if (!weapons || typeof weapons !== "object") return null;
  for (const w of Object.values(weapons)) {
    if (!w || typeof w !== "object") continue;
    if (w.state !== "active") continue;
    if (typeof w.name === "string" && SNIPER_WEAPONS.has(w.name)) return w.name;
  }
  return null;
}

export function applyGsiUpdate(body) {
  const map = body?.map ?? {};
  const round = body?.round ?? {};
  const player = body?.player ?? {};
  const allPlayers = body?.allplayers ?? null;
  const pc = body?.phase_countdowns ?? {};

  const prevMapPhase = gsiState.mapPhase;
  const prevRoundPhase = gsiState.roundPhase;
  const prevPhaseEndsIn = gsiState.phaseEndsIn;
  const wasReceiving = gsiState.lastReceivedMs > 0;

  gsiState.lastReceivedMs   = Date.now();
  gsiState.mapName          = typeof map.name === "string" ? map.name : null;
  gsiState.mapPhase         = typeof map.phase === "string" ? map.phase : null;
  gsiState.roundPhase       = typeof round.phase === "string" ? round.phase : null;
  gsiState.phaseEndsIn      =
    typeof pc.phase_ends_in === "string" ? pc.phase_ends_in
    : typeof pc.phase_ends_in === "number" ? String(pc.phase_ends_in)
    : null;
  gsiState.roundNumber      = typeof map.round === "number" ? map.round : null;
  gsiState.spectatedSteamId = typeof player.steamid === "string" ? player.steamid : null;
  gsiState.localPosition    = parsePosition(player.position);
  gsiState.localForward     = parsePosition(player.forward);
  gsiState.localHealth      = Number(player?.state?.health ?? 0) || 0;
  gsiState.localActivity    = typeof player.activity === "string" ? player.activity : null;
  gsiState.localTeam        = player.team === "T" || player.team === "CT" ? player.team : null;
  gsiState.teamCtName       = typeof map?.team_ct?.name === "string" ? map.team_ct.name : null;
  gsiState.teamTName        = typeof map?.team_t?.name === "string" ? map.team_t.name : null;
  gsiState.teamCtScore      = Number(map?.team_ct?.score ?? 0) || 0;
  gsiState.teamTScore       = Number(map?.team_t?.score ?? 0) || 0;

  let playersUpdated = false;
  if (allPlayers && typeof allPlayers === "object") {
    // GSI `observer_slot` is 0-indexed; observer.cfg binds digits
    // 1..0 to spec_player 1..10, so slot = observer_slot + 1.
    const prev = gsiState.players;
    const next = new Map();
    const slots = [];
    for (const [steamId, p] of Object.entries(allPlayers)) {
      if (!p || typeof p !== "object") continue;
      const raw = p.observer_slot;
      const slot = typeof raw === "number" ? raw + 1 : null;
      if (slot !== null && (slot < 1 || slot > 12)) continue;
      const team = p.team === "T" || p.team === "CT" ? p.team : null;
      const state = p.state ?? {};
      const health = Number(state.health ?? 0);
      const prevEntry = prev.get(steamId);
      const record = {
        steamId,
        accountId: steamIdToAccountId(steamId),
        slot,
        name: typeof p.name === "string" ? p.name : null,
        team,
        alive: health > 0,
        health,
        prevHealth: prevEntry?.health ?? health,
        equipValue: Number(state.equip_value ?? 0),
        hasDefuser: team === "CT" && Boolean(state.defusekit),
        roundKills: Number(state.round_kills ?? 0),
        prevRoundKills: prevEntry?.roundKills ?? Number(state.round_kills ?? 0),
        position: parsePosition(p.position),
        activeSniper: activeSniperOf(p),
      };
      next.set(steamId, record);
      if (slot !== null) {
        slots.push({ slot, steam_id: steamId, name: record.name, team, alive: record.alive, health, round_kills: record.roundKills });
      }
    }
    slots.sort((a, b) => a.slot - b.slot);
    gsiState.players = next;
    gsiState.specSlots = slots;
    playersUpdated = true;
  }
  return { prevMapPhase, prevRoundPhase, prevPhaseEndsIn, wasReceiving, playersUpdated };
}

export function aliveCount() {
  let n = 0;
  for (const p of gsiState.players.values()) if (p.alive) n++;
  return n;
}

export function phaseKey() {
  if (gsiState.mapPhase === "warmup") return "warmup";
  if (gsiState.roundPhase === "freezetime") return "freezetime";
  return "live";
}
