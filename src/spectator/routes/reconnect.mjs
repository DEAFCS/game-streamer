import process from "node:process";

import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { sendConsoleCommand } from "../cs2/input.mjs";
import { gsiState } from "../state/gsi.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { sendJson } from "../util/http.mjs";

const NON_BLANK = /\S/;
function isNonBlankString(v) {
  return typeof v === "string" && NON_BLANK.test(v);
}

const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

function resolveTarget() {
  if (isNonBlankString(process.env.PLAYCAST_URL)) {
    return { kind: "playcast", url: process.env.PLAYCAST_URL };
  }
  if (isNonBlankString(process.env.CONNECT_TV_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_TV_ADDR,
      password: process.env.CONNECT_TV_PASSWORD ?? "",
    };
  }
  if (isNonBlankString(process.env.CONNECT_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_ADDR,
      password: process.env.CONNECT_PASSWORD ?? "",
    };
  }
  return null;
}

export async function reconnectHandler(_req, res) {
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const target = resolveTarget();
  if (!target) {
    sendJson(res, 409, {
      error:
        "no connect target on this pod — PLAYCAST_URL / CONNECT_TV_ADDR / CONNECT_ADDR all unset",
    });
    return;
  }

  let followUp;
  if (target.kind === "playcast") {
    if (hasUnsafeCfgChars(target.url)) {
      sendJson(res, 400, { error: "playcast url contains unsafe characters" });
      return;
    }
    followUp = `playcast "${target.url}"`;
  } else {
    if (hasUnsafeCfgChars(target.addr) || hasUnsafeCfgChars(target.password)) {
      sendJson(res, 400, { error: "connect target contains unsafe characters" });
      return;
    }
    followUp = `password "${target.password}"; connect ${target.addr}`;
  }

  // In a game the BACKSPACE bind that flushes the exec-cfg fires, so the connect
  // goes through the cfg -- hidden from the stream, which typing into the
  // console is not (it shows the address and password).
  //
  // No `disconnect` first: `connect` (and `playcast`) already leave the current
  // game, and a disconnect in the same exec dropped cs2 to the main menu
  // without the rest of the exec ever running -- the stream-deck reconnect left
  // the streamer disconnected, and the retry then had to type into the console.
  //
  // Not in a game (already on the menu, or a connect that never landed): the
  // bind is dead there, so the console is the only way in.
  const inGame = gsiState.mapName !== null;
  const ok = inGame
    ? await execCfgCommand(followUp)
    : await sendConsoleCommand(followUp);
  if (!ok) {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  process.stderr.write(
    `[spec-server] reconnect (${target.kind}) -> ${target.addr ?? target.url}\n`,
  );
  sendJson(res, 200, { ok: true, kind: target.kind });
}
