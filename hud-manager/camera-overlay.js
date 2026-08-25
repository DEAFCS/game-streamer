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
// live video connection. That's a deliberate trade-off: a couple of
// fresh frames a second via polling (POLL_MS below), not real-time
// video with audio sync -- but reliable, and immune to whatever was
// blocking raw UDP media on this network.
//
// Avatar-mount behavior (selector, hide-the-photo-behind-it, the
// MutationObserver re-attach loop) mirrors upstream 5stackgg's own
// camera-overlay.js exactly -- same bundled JTs Hud Manager binary,
// same markup, verified against their source rather than guessed. Only
// the actual feed mechanism (poll-a-JPEG vs. hold-a-WebRTC-track)
// differs, per the above.
(function () {
  "use strict";

  // Injection is wired to did-finish-load, which fires again on any
  // in-page reload -- without this a second poll loop and observer
  // stack on top of the first every time.
  if (window.__DEAFCS_CAMERA_DISPOSE__) {
    window.__DEAFCS_CAMERA_DISPOSE__();
  }

  var SPEC_BASE = window.__DEAFCS_SPEC_BASE__ || "http://127.0.0.1:1350";
  var POLL_MS = 2000;
  // How long to wait for a snapshot fetch before giving up on this
  // cycle -- generous, since a slow/first-time snapshot means the
  // server-side headless page is still negotiating its own (local,
  // same-cluster) WHEP connection.
  var FETCH_TIMEOUT_MS = 4000;
  // The 140x140 box the HUD floats above the spectated player's bar.
  // Present in both hud variants -- `.observed` is not scoped to
  // `.layout-*`.
  var AVATAR_SELECTOR = ".observed .avatar_container .avatar";
  // The hud's avatar box is a 140px square while a webcam is 16:9, so
  // filling it exactly crops away most of the shot. Overflowing the
  // box horizontally keeps the same height but shows noticeably more
  // of the frame -- `.observed` is 380px wide and sets
  // overflow:visible, so nothing clips it.
  var AVATAR_WIDTH_PX = 200;

  var img = document.createElement("img");
  img.id = "deafcs-camera";

  var AVATAR_STYLE = {
    position: "absolute",
    inset: "auto",
    top: "0",
    left: "50%",
    transform: "translateX(-50%)",
    width: AVATAR_WIDTH_PX + "px",
    height: "100%",
    borderRadius: "4px",
    border: "none",
    boxShadow: "0 4px 15px rgba(0,0,0,0.5)",
    background: "#000",
    zIndex: "9",
    opacity: "0",
    transition: "opacity 220ms ease",
    pointerEvents: "none",
    objectFit: "cover",
  };

  // Only reached on a hud whose markup has no observed-player avatar.
  // Keeping a corner box means the feature degrades rather than
  // silently disappearing.
  var CORNER_STYLE = {
    position: "fixed",
    inset: "auto",
    left: "24px",
    bottom: "96px",
    width: "200px",
    height: "auto",
    aspectRatio: "16/9",
    borderRadius: "10px",
    border: "2px solid rgba(255,255,255,0.85)",
    boxShadow: "0 2px 10px rgba(0,0,0,0.5)",
    background: "#000",
    zIndex: "2147483647",
    opacity: "0",
    transition: "opacity 220ms ease",
    pointerEvents: "none",
    objectFit: "cover",
  };

  var currentSteamId = null;
  var currentObjectUrl = null;
  var fetchInFlight = false;

  var mode = null;
  var visible = false;
  var hiddenImage = null;

  function restoreAvatarImage() {
    if (hiddenImage) {
      hiddenImage.style.removeProperty("visibility");
      hiddenImage = null;
    }
  }

  // React owns this subtree and rebuilds it whenever the spectated
  // player changes, which both drops our img and restores the avatar
  // photo it replaced -- so re-attaching is a steady-state operation,
  // not just a startup one.
  function attach() {
    var anchor = document.querySelector(AVATAR_SELECTOR);
    var parent = anchor || document.body;
    var nextMode = anchor ? "avatar" : "corner";

    if (img.parentElement !== parent) {
      parent.appendChild(img);
    }

    if (mode !== nextMode) {
      mode = nextMode;
      img.removeAttribute("style");
      var style = nextMode === "avatar" ? AVATAR_STYLE : CORNER_STYLE;
      for (var key in style) img.style[key] = style[key];
      img.style.opacity = visible ? "1" : "0";
    }

    var photo = anchor ? anchor.querySelector("img:not(#deafcs-camera)") : null;

    if (visible && anchor && photo) {
      if (hiddenImage !== photo) {
        restoreAvatarImage();
        hiddenImage = photo;
      }
      photo.style.visibility = "hidden";
      return;
    }

    restoreAvatarImage();
  }

  var attachQueued = false;
  var observer = new MutationObserver(function () {
    if (attachQueued) return;
    attachQueued = true;
    requestAnimationFrame(function () {
      attachQueued = false;
      attach();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });

  attach();

  function show(next) {
    visible = next;
    img.style.opacity = next ? "1" : "0";
    attach();
  }

  function teardown() {
    show(false);
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
      var nextUrl = URL.createObjectURL(blob);
      var prevUrl = currentObjectUrl;
      img.src = nextUrl;
      currentObjectUrl = nextUrl;
      if (prevUrl) URL.revokeObjectURL(prevUrl);
      show(true);
    }).catch(function () {
      // Quiet by design -- fires constantly for any spectated player
      // who simply doesn't have the feature on or hasn't published a
      // camera yet, the overwhelmingly common case, not an error worth
      // logging continuously.
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
        show(false);
      }

      fetchSnapshot(steamId);
    }).finally(function () {
      setTimeout(poll, POLL_MS);
    });
  }

  poll();

  window.__DEAFCS_CAMERA_DISPOSE__ = function () {
    observer.disconnect();
    teardown();
    restoreAvatarImage();
    img.remove();
  };
})();
