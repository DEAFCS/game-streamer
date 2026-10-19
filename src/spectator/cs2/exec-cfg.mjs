import { writeFileSync, renameSync } from "node:fs";
import process from "node:process";

import { EXEC_CFG_KEY } from "../constants.mjs";
import { EXEC_CFG_PATH } from "../env.mjs";
import { sendConsoleCommand, sendKey } from "./input.mjs";

// Serialized so two in-flight calls can't race the cfg rename
// against BACKSPACE delivery and have cs2 read the wrong contents.
let execCfgChain = Promise.resolve();

export async function execCfgCommand(cmd) {
  const prev = execCfgChain;
  let release;
  execCfgChain = new Promise((r) => { release = r; });
  try {
    await prev.catch(() => undefined);
    return await execCfgCommandImpl(cmd);
  } finally {
    setTimeout(release, 30);
  }
}

// Writes the commands where `exec 5stack_exec` reads them. False on failure.
function writeExecCfg(cmd) {
  if (!EXEC_CFG_PATH) return false;
  // One cmd per line; `;`-joined lines get mis-parsed across cs2 builds.
  const lines = cmd.split(";").map((s) => s.trim()).filter(Boolean);
  const body = lines.join("\n") + "\n";
  try {
    const tmp = `${EXEC_CFG_PATH}.tmp`;
    writeFileSync(tmp, body, "utf8");
    renameSync(tmp, EXEC_CFG_PATH);
    return true;
  } catch (err) {
    process.stderr.write(
      `[spec-server] exec-cfg write failed (${(err && err.message) || err})\n`,
    );
    return false;
  }
}

// For when the BACKSPACE bind cannot fire (cs2 on the main menu): the console
// is the only way in, but only `exec 5stack_exec` is typed into it, so the
// address and password never show on the stream. `clear` first wipes the
// scrollback, which can hold the last connect's address.
export async function execCfgViaConsole(cmd) {
  if (!writeExecCfg(`clear; ${cmd}`)) return sendConsoleCommand(cmd);
  return sendConsoleCommand("exec 5stack_exec");
}

async function execCfgCommandImpl(cmd) {
  if (!writeExecCfg(cmd)) return sendConsoleCommand(cmd);
  // Via sendKey so the flush key gets the same focus recovery as every other
  // input path — a raw xdotool key silently no-ops when focus has drifted.
  return sendKey(EXEC_CFG_KEY);
}
