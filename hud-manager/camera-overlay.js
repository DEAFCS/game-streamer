// deafcs: live camera overlay for the spectated player
// (match_options.streamer_camera_enabled, see DEAFCS/deafcs-web#91).
//
// Injected as raw JS into the HUD's Electron overlay window via
// auto-overlay.patch (executeJavaScript on did-finish-load) -- NOT part
// of the HUD's own bundle, since that's JTs Hud Manager's closed
// pre-built binary. window.__DEAFCS_SPEC_BASE__ is set immediately
// before this script runs (see the patch).
//
// Real WebRTC never worked from this pod (extensive live debugging --
// stale IPs, ICE noise, a TURN relay, forcing it over a full-MTU public
// IP -- see git history -- this deployment's game-streamer runs on a
// laptop reachable only over a university network's VPN tunnel, and
// every WebRTC/DTLS handshake failed identically regardless of
// destination, while plain HTTPS always worked fine on the same path).
// A single-JPEG-every-2s poll sidestepped that but read as a slideshow,
// not live video -- not good enough for an actual broadcast. This
// version instead points a plain <img> at a continuous MJPEG stream
// (GET /camera/:steamId/stream, proxied from api-deafcs's snapshotter --
// see spec-server's camera.mjs) -- browsers have natively played
// multipart/x-mixed-replace JPEG streams in <img> forever (it's how
// most IP/security cameras have always worked), so this gets real,
// continuously-updating video using only plain HTTP, no WebRTC and no
// per-frame JS on this end at all.
//
// Avatar-mount behavior (selector, hide-the-photo-behind-it, the
// MutationObserver re-attach loop) mirrors upstream 5stackgg's own
// camera-overlay.js -- same bundled JTs Hud Manager binary, same
// markup, verified against their source rather than guessed.
(function () {
  "use strict";

  // Injection is wired to did-finish-load, which fires again on any
  // in-page reload -- without this a second observer and state-poll
  // loop stack on top of the first every time.
  if (window.__DEAFCS_CAMERA_DISPOSE__) {
    window.__DEAFCS_CAMERA_DISPOSE__();
  }

  var SPEC_BASE = window.__DEAFCS_SPEC_BASE__ || "http://127.0.0.1:1350";
  var STATE_POLL_MS = 2000;
  // A player with no camera fails every attempt; back off rather than
  // re-requesting a doomed stream every couple of seconds.
  var RETRY_BACKOFF_MS = 15000;
  // <img> doesn't reliably surface a silently-stalled multipart stream
  // (server-side hiccup, session reaped, network blip) as an error
  // event -- it just freezes on the last frame. Force a fresh
  // connection periodically as a cheap safety net rather than trying to
  // detect staleness precisely.
  var RECONNECT_INTERVAL_MS = 60000;
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
  var connectedAt = 0;
  var failedUntil = new Map();

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

  // Multipart/x-mixed-replace parts each fire their own load event --
  // the first one landing is exactly "a real frame arrived", the same
  // signal the old WebRTC client got from ontrack.
  img.addEventListener("load", function () {
    if (currentSteamId) show(true);
  });
  img.addEventListener("error", function () {
    if (currentSteamId) failedUntil.set(currentSteamId, Date.now() + RETRY_BACKOFF_MS);
    show(false);
    img.removeAttribute("src");
  });

  function connect(steamId) {
    currentSteamId = steamId;
    connectedAt = Date.now();
    show(false);
    img.src = SPEC_BASE + "/camera/" + steamId + "/stream";
  }

  function teardown() {
    show(false);
    img.removeAttribute("src");
    currentSteamId = null;
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

      if (steamId === currentSteamId) {
        // Same player still spectated -- periodically force a fresh
        // connection as a stall safety net (see RECONNECT_INTERVAL_MS).
        if (Date.now() - connectedAt > RECONNECT_INTERVAL_MS) connect(steamId);
        return;
      }

      var backoff = failedUntil.get(steamId) || 0;
      if (Date.now() < backoff) return;

      connect(steamId);
    }).finally(function () {
      setTimeout(poll, STATE_POLL_MS);
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
