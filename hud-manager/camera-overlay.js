// deafcs: live camera overlay for the spectated player
// (match_options.streamer_camera_enabled, see DEAFCS/deafcs-web#91).
//
// Injected as raw JS into the HUD's Electron overlay window via
// auto-overlay.patch (executeJavaScript on did-finish-load) -- NOT part
// of the HUD's own bundle, since that's JTs Hud Manager's closed
// pre-built binary. window.__DEAFCS_SPEC_BASE__ is set immediately
// before this script runs (see the patch).
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
  var RETRY_BACKOFF_MS = 15000;
  var ICE_GATHER_TIMEOUT_MS = 1500;

  var box = null;
  var videoEl = null;
  var pc = null;
  var currentSteamId = null;
  var failedUntil = Object.create(null);

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
    videoEl = document.createElement("video");
    videoEl.autoplay = true;
    videoEl.playsInline = true;
    videoEl.muted = true;
    videoEl.style.cssText = "width:100%;height:100%;object-fit:cover;display:block";
    box.appendChild(videoEl);
    document.body.appendChild(box);
    return box;
  }

  function showLive(show) {
    ensureBox();
    box.style.display = show ? "block" : "none";
  }

  function teardown() {
    if (pc) {
      try { pc.close(); } catch (e) {}
      pc = null;
    }
    showLive(false);
    if (videoEl) videoEl.srcObject = null;
  }

  function connect(steamId) {
    teardown();
    currentSteamId = steamId;

    var attempt = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });
    pc = attempt;
    attempt.addTransceiver("video", { direction: "recvonly" });

    attempt.ontrack = function (e) {
      // Only reveal the box once real track data actually arrives --
      // otherwise a connection that "succeeds" at the SDP level but
      // never receives frames would still paint an empty black box.
      if (attempt !== pc) return;
      ensureBox();
      videoEl.srcObject = e.streams[0];
      showLive(true);
    };

    attempt.createOffer().then(function (offer) {
      return attempt.setLocalDescription(offer);
    }).then(function () {
      return new Promise(function (resolve) {
        if (attempt.iceGatheringState === "complete") return resolve();
        attempt.addEventListener("icegatheringstatechange", function onChange() {
          if (attempt.iceGatheringState === "complete") {
            attempt.removeEventListener("icegatheringstatechange", onChange);
            resolve();
          }
        });
        setTimeout(resolve, ICE_GATHER_TIMEOUT_MS);
      });
    }).then(function () {
      return fetch(SPEC_BASE + "/camera/" + steamId + "/whep", {
        method: "POST",
        headers: { "Content-Type": "application/sdp" },
        body: attempt.localDescription.sdp,
      });
    }).then(function (res) {
      if (!res.ok) throw new Error("whep " + res.status);
      return res.text();
    }).then(function (answerSdp) {
      if (attempt !== pc) return; // superseded by a newer attempt/poll
      return attempt.setRemoteDescription({ type: "answer", sdp: answerSdp });
    }).catch(function () {
      // Quiet by design -- fires constantly for any spectated player who
      // simply doesn't have the feature on or hasn't published a camera
      // yet, the overwhelmingly common case, not an error worth logging.
      failedUntil[steamId] = Date.now() + RETRY_BACKOFF_MS;
      if (attempt === pc) teardown();
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
        if (currentSteamId !== null) {
          currentSteamId = null;
          teardown();
        }
        return;
      }

      if (steamId === currentSteamId) return; // already connecting/connected

      var until = failedUntil[steamId];
      if (until && Date.now() < until) return; // still in backoff

      connect(steamId);
    }).finally(function () {
      setTimeout(poll, POLL_MS);
    });
  }

  poll();
})();
