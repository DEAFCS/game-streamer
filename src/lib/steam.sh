# shellcheck shell=bash
# Steam-specific helpers: bootstrap install, library registration, start/stop,
# pipe-up wait, and gbe_fork stub <-> real-client swap.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SDK64_LINK=/root/.steam/sdk64/steamclient.so
SDK64_BACKUP=/root/.steam/sdk64/steamclient.so.real

steam_pipe_up() {
  [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ] \
    && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null
}

steam_bootstrap_extracted() {
  [ -x "$STEAM_HOME/steam.sh" ]
}

# Seed $STEAM_HOME with the Steam bootstrap if missing. Prefers the copy
# baked into the image at /opt/steam-bootstrap (Dockerfile pre-extracts it);
# falls back to downloading steam.deb when running outside the image.
ensure_steam_bootstrap() {
  if steam_bootstrap_extracted; then return 0; fi

  mkdir -p "$STEAM_HOME"

  if [ -x /opt/steam-bootstrap/steam.sh ]; then
    log "seeding Steam bootstrap from /opt/steam-bootstrap into $STEAM_HOME"
    cp -a /opt/steam-bootstrap/. "$STEAM_HOME/"
    steam_bootstrap_extracted || die "bootstrap copy failed"
    return 0
  fi

  command -v xz >/dev/null 2>&1 || {
    log "installing xz-utils"
    apt-get update -qq && apt-get install -y -qq xz-utils
  }
  log "downloading + extracting Steam bootstrap into $STEAM_HOME"
  curl -fsSL -o /tmp/steam.deb \
    https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb
  dpkg-deb -x /tmp/steam.deb /tmp/steamdeb
  local bootstrap
  bootstrap=$(find /tmp/steamdeb -name 'bootstraplinux_ubuntu12_32.tar.xz' | head -1)
  tar -xJf "$bootstrap" -C "$STEAM_HOME"
  rm -rf /tmp/steam.deb /tmp/steamdeb
  steam_bootstrap_extracted || die "bootstrap extract failed"
}

# Make sure sdk64/steamclient.so points at the real Steam runtime, not the
# gbe_fork stub. Real Steam needs its own steamclient.so for IPC.
restore_real_steamclient() {
  if [ ! -L "$SDK64_LINK" ]; then return 0; fi
  if ! readlink -f "$SDK64_LINK" 2>/dev/null | grep -q '/opt/gbe_fork'; then
    return 0
  fi
  log "swapping sdk64/steamclient.so back to real Steam runtime"
  rm -f "$SDK64_LINK"
  if [ -e "$SDK64_BACKUP" ]; then
    if [ -L "$SDK64_BACKUP" ]; then
      ln -sfn "$(readlink "$SDK64_BACKUP")" "$SDK64_LINK"
    else
      mv "$SDK64_BACKUP" "$SDK64_LINK"
    fi
  else
    local sc
    sc=$(find "$STEAM_HOME" -name 'steamclient.so' -path '*linux64*' 2>/dev/null | head -1)
    [ -n "$sc" ] && ln -sfn "$sc" "$SDK64_LINK"
  fi
  # Stub-era appid hints confuse real Steam.
  rm -f "$STEAM_LIBRARY/cs2/game/csgo/steam_appid.txt" \
        "$STEAM_LIBRARY/cs2/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true
}

# Register $lib as a Steam library so CS2 (installed there by steamcmd) is
# recognized on boot â€” no interactive Install dialog, no re-download.
#
# CRITICAL: Steam READS and rewrites $STEAM_HOME/steamapps/libraryfolders.vdf,
# NOT $STEAM_HOME/config/libraryfolders.vdf. Proven via content_log.txt:
#   "Loaded Steam library folders configuration: .../steam/steamapps/libraryfolders.vdf"
# The long-standing bug seeded only config/, which Steam ignores, so on a fresh
# (or reset) library $lib was never registered in the file Steam reads â†’ Steam
# loaded "1 libraries", never loaded CS2 from $lib/steamapps â†’ "not installed".
# Working pods only worked because Steam had adopted the library into the
# steamapps/ copy long ago and it persisted. Seed BOTH copies (Steam keeps them
# in sync once it adopts); the steamapps/ one is load-bearing.
register_library() {
  local lib="${1:-$STEAM_LIBRARY}"
  mkdir -p "$lib/steamapps/common"

  # Stable per-library contentid: reuse an existing non-zero one (Steam stamps a
  # real value once it adopts the library), else generate. Matches the adopted
  # state on working pods.
  local cid=""
  [ -f "$lib/libraryfolder.vdf" ] && \
    cid=$(grep -oE '"contentid"[^0-9]*"[0-9]+"' "$lib/libraryfolder.vdf" 2>/dev/null \
          | grep -oE '[0-9]+' | head -1)
  if [ -z "$cid" ] || [ "$cid" = "0" ]; then
    cid=$(od -An -tu8 -N8 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -n "$cid" ] || cid=$(( (RANDOM << 30) ^ (RANDOM << 15) ^ RANDOM ))
  fi

  # Per-library marker. Working pods carry it at the library root.
  local marker
  for marker in "$lib/libraryfolder.vdf" "$lib/steamapps/libraryfolder.vdf"; do
    cat > "$marker" <<EOF
"libraryfolder"
{
    "contentid"        "$cid"
    "label"            "game-streamer hostpath"
}
EOF
  done

  # Register $lib in the file Steam reads (steamapps/) AND the config/ mirror.
  # Idempotent: leave an existing entry for $lib alone, else append one.
  local lf
  for lf in "$STEAM_HOME/steamapps/libraryfolders.vdf" "$STEAM_HOME/config/libraryfolders.vdf"; do
    mkdir -p "$(dirname "$lf")"
    if [ ! -f "$lf" ]; then
      cat > "$lf" <<EOF
"libraryfolders"
{
    "0"
    {
        "path"        "$STEAM_HOME"
        "label"        ""
        "contentid"        "0"
        "apps"
        {
        }
    }
    "1"
    {
        "path"        "$lib"
        "label"        "game-streamer hostpath"
        "contentid"        "$cid"
        "apps"
        {
        }
    }
}
EOF
      log "wrote fresh $lf with $lib (contentid $cid)"
      continue
    fi
    # Match the exact path entry â€” "$lib" must not match "$lib/steam" (the home).
    if grep -qE "\"path\"[[:space:]]*\"${lib}\"" "$lf"; then
      log "$lib already registered in $lf"
      continue
    fi
    log "appending $lib to existing $lf"
    python3 - "$lf" "$lib" "$cid" <<'PY'
import re, sys, pathlib
lf = pathlib.Path(sys.argv[1])
path = sys.argv[2]
cid = sys.argv[3]
src = lf.read_text()
idxs = [int(m.group(1)) for m in re.finditer(r'"(\d+)"\s*\{', src)]
nxt = max(idxs) + 1 if idxs else 0
entry = f'''
    "{nxt}"
    {{
        "path"        "{path}"
        "label"        "game-streamer hostpath"
        "contentid"        "{cid}"
        "apps"
        {{
        }}
    }}
'''
src = src.rstrip()
if src.endswith("}"):
    src = src[:-1] + entry + "}\n"
lf.write_text(src)
PY
  done
}

# Forwards steamcmd "Update state ... progress: X.YY" lines through
# report_status; mirrors each throttled tick to stderr. Skips repeats
# unless stage changes or % advances â‰¥1.0. set -o pipefail safe.
_emit_cs2_progress_from_stdin() {
  local line stage pct last_stage="" last_pct="-1"
  while IFS= read -r line; do
    if [[ "$line" =~ Update\ state\ \(0x[0-9a-fA-F]+\)\ ([^,]+),\ progress:\ ([0-9]+\.[0-9]+) ]]; then
      stage="${BASH_REMATCH[1]}"
      pct="${BASH_REMATCH[2]}"
      if [ "$stage" = "$last_stage" ] \
         && awk -v a="$pct" -v b="$last_pct" 'BEGIN{exit !(a-b<1)}'; then
        continue
      fi
      last_stage="$stage"
      last_pct="$pct"
      printf '[steamcmd] cs2 install: %s %s%%\n' "$stage" "$pct" >&2
      report_status status=downloading_cs2 progress="$pct" progress_stage="$stage"
    fi
  done
}

# Install CS2 via steamcmd directly into the configured library when
# the install is missing. Skips when an appmanifest already exists â€”
# our game-server runs on a fixed CS2 build, so leaving warm pods on
# whatever buildid was first installed keeps client/server in sync.
#
# Runs against $STEAM_LIBRARY (not the default ~/.local/share/Steam) by
# passing +force_install_dir, so the install lands inside our registered
# library folder and Steam picks it up on launch â€” no Install UI dialog.
#
# Steam should be OFF when this runs (we kill it in setup-steam before
# calling). steamcmd and Steam can clash on appmanifest writes otherwise.
install_cs2_via_steamcmd() {
  require_env STEAM_USER STEAM_PASSWORD

  local manifest="$STEAM_LIBRARY/steamapps/appmanifest_730.acf"
  local cs2_bin="$CS2_DIR/game/bin/linuxsteamrt64/cs2"

  if [ -f "$manifest" ] && [ -x "$cs2_bin" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$manifest" | head -1 || true)
    log "CS2 already installed at $CS2_DIR (${bid:-buildid unknown}) â€” skip steamcmd"
    return 0
  fi

  if ! command -v /opt/steamcmd/steamcmd.sh >/dev/null 2>&1 \
       && [ ! -x /opt/steamcmd/steamcmd.sh ]; then
    die "steamcmd not found at /opt/steamcmd/steamcmd.sh â€” image needs the steamcmd install layer"
  fi

  report_status status=downloading_cs2

  log "running steamcmd: install CS2 (appid 730) into $CS2_DIR"
  log "  this is a ~57 GB download on a fresh install"
  mkdir -p "$CS2_DIR"

  # Capture the steamcmd transcript so we can pattern-match failures
  # below â€” auth errors come out on stdout (e.g. "ERROR (Invalid
  # Password)") and we want to surface them as a specific operator-
  # actionable message via report_status, not the generic "no
  # appmanifest" fallthrough. `tee` keeps the live log in k8s stdout
  # so behaviour for healthy runs is unchanged.
  local steamcmd_log="$LOG_DIR/steamcmd-cs2-install.log"
  : > "$steamcmd_log"

  # Call steamcmd.sh directly â€” the /usr/local/bin/steamcmd shim resolves
  # its own dir wrong via symlink and can't find linux32/. The trailing
  # _emit_cs2_progress_from_stdin pipe stage forwards live download
  # progress to the API; tee keeps the full transcript for the post-exit
  # auth-error grep below.
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    +login "$STEAM_USER" "$STEAM_PASSWORD" \
    +app_update 730 validate \
    +quit 2>&1 | tee -a "$steamcmd_log" | _emit_cs2_progress_from_stdin

  if [ ! -f "$manifest" ] && [ -f "$CS2_DIR/steamapps/appmanifest_730.acf" ]; then
    # steamcmd put the manifest inside the install dir; lift it to the
    # library root where Steam expects it.
    mv "$CS2_DIR/steamapps/appmanifest_730.acf" "$manifest"
    rmdir "$CS2_DIR/steamapps" 2>/dev/null || true
    sed -i 's|"installdir"[[:space:]]*"[^"]*"|"installdir"\t\t"Counter-Strike Global Offensive"|' \
      "$manifest"
    log "  lifted manifest to $manifest"
  fi

  if [ -f "$manifest" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$manifest" | head -1 || true)
    log "CS2 install OK â€” ${bid:-buildid unknown}"
    # Re-register: steamcmd rewrote libraryfolders.vdf, dropping the pre-install entry.
    register_library "$STEAM_LIBRARY"
    return 0
  fi

  # No manifest. Walk the captured transcript for known auth failures
  # so the match_streams row gets a message the operator can act on
  # ("verify steam username and password") rather than the generic
  # "install failed". Pattern list mirrors the EResult strings
  # steamcmd prints â€” extend as new failure modes show up in the wild.
  if grep -qE 'ERROR \(Invalid Password\)|FAILED login.*Invalid Password|FAILED \(Invalid Password\)' "$steamcmd_log"; then
    die "Steam login rejected â€” verify STEAM_USER and STEAM_PASSWORD on the API are correct for the streamer Steam account."
  fi
  if grep -qE 'Account Logon Denied|Account Login Denied Need Two Factor|RateLimitExceeded|Rate Limit Exceeded' "$steamcmd_log"; then
    die "Steam login blocked by Steam Guard / rate limit â€” disable Steam Guard on the streamer Steam account or wait a few minutes and retry."
  fi
  if grep -qE 'No subscription|No license' "$steamcmd_log"; then
    die "Steam account lacks a CS2 license â€” the streamer Steam account must own (or have a free license for) CS2 (appid 730)."
  fi
  if grep -qE 'No space left on device|Disk write failure|ENOSPC|insufficient.*disk space' "$steamcmd_log"; then
    die "steamcmd failed: out of disk space on the streamer PVC (\$STEAM_LIBRARY=$STEAM_LIBRARY) â€” resize or evict cached games."
  fi
  if grep -qE 'Connection reset by peer|Failed to receive any data, quitting now|Could not connect to Steam network|Connecting anonymously to Steam Public.*FAILED|Connection to Steam servers lost' "$steamcmd_log"; then
    die "steamcmd lost connection to Steam servers â€” usually transient, the pod will retry on restart. Last log lines: $(_steamcmd_log_tail "$steamcmd_log")"
  fi
  local appstate_line
  appstate_line=$(grep -E 'ERROR! ?(App|Update) .*(state|failed)|Failed to install app|Update failed' "$steamcmd_log" | tail -1 || true)
  if [ -n "$appstate_line" ]; then
    die "steamcmd install failed: ${appstate_line}"
  fi

  die "steamcmd finished but no $manifest â€” install failed. Tail: $(_steamcmd_log_tail "$steamcmd_log")"
}

# Joins the last few non-empty lines with ` | ` for embedding in die().
# Capped well under the api's 500-char error_message ceiling.
_steamcmd_log_tail() {
  local f="${1:?log path required}"
  [ -f "$f" ] || { printf '(log missing)'; return; }
  local tail_text
  tail_text=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null \
    | tail -8 \
    | tr '\n' '|' \
    | sed 's/|$//; s/|/ | /g')
  if [ -z "$tail_text" ]; then
    printf '(no output captured)'
  else
    printf '%.380s' "$tail_text"
  fi
}

# Pre-download a CS2 workshop map via steamcmd. Without this, +playdemo
# on a workshop map stalls CS2 on a "Subscribe?" prompt and the demo
# never starts. Idempotent â€” steamcmd skips if the .vpk is already on
# disk at the expected path.
#
#   $1  workshop item id (numeric, from the demo header `workshop/<id>/...`)
download_workshop_map() {
  local id="${1:?workshop id required}"

  # steamcmd writes to $STEAM_LIBRARY/steamapps/workshop/content/730/<id>/.
  # CS2 looks there at runtime â€” no extra symlink required.
  local target="$STEAM_LIBRARY/steamapps/workshop/content/730/${id}"
  if compgen -G "$target/*.vpk" >/dev/null 2>&1; then
    log "workshop map ${id} already present at $target â€” skip download"
    return 0
  fi

  if [ ! -x /opt/steamcmd/steamcmd.sh ]; then
    warn "steamcmd missing â€” cannot pre-download workshop map ${id}"
    return 1
  fi

  # Creds only needed when we're actually about to call steamcmd; the
  # idempotent skip above must work in env contexts that don't have them.
  require_env STEAM_USER STEAM_PASSWORD

  log "downloading workshop map ${id} via steamcmd"
  # +force_install_dir matters: steamcmd places workshop content RELATIVE
  # to the install dir, so this gives us $STEAM_LIBRARY/steamapps/workshop/...
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    +login "$STEAM_USER" "$STEAM_PASSWORD" \
    +workshop_download_item 730 "$id" \
    +quit \
    | sed -u 's/^/  [steamcmd] /'

  if compgen -G "$target/*.vpk" >/dev/null 2>&1; then
    log "  workshop map ${id} ready at $target"
    return 0
  fi
  warn "  workshop_download_item finished but no .vpk at $target"
  warn "  CS2 will likely show the Subscribe? prompt and stall"
  return 1
}

# Set Steam Cloud sync to OFF for CS2 (appid 730) in every user's
# localconfig.vdf. CS2's "Cloud Out of Date" / "Play anyway" prompt is a
# CEF dialog with no X11 title â€” xdotool can't reliably target it â€” so we
# stop it from firing in the first place.
#
# Steam rewrites localconfig.vdf on shutdown, so this is a no-op while
# Steam is running. Call BEFORE start_steam.

# Edit a single VDF file (localconfig.vdf or sharedconfig.vdf) to set
# cloudenabled=0 inside the apps/<appid> block. Idempotent.
_vdf_disable_app_cloud() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib

cfg_path, appid = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg_path)
src = p.read_text()

# Case 1: existing <appid> block â€” flip or insert cloudenabled inside.
pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
    brace_open = m.end() - 1
    depth, i = 1, brace_open + 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    if depth != 0:
        print(f"  {cfg_path}: unbalanced braces â€” refusing to edit")
        sys.exit(1)
    brace_close = i - 1
    block = src[brace_open + 1:brace_close]
    indent = m.group(2) + "\t"
    # Steam writes the key as "CloudEnabled" (capitalized); historic docs
    # use lowercase. Match either, preserve case to avoid duplicates.
    ce = re.search(r'(^|\n)([ \t]*)"([Cc]loud[Ee]nabled)"[ \t]+"([^"]*)"', block)
    if ce:
        if ce.group(4) == "0":
            sys.exit(0)
        new_block = block[:ce.start()] \
            + f'{ce.group(1)}{ce.group(2)}"{ce.group(3)}"\t\t"0"' \
            + block[ce.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: flipped {ce.group(3)} to 0 in existing {appid} block")
    else:
        new_block = f'\n{indent}"CloudEnabled"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: inserted CloudEnabled=0 in existing {appid} block")
    sys.exit(0)

# Case 2: existing "apps" block â€” insert <appid> block inside.
apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
if apps:
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"CloudEnabled"\t\t"0"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with CloudEnabled=0")
    sys.exit(0)

# Case 3: no "apps" block at all â€” synthesize the whole structure under
# the Steam block. sharedconfig.vdf is nearly empty before the first
# CS2 launch.
def find_block_open(src, key, start=0):
    """Return offset right after the `{` of `"key" {` (or -1)."""
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    mm = pat.search(src, start)
    return mm.end() if mm else -1

sw = find_block_open(src, "Software")
if sw == -1:
    print(f"  {cfg_path}: no Software block â€” leaving untouched"); sys.exit(0)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  {cfg_path}: no Valve block â€” leaving untouched"); sys.exit(0)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  {cfg_path}: no Steam block â€” leaving untouched"); sys.exit(0)

# Pull the indent of the "Steam" line so the new block matches the file's style.
sm = re.search(r'(\n)([ \t]*)"Steam"[ \t\r\n]*\{', src[:steam])
steam_indent = sm.group(2) if sm else "\t\t\t"
inner = steam_indent + "\t"  # one level deeper for "apps"

insertion = (
    f'\n{inner}"apps"\n{inner}{{\n'
    f'{inner}\t"{appid}"\n{inner}\t{{\n'
    f'{inner}\t\t"CloudEnabled"\t\t"0"\n{inner}\t}}\n'
    f'{inner}}}'
)
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  {cfg_path}: synthesized apps/{appid}/CloudEnabled=0 under Steam block")
PY
}

# Print the userdata/<id> account id for the login account (STEAM_USER in
# loginusers.vdf, else MostRecent); empty if unresolved.
active_steam_accountid() {
  local f
  for f in "$STEAM_HOME/config/loginusers.vdf" "$HOME/.steam/steam/config/loginusers.vdf"; do
    [ -f "$f" ] || continue
    python3 - "$f" "${STEAM_USER:-}" <<'PY' && return 0
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text(errors="ignore")
want = (sys.argv[2] or "").strip().lower()
best = None
for m in re.finditer(r'"(7656\d{13})"\s*\{([^{}]*)\}', src):
    sid, body = m.group(1), m.group(2)
    am = re.search(r'"AccountName"\s*"([^"]*)"', body, re.I)
    acct = am.group(1).lower() if am else ""
    if want and acct == want:
        best = sid; break
    if re.search(r'"MostRecent"\s*"1"', body) and best is None:
        best = sid
if best:
    print(int(best) - 76561197960265728)
PY
  done
  return 1
}

# True if the login account still has CS2 cloud on (leftover 730 ledger, or no
# CloudEnabled=0 in its localconfig). Unknown id â†’ dirty.
cs2_cloud_dirty_for_active() {
  local aid lc
  aid=$(active_steam_accountid 2>/dev/null) || return 0
  [ -n "$aid" ] || return 0
  [ -e "$STEAM_HOME/userdata/$aid/730/remotecache.vdf" ] && return 0
  lc="$STEAM_HOME/userdata/$aid/config/localconfig.vdf"
  [ -f "$lc" ] || return 0
  # CloudEnabled "0" anywhere in the apps/730 block â†’ clean. (Coarse 40-line
  # window after the "730" key; good enough â€” the block is small.)
  if grep -A40 '"730"' "$lc" 2>/dev/null | grep -qiE '"CloudEnabled"[[:space:]]+"0"'; then
    return 1
  fi
  return 0
}

# Set Steam Cloud sync to OFF for CS2 in every user's per-account VDFs:
#   localconfig.vdf  â€” local-only (rewritten on Steam shutdown)
#   sharedconfig.vdf â€” synced across PCs (under userdata/<id>/7/remote)
# Also auto-discovers all SteamIDs (numeric subdirs of userdata/) so we
# don't need to know the SteamID up front.
#
# Steam rewrites these on shutdown; this is a no-op while Steam is
# running. Call BEFORE start_steam.
disable_cs2_cloud() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cs2_cloud: Steam is running â€” skip (would be clobbered on shutdown)"
    return 0
  fi

  # Both common userdata paths â€” ~/.steam/steam is normally a symlink
  # into ~/.local/share/Steam, but if it's been replaced with a real
  # dir we want to catch that too.
  local roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  local seen=() root user_dir steamid edited=0
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    # De-dup if both paths resolve to the same place.
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")

    shopt -s nullglob
    for user_dir in "$root"/*/; do
      steamid=$(basename "$user_dir")
      case "$steamid" in ''|*[!0-9]*) continue ;; esac
      log "disable_cs2_cloud: SteamID $steamid (under $root)"
      _vdf_disable_app_cloud "$user_dir/config/localconfig.vdf"
      _vdf_disable_app_cloud "$user_dir/7/remote/sharedconfig.vdf"
      # Nuke the stale 730 cloud conflict state (local only; Steam-off).
      if [ -d "$user_dir/730" ]; then
        rm -rf "$user_dir/730" \
          && log "disable_cs2_cloud:   cleared local 730 cloud state (userdata/$steamid/730)"
      fi
      edited=1
    done
    shopt -u nullglob
  done

  [ "$edited" = 0 ] && log "disable_cs2_cloud: no userdata SteamIDs found yet â€” skip"
  return 0
}

# Disable cloud in $STEAM_HOME/config/config.vdf (the install-wide
# config, distinct from registry.vdf). Sets:
#   InstallConfigStore/Software/Valve/Steam/Cloud/EnableCloud = 0
disable_cloud_in_config_vdf() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cloud_in_config_vdf: Steam is running â€” skip"
    return 0
  fi
  local f
  for f in "$STEAM_HOME/config/config.vdf" "$HOME/.steam/steam/config/config.vdf"; do
    [ -f "$f" ] || continue
    log "disable_cloud_in_config_vdf: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# 1) Existing EnableCloud â€” flip its value.
m = re.search(r'"EnableCloud"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  EnableCloud already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("EnableCloud"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>', src, count=1,
    )
    p.write_text(new)
    print(f"  flipped EnableCloud to 0 in {p}")
    sys.exit(0)

# 2) Existing Cloud { ... } block â€” inject EnableCloud into it.
m = re.search(r'"Cloud"[ \t\r\n]*\{', src)
if m:
    p.write_text(src[:m.end()] + '\n\t\t\t\t\t"EnableCloud"\t\t"0"' + src[m.end():])
    print(f"  inserted EnableCloud=0 into existing Cloud block in {p}")
    sys.exit(0)

# 3) Inject a fresh Cloud block under Steam.
def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    m = pat.search(src, start)
    return m.end() if m else -1

ics = find_block_open(src, "InstallConfigStore")
if ics == -1:
    print(f"  no InstallConfigStore in {p} â€” skip"); sys.exit(0)
sw = find_block_open(src, "Software", ics)
if sw == -1: print(f"  no Software in {p}"); sys.exit(0)
v = find_block_open(src, "Valve", sw)
if v == -1: print(f"  no Valve in {p}"); sys.exit(0)
steam = find_block_open(src, "Steam", v)
if steam == -1: print(f"  no Steam in {p}"); sys.exit(0)

block = '\n\t\t\t\t"Cloud"\n\t\t\t\t{\n\t\t\t\t\t"EnableCloud"\t\t"0"\n\t\t\t\t}'
p.write_text(src[:steam] + block + src[steam:])
print(f"  inserted Cloud {{ EnableCloud=0 }} into Steam block in {p}")
PY
  done
}

# Disable Steam Cloud globally by editing registry.vdf
# (HKCU/Software/Valve/Steam/CloudEnabled = 0). This is the SAME setting
# the Steam UI exposes as "Settings â†’ Cloud â†’ Enable Steam Cloud sync".
# Per-app cloudenabled in localconfig.vdf isn't always sufficient â€” the
# global flag is the reliable kill switch for the "Cloud Out of Date" dialog.
#
# Steam rewrites registry.vdf on shutdown; call BEFORE start_steam.
disable_cloud_globally() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cloud_globally: Steam is running â€” skip (would be clobbered on shutdown)"
    return 0
  fi
  local f
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    [ -f "$f" ] || continue
    log "disable_cloud_globally: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# Replace existing key value if present.
m = re.search(r'"CloudEnabled"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  CloudEnabled already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("CloudEnabled"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>',
        src, count=1,
    )
    p.write_text(new)
    print(f"  flipped CloudEnabled to 0 in {p}")
    sys.exit(0)

# Insert into HKCU > Software > Valve > Steam.
def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    m = pat.search(src, start)
    return m.end() if m else -1

hkcu = find_block_open(src, "HKCU")
if hkcu == -1:
    hkcu = find_block_open(src, "HKEY_CURRENT_USER")
if hkcu == -1:
    print(f"  no HKCU block in {p} â€” leaving untouched")
    sys.exit(1)
sw = find_block_open(src, "Software", hkcu)
if sw == -1:
    print(f"  no Software in HKCU in {p}"); sys.exit(1)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  no Valve in Software in {p}"); sys.exit(1)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  no Steam in Valve in {p}"); sys.exit(1)

insertion = '\n\t\t\t\t\t"CloudEnabled"\t\t"0"'
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  inserted CloudEnabled=0 in {p}")
PY
  done
}

# Disable the Steam in-game overlay globally by editing registry.vdf
# (HKCU/Software/Valve/Steam/EnableGameOverlay = 0). Same toggle as the
# Steam UI's Settings â†’ In-Game â†’ "Enable the Steam Overlay while
# in-game". Without this, Steam can pop the overlay over cs2 mid-match
# (Shift+Tab, friend invites, achievement toasts) and steal focus â€”
# we'd capture the overlay instead of the game.
#
# Steam rewrites registry.vdf on shutdown; call BEFORE start_steam.
disable_overlay_globally() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_overlay_globally: Steam is running â€” skip (would be clobbered on shutdown)"
    return 0
  fi
  local f
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    [ -f "$f" ] || continue
    log "disable_overlay_globally: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

m = re.search(r'"EnableGameOverlay"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  EnableGameOverlay already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("EnableGameOverlay"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>',
        src, count=1,
    )
    p.write_text(new)
    print(f"  flipped EnableGameOverlay to 0 in {p}")
    sys.exit(0)

def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    m = pat.search(src, start)
    return m.end() if m else -1

hkcu = find_block_open(src, "HKCU")
if hkcu == -1:
    hkcu = find_block_open(src, "HKEY_CURRENT_USER")
if hkcu == -1:
    print(f"  no HKCU block in {p} â€” leaving untouched")
    sys.exit(1)
sw = find_block_open(src, "Software", hkcu)
if sw == -1:
    print(f"  no Software in HKCU in {p}"); sys.exit(1)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  no Valve in Software in {p}"); sys.exit(1)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  no Steam in Valve in {p}"); sys.exit(1)

insertion = '\n\t\t\t\t\t"EnableGameOverlay"\t\t"0"'
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  inserted EnableGameOverlay=0 in {p}")
PY
  done
}

# Edit a single localconfig.vdf to set OverlayAppEnabled=0 inside the
# apps/<appid> block. Idempotent. Mirrors _vdf_disable_app_cloud's
# 3-case structure (existing key, existing app block, no apps block).
_vdf_disable_app_overlay() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib

cfg_path, appid = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg_path)
src = p.read_text()

pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
    brace_open = m.end() - 1
    depth, i = 1, brace_open + 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    if depth != 0:
        print(f"  {cfg_path}: unbalanced braces â€” refusing to edit")
        sys.exit(1)
    brace_close = i - 1
    block = src[brace_open + 1:brace_close]
    indent = m.group(2) + "\t"
    oe = re.search(r'(^|\n)([ \t]*)"([Oo]verlay[Aa]pp[Ee]nabled)"[ \t]+"([^"]*)"', block)
    if oe:
        if oe.group(4) == "0":
            sys.exit(0)
        new_block = block[:oe.start()] \
            + f'{oe.group(1)}{oe.group(2)}"{oe.group(3)}"\t\t"0"' \
            + block[oe.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: flipped {oe.group(3)} to 0 in existing {appid} block")
    else:
        new_block = f'\n{indent}"OverlayAppEnabled"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: inserted OverlayAppEnabled=0 in existing {appid} block")
    sys.exit(0)

apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
if apps:
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"OverlayAppEnabled"\t\t"0"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with OverlayAppEnabled=0")
    sys.exit(0)

def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    mm = pat.search(src, start)
    return mm.end() if mm else -1

sw = find_block_open(src, "Software")
if sw == -1:
    print(f"  {cfg_path}: no Software block â€” leaving untouched"); sys.exit(0)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  {cfg_path}: no Valve block â€” leaving untouched"); sys.exit(0)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  {cfg_path}: no Steam block â€” leaving untouched"); sys.exit(0)

sm = re.search(r'(\n)([ \t]*)"Steam"[ \t\r\n]*\{', src[:steam])
steam_indent = sm.group(2) if sm else "\t\t\t"
inner = steam_indent + "\t"

insertion = (
    f'\n{inner}"apps"\n{inner}{{\n'
    f'{inner}\t"{appid}"\n{inner}\t{{\n'
    f'{inner}\t\t"OverlayAppEnabled"\t\t"0"\n{inner}\t}}\n'
    f'{inner}}}'
)
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  {cfg_path}: synthesized apps/{appid}/OverlayAppEnabled=0 under Steam block")
PY
}

# Disable Steam overlay for CS2 in every user's localconfig.vdf. Mirrors
# disable_cs2_cloud â€” Steam clobbers localconfig.vdf on shutdown, so
# this is a no-op while Steam is running. Call BEFORE start_steam.
disable_cs2_overlay() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cs2_overlay: Steam is running â€” skip (would be clobbered on shutdown)"
    return 0
  fi

  local roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  local seen=() root user_dir steamid edited=0
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")

    shopt -s nullglob
    for user_dir in "$root"/*/; do
      steamid=$(basename "$user_dir")
      case "$steamid" in ''|*[!0-9]*) continue ;; esac
      log "disable_cs2_overlay: SteamID $steamid (under $root)"
      _vdf_disable_app_overlay "$user_dir/config/localconfig.vdf"
      _vdf_disable_overlay_system "$user_dir/config/localconfig.vdf"
      edited=1
    done
    shopt -u nullglob
  done

  [ "$edited" = 0 ] && log "disable_cs2_overlay: no userdata SteamIDs found yet â€” skip"
  return 0
}

# Set cs2's per-app LaunchOptions in localconfig.vdf. Idempotent. Mirrors
# _vdf_disable_app_overlay's 3-case structure (existing key / existing app
# block / no apps block) but writes a string value passed as argv[3].
_vdf_set_app_launchoptions() {
  local cfg="$1" value="$3"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" 730 "$value" <<'PY'
import re, sys, pathlib

cfg_path, appid, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(cfg_path)
src = p.read_text()
# VDF string escaping (our value has none, but be safe).
val = value.replace('\\', '\\\\').replace('"', '\\"')

pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
    brace_open = m.end() - 1
    depth, i = 1, brace_open + 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    if depth != 0:
        print(f"  {cfg_path}: unbalanced braces â€” refusing to edit")
        sys.exit(1)
    brace_close = i - 1
    block = src[brace_open + 1:brace_close]
    indent = m.group(2) + "\t"
    lo = re.search(r'(^|\n)([ \t]*)"([Ll]aunch[Oo]ptions)"[ \t]+"([^"]*)"', block)
    if lo:
        if lo.group(4) == value:
            sys.exit(0)
        new_block = block[:lo.start()] \
            + f'{lo.group(1)}{lo.group(2)}"{lo.group(3)}"\t\t"{val}"' \
            + block[lo.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: set LaunchOptions in existing {appid} block")
    else:
        new_block = f'\n{indent}"LaunchOptions"\t\t"{val}"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: inserted LaunchOptions in existing {appid} block")
    sys.exit(0)

apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
if apps:
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"LaunchOptions"\t\t"{val}"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with LaunchOptions")
    sys.exit(0)

def find_block_open(src, key, start=0):
    mm = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{').search(src, start)
    return mm.end() if mm else -1

sw = find_block_open(src, "Software")
if sw == -1:
    print(f"  {cfg_path}: no Software block â€” leaving untouched"); sys.exit(0)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  {cfg_path}: no Valve block â€” leaving untouched"); sys.exit(0)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  {cfg_path}: no Steam block â€” leaving untouched"); sys.exit(0)

sm = re.search(r'(\n)([ \t]*)"Steam"[ \t\r\n]*\{', src[:steam])
steam_indent = sm.group(2) if sm else "\t\t\t"
inner = steam_indent + "\t"
insertion = (
    f'\n{inner}"apps"\n{inner}{{\n'
    f'{inner}\t"{appid}"\n{inner}\t{{\n'
    f'{inner}\t\t"LaunchOptions"\t\t"{val}"\n{inner}\t}}\n'
    f'{inner}}}'
)
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  {cfg_path}: synthesized apps/{appid}/LaunchOptions under Steam block")
PY
}

# Force `__GL_SHADER_DISK_CACHE=1` onto the cs2 process via its Steam launch
# options. WHY: cs2 uses Vulkan; the NVIDIA driver DISABLES the writable shader
# disk cache when running as root unless that env var is set, so runtime-
# compiled pipelines (e.g. the molotov fire shader) recompile every render â€”
# a fixed-spot stutter. Steam manages the __GL_SHADER_DISK_CACHE_* env itself
# and strips our exported enable flag, so exporting it before -applaunch
# doesn't stick; launch options (`VAR=1 %command%`) ARE applied to the final
# game process and survive. Steam clobbers localconfig.vdf on shutdown, so â€”
# like disable_cs2_overlay â€” this must run while Steam is OFF.
set_cs2_launch_options() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "set_cs2_launch_options: Steam is running â€” skip (would be clobbered on shutdown)"
    return 0
  fi
  # Env prepended to %command%: the shader-cache flag always, plus OBS_VKCAPTURE=1
  # when CLIP rendering uses the Vulkan present-hook (CLIP_CAPTURE_METHOD=vkcapture,
  # the default). The layer also loads in live cs2 but is unused there (live
  # captures cs2+HUD via ximagesrc) â€” harmless. Steam strips exported env before
  # -applaunch, so the obs-vkcapture implicit Vulkan layer can ONLY be enabled here.
  local cap_env=""
  case "${CLIP_CAPTURE_METHOD:-vkcapture}" in
    vkcapture) cap_env="OBS_VKCAPTURE=1 " ;;
  esac
  local launch_opts="${CS2_LAUNCH_OPTIONS:-__GL_SHADER_DISK_CACHE=1 ${cap_env}%command%}"
  local roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  local seen=() root user_dir steamid edited=0
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")

    shopt -s nullglob
    for user_dir in "$root"/*/; do
      steamid=$(basename "$user_dir")
      case "$steamid" in ''|*[!0-9]*) continue ;; esac
      log "set_cs2_launch_options: SteamID $steamid -> '$launch_opts'"
      _vdf_set_app_launchoptions "$user_dir/config/localconfig.vdf" 730 "$launch_opts"
      edited=1
    done
    shopt -u nullglob
  done
  [ "$edited" = 0 ] && log "set_cs2_launch_options: no userdata SteamIDs found yet â€” skip"
  return 0
}

# The per-app `OverlayAppEnabled=0` only suppresses the overlay panel
# inside cs2 â€” Steam still spawns GameOverlayUI and pops the "Press
# Shift+Tab to begin" first-run toast over the captured stream. The
# master switch is `system.EnableGameOverlay` in localconfig.vdf
# (mirrors Settings â†’ In-Game â†’ "Enable the Steam Overlay while
# in-game"). With this flipped to 0, GameOverlayUI never spawns and
# the toast never appears.
_vdf_disable_overlay_system() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# Find or create the top-level "system" block inside UserLocalConfigStore.
sys_pat = re.compile(r'(^|\n)([ \t]*)"system"[ \t\r\n]*\{', re.MULTILINE)
sm = sys_pat.search(src)
if sm:
    brace_open = sm.end() - 1
    depth, i = 1, brace_open + 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    if depth != 0:
        print(f"  {p}: unbalanced braces in system block â€” refusing to edit")
        sys.exit(1)
    brace_close = i - 1
    block = src[brace_open + 1:brace_close]
    indent = sm.group(2) + "\t"
    eg = re.search(r'(^|\n)([ \t]*)"([Ee]nable[Gg]ame[Oo]verlay)"[ \t]+"([^"]*)"', block)
    if eg:
        if eg.group(4) == "0":
            sys.exit(0)
        new_block = block[:eg.start()] \
            + f'{eg.group(1)}{eg.group(2)}"{eg.group(3)}"\t\t"0"' \
            + block[eg.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {p}: flipped system.{eg.group(3)} to 0")
    else:
        new_block = f'\n{indent}"EnableGameOverlay"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {p}: inserted system.EnableGameOverlay=0")
    sys.exit(0)

# No system block â€” synthesize one at the top-level.
root = re.match(r'\s*"UserLocalConfigStore"[ \t\r\n]*\{', src)
if not root:
    print(f"  {p}: no UserLocalConfigStore root â€” leaving untouched")
    sys.exit(0)
insertion = '\n\t"system"\n\t{\n\t\t"EnableGameOverlay"\t\t"0"\n\t}'
p.write_text(src[:root.end()] + insertion + src[root.end():])
print(f"  {p}: synthesized system.EnableGameOverlay=0")
PY
}

# Diagnostic: print the current Steam overlay state on disk.
print_overlay_state() {
  log "current Steam overlay state on disk:"
  local f m

  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"EnableGameOverlay"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no EnableGameOverlay key)}"
    fi
  done

  local user_dir cfg root seen=()
  for root in "$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")
    shopt -s nullglob
    for user_dir in "$root"/*/; do
      cfg="$user_dir/config/localconfig.vdf"
      [ -f "$cfg" ] || continue
      m=$(python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); appid = sys.argv[2]
src = p.read_text()
parts = []
# Per-app
pat = re.compile(r'"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
    i = m.end(); depth = 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    block = src[m.end():i-1]
    oe = re.search(r'"([Oo]verlay[Aa]pp[Ee]nabled)"[ \t]+"([^"]*)"', block)
    parts.append(f'{oe.group(1)}="{oe.group(2)}"' if oe else "(no OverlayAppEnabled key)")
else:
    parts.append("(no 730 block)")
# System (master switch)
sys_pat = re.compile(r'"system"[ \t\r\n]*\{', re.MULTILINE)
sm = sys_pat.search(src)
if sm:
    i = sm.end(); depth = 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    block = src[sm.end():i-1]
    eg = re.search(r'"([Ee]nable[Gg]ame[Oo]verlay)"[ \t]+"([^"]*)"', block)
    parts.append(f'{eg.group(1)}="{eg.group(2)}"' if eg else "(no system.EnableGameOverlay key)")
else:
    parts.append("(no system block)")
print(" | ".join(parts))
PY
)
      log "  $cfg: $m"
    done
    shopt -u nullglob
  done
}

# Diagnostic: print the current Steam Cloud state so the operator can
# confirm the edits actually took effect. Reads files on disk; if Steam
# is running this reflects the on-disk state, NOT in-memory state.
print_cloud_state() {
  log "current Steam Cloud state on disk:"
  local f m

  # Global: registry.vdf -> CloudEnabled
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"CloudEnabled"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no CloudEnabled key)}"
    fi
  done

  # Global: config/config.vdf -> Cloud { EnableCloud }
  for f in "$STEAM_HOME/config/config.vdf" "$HOME/.steam/steam/config/config.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"EnableCloud"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no EnableCloud key)}"
    fi
  done

  # Per-user, per-app: localconfig.vdf + sharedconfig.vdf
  local user_dir cfg root seen=()
  for root in "$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")
    shopt -s nullglob
    for user_dir in "$root"/*/; do
      for cfg in "$user_dir/config/localconfig.vdf" "$user_dir/7/remote/sharedconfig.vdf"; do
        [ -f "$cfg" ] || continue
        m=$(python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); appid = sys.argv[2]
src = p.read_text()
pat = re.compile(r'"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if not m:
    print("(no 730 block)"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
block = src[m.end():i-1]
ce = re.search(r'"([Cc]loud[Ee]nabled)"[ \t]+"([^"]*)"', block)
print(f'{ce.group(1)}="{ce.group(2)}"' if ce else "(no CloudEnabled key)")
PY
)
        log "  $cfg: $m"
      done
    done
    shopt -u nullglob
  done
}

# Verbose dump of everything cloud-related: file paths, sizes, mtimes,
# the actual VDF blocks our edits target, and the tail of Steam's log
# filtered to "cloud" lines. Use this to confirm whether our edits stuck
# and whether Steam saw them.

# Comprehensive diagnostic dump â€” everything we need to figure out why
# Steam isn't behaving. One command, all signals.

# Make $STEAM_HOME a symlink into the cache mount so state persists
# across pod restarts without a second bind mount (which causes EXDEV
# on Steam self-update â€” see fix_steam_perms). Single filesystem means
# rename(2) always succeeds. On first run we migrate any pre-existing
# $STEAM_HOME content; if both sides have content, the persisted cache
# wins.
ensure_steam_home_persist() {
  local target="$STEAM_LIBRARY/steam"
  mkdir -p "$target"

  # if/else (not early-return): the ~/.steam repair below must run every
  # call, including warm reuse where $STEAM_HOME is already linked.
  if [ -L "$STEAM_HOME" ] \
     && [ "$(readlink -f "$STEAM_HOME" 2>/dev/null)" = "$(readlink -f "$target" 2>/dev/null)" ]; then
    log "ensure_steam_home_persist: $STEAM_HOME already -> $target"
  else
    if [ -L "$STEAM_HOME" ]; then
      log "ensure_steam_home_persist: replacing wrong symlink ($STEAM_HOME -> $(readlink "$STEAM_HOME"))"
      rm -f "$STEAM_HOME"
    elif [ -d "$STEAM_HOME" ]; then
      if [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
        log "ensure_steam_home_persist: migrating $STEAM_HOME contents -> $target"
        cp -a "$STEAM_HOME/." "$target/" 2>/dev/null || true
      else
        log "ensure_steam_home_persist: cache already populated, dropping ephemeral $STEAM_HOME"
      fi
      rm -rf "$STEAM_HOME"
    fi

    mkdir -p "$(dirname "$STEAM_HOME")"
    ln -sfn "$target" "$STEAM_HOME"
    log "ensure_steam_home_persist: $STEAM_HOME -> $target"
  fi

  # Steam asserts "Steam data link does not exist" and crash-loops if
  # ~/.steam/steam is missing; its bootstrap doesn't reliably recreate it
  # when $STEAM_HOME is a symlink. Pin both classic links every boot.
  local dotsteam="$HOME/.steam"
  mkdir -p "$dotsteam"
  local lk
  for lk in steam root; do
    rm -rf "$dotsteam/$lk" 2>/dev/null || true
    ln -s "$STEAM_HOME" "$dotsteam/$lk"
  done
  log "ensure_steam_home_persist: $dotsteam/{steam,root} -> $STEAM_HOME"
}

# Use ALL the node's cores for the shader compile. Steam's default is only
# ~half and there's no "all" keyword, so we compute it. The pod has no CPU
# limit (1 streamer/GPU node), so nproc = the node's full core count.
write_steam_dev_cfg() {
  local cfg="$STEAM_HOME/steam_dev.cfg"
  local threads
  threads=$(nproc 2>/dev/null || echo 0)
  if printf 'unShaderBackgroundProcessingThreads %s\n' "$threads" > "$cfg" 2>/dev/null; then
    log "write_steam_dev_cfg: unShaderBackgroundProcessingThreads=$threads (all cores)"
  else
    warn "write_steam_dev_cfg: could not write $cfg"
  fi
}

fix_steam_perms() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "fix_steam_perms: Steam is running â€” skip"
    return 0
  fi

  # Legacy `$STEAM_HOME/steam` symlink that points to /mnt/game-streamer/steam.
  # That target is a *different bind mount* from $STEAM_HOME, so rename(2)
  # across the symlink boundary fails with EXDEV. Steam's self-update
  # uses rename to commit `package/tmp/.../steam/cached/X` -> `./steam/cached/X`,
  # which crosses the mount and dies with:
  #   BCommitUpdatedFiles: failed to rename ... (error 18)
  #   Failed to apply update, reverting...
  #   dlmopen steamui.so failed: ... no such file
  # â€” Steam exits before webhelper spawns. Removing the symlink lets Steam
  # create ./steam/ as a real subdir on the same mount, so renames work.
  if [ -L "$STEAM_HOME/steam" ]; then
    log "fix_steam_perms: removing legacy $STEAM_HOME/steam symlink (-> $(readlink "$STEAM_HOME/steam"))"
    rm -f "$STEAM_HOME/steam"
  fi

  # Steam's update working area. Two distinct things live under package/:
  #   * package/steam_client_ubuntu12_*.zip + .manifest â€” completed,
  #     immutable downloads from the client-update CDN. Safe to keep
  #     across crashes; reusing them lets Steam skip a ~45s redownload.
  #   * package/tmp/                                    â€” half-extracted
  #     staging area for an in-progress update. If the prior process
  #     died mid-rename this can be inconsistent and will corrupt the
  #     next update attempt.
  #
  # Pods in our deployment get SIGKILL'd on stop, so Steam never exits
  # cleanly and a `.crash` marker shows up on every restart. That makes
  # `.crash` an unreliable signal of update corruption â€” wiping the
  # whole package/ on every boot would force a redownload on every
  # cold-ish start. Only `package/tmp/` presence is a direct, reliable
  # signal of a half-applied update; nuke just that.
  #
  # FORCE_PACKAGE_RESET=1 still wipes the whole package/ dir as a
  # manual escape hatch when a download is genuinely corrupt.
  if [ "${FORCE_PACKAGE_RESET:-0}" = "1" ]; then
    if [ -e "$STEAM_HOME/package" ]; then
      log "fix_steam_perms: FORCE_PACKAGE_RESET=1 â€” removing $STEAM_HOME/package"
      rm -rf "$STEAM_HOME/package"
    fi
  elif [ -e "$STEAM_HOME/package/tmp" ]; then
    log "fix_steam_perms: package/tmp present â€” removing only $STEAM_HOME/package/tmp (cache preserved)"
    rm -rf "$STEAM_HOME/package/tmp"
  fi

  # Stale lock/pid leftovers can wedge Steam at startup.
  rm -f "$STEAM_HOME/.steamstart.id" \
        "$STEAM_HOME/.steam.start" \
        "$STEAM_HOME/.crash" \
        "$STEAM_LIBRARY/steam/.crash" 2>/dev/null || true

  # Normalize ownership across the ENTIRE Steam home. Slow on warm
  # boots (recurses ~10k files in the cache mount) but only matters
  # the FIRST time a fresh host volume is mounted â€” once everything
  # is root:root, subsequent boots can skip. Marker file `.perms-ok`
  # records that we've done it. Bypass the skip by removing the
  # marker or setting FORCE_FIX_STEAM_PERMS=1.
  #
  # IMPORTANT: -H. Without it, $STEAM_HOME (a symlink to the cache
  # mount) is NOT traversed â€” we'd be no-op'ing on the symlink itself
  # and never touching the contents. With -H, chown follows
  # command-line symlinks for the recursion. Same for chmod.
  # CS2_DIR is on a separate path ($STEAM_LIBRARY/steamapps/...), not
  # affected â€” and it's 60GB so we wouldn't want to chown it anyway.
  local perms_marker="$STEAM_HOME/.perms-ok"
  if [ "${FORCE_FIX_STEAM_PERMS:-0}" != "1" ] && [ -f "$perms_marker" ]; then
    log "fix_steam_perms: marker present at $perms_marker â€” skip chown/chmod"
  else
    log "fix_steam_perms: chown -RH root:root + chmod -RH u+rwX on $STEAM_HOME"
    chown -RH root:root "$STEAM_HOME" 2>/dev/null || true
    chmod -RH u+rwX     "$STEAM_HOME" 2>/dev/null || true
    touch "$perms_marker" 2>/dev/null || true
  fi
}

# Kill anything left over from a prior Steam/cs2 session.
kill_steam() {
  pkill -9 -f '/linuxsteamrt64/cs2'  2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam'    2>/dev/null || true
  pkill -9 -f '/steam.sh'            2>/dev/null || true
  pkill -9 -f 'steamwebhelper'       2>/dev/null || true
  pkill -9 -x dbus-launch            2>/dev/null || true
  rm -f "$HOME/.steam/steam.pid" "$HOME/.steam/steam.pipe" 2>/dev/null || true
  rm -rf /tmp/dumps* /tmp/source_engine_*.lock /tmp/steam_pipe_* 2>/dev/null || true
}

# Launch Steam with login prefilled. UI visible so we can watch via the
# debug stream and complete any 2FA/captcha. Steam's stdout/stderr are
# tagged [steam] and stream to the k8s pod log via spawn_logged.
start_steam() {
  require_env STEAM_USER STEAM_PASSWORD

  if steam_pipe_up; then
    log "steam already running (pid $(cat "$HOME/.steam/steam.pid"))"
    return 0
  fi

  ensure_steam_bootstrap
  restore_real_steamclient

  # Webhelper bootstrap dominates cold-boot wall time (~50-60s on a
  # warm cache). These flags drop subsystems we never use:
  #
  #   -nofriendsui    skip Friends UI initialisation
  #   -nochatui       skip Chat UI initialisation
  #   -no-browser     skip the in-Steam web browser
  #
  # All three are community-known and safe â€” they don't affect the
  # webhelper paths +applaunch goes through. We deliberately do NOT
  # use -silent (tested earlier â€” it suppresses the webhelper subset
  # that handles +applaunch and cs2 never spawned).
  #
  # Override with STEAM_LAUNCH_FLAGS="" to fall back to a vanilla
  # launch if any of these ever turn out to break a future Steam
  # update.
  : "${STEAM_LAUNCH_FLAGS:=-nofriendsui -nochatui -no-browser}"
  # shellcheck disable=SC2206  # intentional word-split into argv
  local extra_flags=( $STEAM_LAUNCH_FLAGS )

  log "launching Steam with login=$STEAM_USER (flags: $STEAM_LAUNCH_FLAGS)"
  spawn_logged steam stdbuf -oL -eL dbus-launch --exit-with-session \
    "$STEAM_HOME/steam.sh" \
      "${extra_flags[@]}" \
      -login "$STEAM_USER" "$STEAM_PASSWORD"
  log "  steam wrapper pid=$SPAWNED_PID"
}

# Wait for Steam to finish login by polling for the userdata
# directory. With `-silent` no window ever appears, so we can't proxy
# the "logged in" signal off window visibility â€” userdata/<steamid>/
# is what actually indicates a completed login + roaming-config sync.
#
# On warm boots (HAD_USERDATA=1) this returns immediately. On cold
# first-boots it takes 30-60s (steamwebhelper has to fetch + sync).
wait_for_steam_userdata() {
  # Waits indefinitely â€” operator cancels by closing the popup.
  # "timeout" arg accepted for callsite compatibility, treated as
  # no-op.
  log "waiting for steam userdata (login + roaming config)"
  local i=0
  while :; do
    if [ -d "$STEAM_HOME/userdata" ]; then
      local found
      found=$(find "$STEAM_HOME/userdata" -mindepth 1 -maxdepth 1 -type d \
        ! -name anonymous 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        log "  userdata up after ${i}s ($found)"
        return 0
      fi
    fi
    i=$(( i + 1 ))
    [ $(( i % 15 )) -eq 0 ] && log "  still waiting (${i}s)"
    sleep 1
  done
}

# Wait for Steam IPC to come up. Waits indefinitely â€” operator
# cancels by closing the popup window (which drops the WS, which
# tells the api to delete the pod). No need for a self-imposed
# timeout that just bricks the pod with no recovery path.
#
# A "timeout" arg is still accepted but treated as a no-op so callers
# can keep their old signatures.
wait_for_steam_pipe() {
  log "waiting for steam pipe (Ctrl-C / pod delete to cancel)"
  local i=0
  while :; do
    if steam_pipe_up; then
      log "  PIPE UP after ${i}s (pid $(cat "$HOME/.steam/steam.pid"))"
      return 0
    fi
    i=$(( i + 1 ))
    if [ $(( i % 15 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
    fi
    sleep 1
  done
}

# Report status=validating while Steam verifies 730 game files (no % â€” CEF-only).
# Parsed from content_log.txt. Returns 0 while validating, else 1.
_VALIDATE_LOG_OFFSET=0
_VALIDATE_LAST=""
_validate_log_file() { printf '%s/logs/content_log.txt' "${STEAM_HOME:-/root/.local/share/Steam}"; }

# Snapshot log size so we only read this run's lines. Call before the wait loop.
validate_progress_reset() {
  _VALIDATE_LOG_OFFSET=$(stat -c %s "$(_validate_log_file)" 2>/dev/null || echo 0)
  _VALIDATE_LAST=""
}

validate_report_progress() {
  local f line size
  f="$(_validate_log_file)"
  [ -f "$f" ] || return 1
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$size" -lt "${_VALIDATE_LOG_OFFSET:-0}" ] && _VALIDATE_LOG_OFFSET=0
  # Latest app-update state line for 730 this run.
  line=$(tail -c "+$(( ${_VALIDATE_LOG_OFFSET:-0} + 1 ))" "$f" 2>/dev/null \
    | grep -a 'AppID 730 App update changed' | tail -1)
  case "$line" in
    *Verifying*)
      if [ "$_VALIDATE_LAST" != "validating" ]; then
        _VALIDATE_LAST="validating"
        log "validating CS2 game files (Steam integrity check)"
        report_status status=validating >/dev/null 2>&1 || true
      fi
      return 0 ;;
    *)
      _VALIDATE_LAST=""
      return 1 ;;
  esac
}

# True if the FRESH (boot-wiped) cloud_log shows a 730 conflict â€” the "Cloud Out
# of Date" trigger. Log is wiped on boot, so any hit is this run (not stale).
cloud_conflict_active() {
  local f="${STEAM_HOME:-/root/.local/share/Steam}/logs/cloud_log.txt"
  [ -f "$f" ] || return 1
  # "conflict" = sync-conflict variant; "pending remote operations" = the
  # "(upload not started)" variant (save on another machine not yet uploaded).
  grep -aqiE '\[AppID 730\].*(conflict|returned [1-9][0-9]* pending remote operation)' "$f" 2>/dev/null
}

# wait_for_cs2_process <applaunch_fn>
#
# Block until a /linuxsteamrt64/cs2 process appears, then set CS2_PID.
# Waits indefinitely â€” a cold shader compile can take a long time, so we
# never time out / die (operator cancels via pod delete).
#
# Side effects on each iteration:
#   - on operator skip: stop the fossilize_replay shader workers (deterministic;
#     poke_steam_dialog is kept as a secondary nudge but is unreliable alone).
#   - shader_report_progress (inline) reports compile %.
#   - re-issue -applaunch ONLY when cs2 is absent AND nothing is in flight (no
#     shader compile, no file validation), after a grace period, spaced out, and
#     capped. This recovers the "Steam forwarded the applaunch after a fresh
#     download/update but never actually started cs2" hang WITHOUT reintroducing
#     the duplicate-instance wedge (we never re-launch while a cs2 process exists
#     or while Steam is busy compiling/validating). <applaunch_fn> is invoked by
#     NAME for this.
#   - at 60s/120s/180s: dump open X windows + console-linux.txt tail
#     so a future failure leaves evidence (which dialog was up, what
#     Steam was doing) instead of a silent 5-min wait.
#
# The applaunch fn is passed by NAME (so the caller doesn't need to
# export it). It must be a defined shell function in the caller's
# scope; we invoke it as `"$1"`.
wait_for_cs2_process() {
  local applaunch_fn="${1:?applaunch function name required}"
  local pid="" i=0 cloud_pokes=0 cloud_detected=0 steam_gone=0
  # Re-applaunch recovery state (see header): count + last loop we re-launched.
  local relaunches=0 last_relaunch_i=0

  # Operator "Skip shaders" signal (spec-server writes this file). Clear any
  # stale marker from a prior run so we don't auto-skip this one.
  local skip_marker="${LOG_DIR}/skip-shaders"
  rm -f "$skip_marker" 2>/dev/null || true
  local skip_logged=0

  # Track last loop a compile was active, to detect a wedged/stalled one.
  local shaders_seen=0 last_active_i=0

  # Ignore stale progress from a prior run (persistent shader_log.txt /
  # content_log.txt both append across runs).
  declare -F shader_progress_reset >/dev/null 2>&1 && shader_progress_reset
  validate_progress_reset

  # Wait indefinitely â€” a cold shader compile can run well past any fixed
  # timeout and killing it mid-compile wastes the work. Operator cancels by
  # deleting the pod (same pattern as wait_for_steam_pipe).
  while :; do
    i=$(( i + 1 ))
    pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
    if [ -n "$pid" ]; then
      CS2_PID="$pid"
      return 0
    fi

    # Skip requested â†’ dismiss the modal now (any time, not just the poke
    # window) and stop holding open. Never in batch (clips must be warm).
    local skip_now=0
    if [ -f "$skip_marker" ] && [ "${CLIP_BATCH_MODE:-0}" != "1" ]; then
      skip_now=1
      if [ "$skip_logged" != 1 ]; then
        log "  operator requested skip â€” dismissing shader modal, launching cs2"
        skip_logged=1
      fi
    fi

    # On operator skip: stop the fossilize_replay workers directly (deterministic
    # end to "Processing Vulkan shaders" regardless of dialog focus / black UI),
    # and still poke the CEF dialog as a secondary nudge. Only on skip â€” we never
    # auto-kill the compile we normally want to run.
    if [ "$skip_now" = 1 ]; then
      declare -F skip_shader_compile >/dev/null 2>&1 && skip_shader_compile
      poke_steam_dialog
    fi

    [ $(( i % 15 )) -eq 0 ] && log "  ${i}s elapsed waiting on cs2..."

    # Steam client watchdog: the client can segfault after boot (breakpad dump
    # fires, the steam.sh wrapper survives holding the IPC pipe) â€” every
    # applaunch then "forwards" into the corpse and cs2 never spawns. Three
    # consecutive 5s checks with no client process = dead â†’ full restart.
    if [ $(( i % 5 )) -eq 0 ]; then
      if pgrep -f 'ubuntu12_32/steam' >/dev/null 2>&1; then
        steam_gone=0
      else
        steam_gone=$(( steam_gone + 1 ))
        if [ "$steam_gone" -ge 3 ]; then
          log "  Steam client process gone ~15s (segfault?) â€” restarting Steam"
          kill_steam
          start_steam
          wait_for_steam_pipe "${STEAM_PIPE_TIMEOUT:-300}"
          wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" || true
          steam_gone=0; cloud_pokes=0; relaunches=0; last_relaunch_i=$i
          "$applaunch_fn"
        fi
      fi
    fi

    # Surface a Steam game-file validation pass (corrupt-files repair / partial
    # update) as status=validating. Self-throttles; no-op when not validating.
    # Capture whether it's actively validating so re-applaunch holds off.
    local validating_active=0
    validate_report_progress && validating_active=1

    # Report compile progress + whether it's actively running (inline â€” no
    # bg process that can die and freeze the UI).
    local shaders_active=0
    if declare -F shader_report_progress >/dev/null 2>&1 && shader_report_progress; then
      shaders_active=1
      shaders_seen=1
      last_active_i=$i
    fi

    # Hold the launch open while a compile is active (don't re-issue applaunch).
    if [ "$skip_now" = 0 ] && [ "$shaders_active" = 1 ]; then
      [ $(( i % 30 )) -eq 0 ] && log "  shaders still compiling â€” holding launch open"
      sleep 1
      continue
    fi

    # Cloud "Out of Date" modal: gate on the FRESH (boot-wiped) cloud_log â€” a 730
    # conflict line means the modal is actually up THIS run. Only then dismiss.
    # Fresh log = no stale false-positives (won't fire on the shader screen).
    if [ $(( i % 4 )) -eq 0 ] \
       && declare -F cloud_conflict_active >/dev/null 2>&1 && cloud_conflict_active; then
      if [ "$cloud_detected" != 1 ]; then
        cloud_detected=1
        log "  Cloud Out of Date signature in cloud_log @ ${i}s"
      fi
      if [ "$cloud_pokes" -lt "${CLOUD_DISMISS_MAX:-1}" ]; then
        if declare -F dismiss_cloud_dialog >/dev/null 2>&1 && dismiss_cloud_dialog; then
          cloud_pokes=$(( cloud_pokes + 1 ))
          log "  dismissed Cloud Out of Date modal (poke ${cloud_pokes}/${CLOUD_DISMISS_MAX:-1})"
        else
          log "  dismiss_cloud_dialog failed â€” retrying in 4s"
        fi
      fi
    fi

    # Re-applaunch recovery: after a fresh steamcmd download/update, Steam often
    # forwards the applaunch ("Steam is already running, command was forwarded")
    # but never actually starts cs2 â€” the loop would then wait forever. Re-issue
    # the launch when cs2 is absent (loop top) AND nothing is in flight (no shader
    # compile, no file validation), after an initial grace, spaced out, and capped.
    # Tightly guarded so we never fire while a cs2 process exists or Steam is busy
    # â€” that's the duplicate-instance wedge we must avoid.
    # i - last_active_i guards the post-compile handoff: when a compile just
    # finished, cs2 spawns within seconds, so we hold off re-launching until the
    # GPU/Steam has been idle for the grace window (last_active_i stays 0 when no
    # compile ever ran, so a truly-stuck launch still fires after the grace).
    if [ "$shaders_active" = 0 ] && [ "$validating_active" = 0 ] \
       && [ $(( i - last_active_i )) -ge "${CS2_RELAUNCH_GRACE:-45}" ] \
       && [ "$relaunches" -lt "${CS2_RELAUNCH_MAX:-5}" ] \
       && [ $(( i - last_relaunch_i )) -ge "${CS2_RELAUNCH_INTERVAL:-30}" ]; then
      relaunches=$(( relaunches + 1 ))
      last_relaunch_i=$i
      log "  cs2 not up after ${i}s with nothing in flight â€” re-issuing applaunch (#${relaunches}/${CS2_RELAUNCH_MAX:-5}); Steam likely dropped the first one after a download/update"
      "$applaunch_fn" || warn "  re-applaunch invocation failed"
    fi

    # Quiet/slow compile: never auto-skip or die â€” only the UI skip button
    # skips. Wait indefinitely; operator cancels a wedged job from the UI.
    if [ "$shaders_seen" = 1 ] && [ "$skip_now" = 0 ] \
       && [ $(( i - last_active_i )) -ge "${SHADER_STALL_GRACE:-180}" ] \
       && [ $(( i % 60 )) -eq 0 ]; then
      warn "  shader compile quiet ${SHADER_STALL_GRACE:-180}s+ (cs2 not up yet) â€” still waiting; cancel the job in the UI if it's truly stuck"
    fi

    case "$i" in
      60|120|180)
        log "  diag @ ${i}s â€” open X windows:"
        list_x_windows 2>/dev/null | sed 's/^/    /' || true
        log "  diag @ ${i}s â€” last 10 lines of $STEAM_LIBRARY/steam/logs/console-linux.txt:"
        tail -10 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null | sed 's/^/    /' || true
        ;;
    esac

    sleep 1
  done
}
