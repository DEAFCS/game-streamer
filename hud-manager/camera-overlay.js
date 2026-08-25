// deafcs: live camera overlay for the spectated player
// (match_options.streamer_camera_enabled, see DEAFCS/deafcs-web#91).
//
// Injected as raw JS into the HUD's Electron overlay window via
// auto-overlay.patch (executeJavaScript on did-finish-load) -- NOT part
// of the HUD's own bundle, since that's JTs Hud Manager's closed
// pre-built binary. window.__DEAFCS_SPEC_BASE__ is set immediately
// before this script runs (see the patch).
//
// Rewritten after extensive live debugging (stale IPs, ICE candidate
// noise, a real retry-logic bug, a dedicated TURN relay, forcing the
// relay over a full-MTU public IP -- see git history) never got a
// direct WebRTC connection working from this pod: this specific
// deployment's game-streamer runs on a laptop reachable only over a
// university network's VPN tunnel, and every WebRTC/DTLS handshake
// attempt from it failed identically regardless of destination, while
// plain HTTPS (every other spec-server <-> api-deafcs call) works fine
// on the exact same path. So this no longer does WebRTC at all -- it
// polls a JPEG snapshot (produced server-side by a headless-browser WHEP
// consumer, see api-deafcs/snapshotter/) instead of holding its own
// live video connection. Not real-time video, but simple, reliable,
// and immune to whatever was blocking raw UDP media on this network.
//
// We don't have a verified DOM selector for this HUD's own avatar
// element (it's not something DEAFCS's fork controls the source of),
// so this always renders as its own fixed corner box rather than trying
// to reach into the HUD's markup -- safe regardless of what HUD/variant
// is active, same reasoning upstream 5stackgg's own camera-overlay.js
// uses as ITS fallback when its own avatar selector doesn't match.
(function () {
  "use strict";

  var SPEC_BASE = window.__DEAFCS_SPEC_BASE__ || "http://127.0.0.1:1350";
  var POLL_MS = 2000;
  // How long to wait for a snapshot fetch before giving up on this
  // cycle -- generous, since a slow/first-time snapshot means the
  // server-side headless page is still negotiating its own (local,
  // same-cluster) WHEP connection.
  var FETCH_TIMEOUT_MS = 4000;

  var box = null;
  var imgEl = null;
  var currentSteamId = null;
  var currentObjectUrl = null;
  var fetchInFlight = false;

  function ensureBox() {
    if (box) return box;
    box = document.createElement("div");
    box.style.cssText = [
      "position:fixed",
      "left:24px",
      "bottom:96px",
      "width:200px",
      "aspect-ratio:16/9",
      "border-radius:10px",
      "overflow:hidden",
      "border:2px solid rgba(255,255,255,0.85)",
      "box-shadow:0 2px 10px rgba(0,0,0,0.5)",
      "background:#000",
      "z-index:2147483647",
      "display:none",
    ].join(";");
    imgEl = document.createElement("img");
    imgEl.style.cssText = "width:100%;height:100%;object-fit:cover;display:block";
    box.appendChild(imgEl);
    document.body.appendChild(box);
    return box;
  }

  function showLive(show) {
    ensureBox();
    box.style.display = show ? "block" : "none";
  }

  function teardown() {
    showLive(false);
    if (currentObjectUrl) {
      URL.revokeObjectURL(currentObjectUrl);
      currentObjectUrl = null;
    }
    currentSteamId = null;
  }

  function fetchSnapshot(steamId) {
    if (fetchInFlight) return;
    fetchInFlight = true;

    var controller = new AbortController();
    var timeoutTimer = setTimeout(function () {
      controller.abort();
    }, FETCH_TIMEOUT_MS);

    fetch(SPEC_BASE + "/camera/" + steamId + "/snapshot", {
      signal: controller.signal,
    }).then(function (res) {
      clearTimeout(timeoutTimer);
      if (!res.ok) throw new Error("snapshot " + res.status);
      return res.blob();
    }).then(function (blob) {
      // Player changed (or feature turned off) while this fetch was in
      // flight -- don't paint a stale frame for the wrong person.
      if (steamId !== currentSteamId) return;
      ensureBox();
      var nextUrl = URL.createObjectURL(blob);
      var prevUrl = currentObjectUrl;
      imgEl.src = nextUrl;
      currentObjectUrl = nextUrl;
      if (prevUrl) URL.revokeObjectURL(prevUrl);
      showLive(true);
    }).catch(function () {
      // Quiet by design -- fires constantly for any spectated player who
      // simply doesn't have the feature on or hasn't published a camera
      // yet, the overwhelmingly common case, not an error worth logging.
    }).finally(function () {
      clearTimeout(timeoutTimer);
      fetchInFlight = false;
    });
  }

  function poll() {
    fetch(SPEC_BASE + "/camera/state").then(function (res) {
      return res.ok ? res.json() : { enabled: false, steam_id: null };
    }).catch(function () {
      return { enabled: false, steam_id: null };
    }).then(function (state) {
      var steamId = state && state.enabled ? state.steam_id : null;

      if (!steamId) {
        if (currentSteamId !== null) teardown();
        return;
      }

      if (steamId !== currentSteamId) {
        // Switched to a new player -- clear the old frame immediately
        // (don't show the previous player's face under the new one's
        // name) rather than waiting for the next fetch to land.
        currentSteamId = steamId;
        showLive(false);
      }

      fetchSnapshot(steamId);
    }).finally(function () {
      setTimeout(poll, POLL_MS);
    });
  }

  poll();
})();
