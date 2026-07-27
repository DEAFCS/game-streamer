# shellcheck shell=bash
# Helpers for the cs2 spectator-control HTTP daemon â€” entry point at
# src/spectator/server.mjs (refactored from the old single-file
# src/spec-server.mjs). All ops idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${SPEC_SERVER_PORT:=1350}"
: "${SPEC_SERVER_BIN:=$SRC_DIR/spectator/server.mjs}"
export SPEC_SERVER_PORT SPEC_SERVER_BIN

# Match by the unique path fragment "spectator/server.mjs" rather than
# the bare filename â€” `server.mjs` is generic enough that other tools
# could legitimately spawn a process with that name. The bracket
# escape on the first char prevents pgrep matching itself.
spec_server_running() {
  pgrep -f "[s]pectator/server.mjs" >/dev/null 2>&1
}

start_spec_server() {
  if [ ! -f "$SPEC_SERVER_BIN" ]; then
    warn "spec-server not found at $SPEC_SERVER_BIN â€” skipping"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node binary not found in PATH â€” spec-server requires Node.js"
    return 1
  fi
  if spec_server_running; then
    log "spec-server already running (pid $(pgrep -f '[s]pectator/server.mjs' | head -1))"
    return 0
  fi
  log "starting spec-server on :$SPEC_SERVER_PORT"
  # Bypass spawn_logged's awk subprocess â€” it dies when setup-steam.sh
  # exits, leaving spec-server's stdout pipe broken and its writes
  # silently dropped (Node ignores SIGPIPE). Redirect straight to
  # PID 1's stdout (the container init) which the k8s log collector
  # tails â€” that handle survives every launcher script exiting.
  # Lines are already prefixed with `[spec-server] ` from inside the
  # daemon so no awk-side tagging is needed.
  SPEC_PORT="$SPEC_SERVER_PORT" \
    nohup node "$SPEC_SERVER_BIN" \
      >/proc/1/fd/1 2>/proc/1/fd/2 &
  SPAWNED_PID=$!
  log "  spec-server pid=$SPAWNED_PID"
}

stop_spec_server() {
  pkill -f "[s]pectator/server.mjs" 2>/dev/null || true
}

spec_server_status() {
  log "spec-server status:"
  if spec_server_running; then
    log "  process: running (pid $(pgrep -f '[s]pectator/server.mjs' | head -1))"
  else
    log "  process: NOT running"
  fi
  local code
  code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' \
    "http://127.0.0.1:${SPEC_SERVER_PORT}/health" 2>/dev/null)
  if [ "$code" = "200" ]; then
    log "  health:  OK on :$SPEC_SERVER_PORT"
    curl -sS --max-time 2 "http://127.0.0.1:${SPEC_SERVER_PORT}/health" 2>/dev/null \
      | sed 's/^/    /'
  else
    log "  health:  unreachable (curl status: ${code:-no response})"
  fi
}
