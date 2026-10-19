import { gsiState } from "../state/gsi.mjs";

function sendLine(res, line) {
  const body = Buffer.from(line);
  res.writeHead(200, {
    "Content-Type": "text/plain",
    "Content-Length": String(body.length),
  });
  res.end(body);
}

// THIS client's own GSI `player` block, which is how the nade render pod knows
// it has spawned on the practice server:
//   gsi_age_ms|steam_id|team|health|activity|x|y|z|fwd_x|fwd_y|fwd_z
// gsi_age_ms is -1 before the first GSI event. cs2 sends position/forward only
// for a spectated player, so for a live pawn those fields stay empty.
export async function nadeSelfHandler(_req, res) {
  const age = gsiState.lastReceivedMs > 0 ? Date.now() - gsiState.lastReceivedMs : -1;
  const pos = gsiState.localPosition ?? ["", "", ""];
  const fwd = gsiState.localForward ?? ["", "", ""];
  sendLine(res, [
    String(age),
    gsiState.spectatedSteamId ?? "",
    gsiState.localTeam ?? "",
    String(gsiState.localHealth),
    gsiState.localActivity ?? "",
    ...pos.map(String),
    ...fwd.map(String),
  ].join("|"));
}
