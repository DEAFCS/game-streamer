#!/usr/bin/env node
import { createServer } from "node:http";
import process from "node:process";

import { BIND, DISPLAY, PORT, SPEC_SERVER_TOKEN } from "./env.mjs";
import { dispatch } from "./routes/index.mjs";
import { findCs2Window } from "./cs2/window.mjs";
import { gsiState } from "./state/gsi.mjs";
import { demoLoadedInProc } from "./state/demo.mjs";
import { startStatePush } from "./reporters/state-push.mjs";

const server = createServer((req, res) => { void dispatch(req, res); });

server.listen(PORT, BIND, () => {
  process.stderr.write(`[spec-server] listening on ${BIND}:${PORT} (display=${DISPLAY})\n`);
  if (!SPEC_SERVER_TOKEN) {
    process.stderr.write(
      "[spec-server] WARN: SPEC_SERVER_TOKEN is unset, so every route is open to anyone who can reach this port\n",
    );
  }
});

// No-op unless DEMO_SESSION_ID is set (batch pods have no watchers).
startStatePush();

// Warn if cs2 has been up but GSI never started flowing. demo_fd=yes means cs2
// has the .dem open (loading the map / compiling shaders — inline in Source 2,
// no console progress counter); demo_fd=no means it's stuck before demo load,
// which points at a missing/misconfigured gamestate_integration cfg.
let gsiWatchdogTicks = 0;
setInterval(async () => {
  if (gsiState.lastReceivedMs > 0) return;
  if (!(await findCs2Window())) return;
  gsiWatchdogTicks++;
  if (gsiWatchdogTicks === 1 || gsiWatchdogTicks % 6 === 0) {
    const demoFd = (await demoLoadedInProc()) ? "yes" : "no";
    process.stderr.write(
      `[spec-server] WARN: cs2 up ${gsiWatchdogTicks * 10}s but no GSI events (demo_fd=${demoFd})\n`,
    );
  }
}, 10_000);

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
