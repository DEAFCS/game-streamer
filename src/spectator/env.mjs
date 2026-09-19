import path from "node:path";
import process from "node:process";

export const DISPLAY = process.env.DISPLAY ?? ":0";
export const PORT    = parseInt(process.env.SPEC_PORT ?? "1350", 10);
export const BIND    = process.env.SPEC_BIND ?? "0.0.0.0";
export const LOG_DIR = process.env.LOG_DIR ?? "/tmp/game-streamer";

export const DEMO_ROUND_TICKS_PATH =
  process.env.DEMO_ROUND_TICKS_PATH ?? path.join(LOG_DIR, "demo-round-ticks.json");

export const PLAYER_BINDINGS_PATH =
  process.env.SPEC_BINDINGS_PATH ?? path.join(LOG_DIR, "spec-bindings.json");

export const CS2_CFG_DIR =
  process.env.CS2_CFG_DIR ??
  (process.env.CS2_DIR ? `${process.env.CS2_DIR}/game/csgo/cfg` : null);

export const EXEC_CFG_PATH = CS2_CFG_DIR ? `${CS2_CFG_DIR}/5stack_exec.cfg` : null;

export const DEMO_FILE = process.env.DEMO_FILE ?? "/tmp/game-streamer/demo.dem";

// Last status body the api accepted, written by status-reporter.sh's daemon.
export const STATUS_ACK_FILE =
  process.env.STATUS_ACK_FILE ?? path.join(LOG_DIR, "status.ack");

export const DEMO_SESSION_ID    = process.env.DEMO_SESSION_ID    ?? null;
export const STATUS_API_BASE    = process.env.STATUS_API_BASE ?? process.env.API_BASE ?? null;

export const HUD_HOST     = process.env.HUD_HOST || "127.0.0.1";
export const HUD_PORT     = process.env.HUD_PORT || "1349";
export const HUD_GSI_PORT = process.env.HUD_GSI_PORT || "23415";
// Where spec-server forwards every /gsi body after processing.
export const HUD_GSI_FORWARD_URL = `http://${HUD_HOST}:${HUD_GSI_PORT}/cs2/input`;

// Auto-director starts ON by default — UI can flip it off at runtime
// via POST /spec/autodirector {enabled:false}. Set AUTODIRECTOR=0 to
// boot with it disabled.
export const AUTODIRECTOR_DEFAULT =
  (process.env.AUTODIRECTOR ?? "1") !== "0";

export const SRC_DIR = process.env.SRC_DIR ?? "/opt/game-streamer/src";

export const DEMO_TICK_RATE   = parseFloat(process.env.DEMO_TICK_RATE  ?? "64") || 64;
export const DEMO_TOTAL_TICKS = parseInt(process.env.DEMO_TOTAL_TICKS ?? "0", 10) || 0;
