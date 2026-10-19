# shellcheck shell=bash
# PulseAudio for headless capture: --user-mode daemon, a null sink named
# $PULSE_SINK_NAME ('cs2' by default), and gstreamer captures from its
# .monitor source.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${PULSE_SINK_NAME:=cs2}"
: "${PULSE_RUNTIME_DIR:=$XDG_RUNTIME_DIR/pulse}"
: "${PULSE_TCP_PORT:=4713}"
: "${PULSE_TCP_HOST:=127.0.0.1}"
export PULSE_SINK_NAME PULSE_RUNTIME_DIR PULSE_TCP_PORT PULSE_TCP_HOST
mkdir -p "$PULSE_RUNTIME_DIR"
chmod 700 "$PULSE_RUNTIME_DIR"

pulseaudio_running() {
  pgrep -x pulseaudio >/dev/null 2>&1 && pactl info >/dev/null 2>&1
}

start_pulseaudio() {
  # PULSE_SERVER must NOT be set during bring-up — pulse interprets it
  # as "a server already exists, don't autospawn" and refuses to start.
  unset PULSE_SERVER

  if pulseaudio_running; then
    log "pulseaudio already up"
  else
    log "starting pulseaudio"
    spawn_logged pulseaudio pulseaudio --start --exit-idle-time=-1 \
      --log-target=stderr
    for _ in $(seq 1 20); do
      pactl info >/dev/null 2>&1 && break
      sleep 0.5
    done
    pactl info >/dev/null 2>&1 || die "pulseaudio failed to start"
  fi

  # Null sink for cs2's output. gstreamer reads from its .monitor.
  # rate=48000 matches cs2 + the capture caps — the daemon default (44.1k)
  # forces a double resample (cs2 48k->44.1k sink, monitor 44.1k->48k capture).
  # sink_properties with embedded spaces hits a parser bug — leave
  # description default; it's cosmetic.
  if ! pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$PULSE_SINK_NAME"; then
    pactl load-module module-null-sink sink_name="$PULSE_SINK_NAME" rate=48000 channels=2 >/dev/null \
      || warn "module-null-sink load failed — apps will route to auto_null"
  fi
  pactl set-default-sink "$PULSE_SINK_NAME" 2>/dev/null || true

  # Idle suspend re-bases stream clocks on resume (audible glitches + latency
  # offsets); a capture box never wants it.
  pactl unload-module module-suspend-on-idle 2>/dev/null || true

  # TCP listener so cs2 can find pulse via PULSE_SERVER even when
  # XDG_RUNTIME_DIR is scrubbed (Steam's -applaunch wrapper does that).
  # auth-anonymous is safe — bound to loopback only.
  if ! pactl list short modules 2>/dev/null | awk '{print $2}' | grep -qx module-native-protocol-tcp; then
    pactl load-module module-native-protocol-tcp \
      "listen=${PULSE_TCP_HOST}" "port=${PULSE_TCP_PORT}" \
      auth-anonymous=1 >/dev/null \
      || warn "module-native-protocol-tcp load failed"
  fi
  # Export only after the daemon is up + TCP listener is loaded.
  export PULSE_SERVER="tcp:${PULSE_TCP_HOST}:${PULSE_TCP_PORT}"
}

# Falls back to whatever pulse considers default (e.g. auto_null.monitor
# if our named null sink failed to load).
get_default_source() {
  pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}'
}

stop_pulseaudio() {
  pulseaudio --kill 2>/dev/null || true
  pkill -x pulseaudio 2>/dev/null || true
}
